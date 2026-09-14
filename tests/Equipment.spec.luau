--!strict

local EquipmentSlots = require("EquipmentSlots")
local Equipment = require("EquipmentService")
local ItemDefinitions = require("ItemDefinitions")

local StarterSword = "weapon_sword_starter"
local UpgradedSword = "weapon_sword_upgraded"
local BasicPickaxe = "tool_pickaxe_basic"
local UpgradedPickaxe = "tool_pickaxe_upgraded"

local passed = 0
local function test(name, run)
	local ok, message = pcall(run)
	assert(ok, name .. ": " .. tostring(message))
	passed += 1
	print("PASS " .. name)
end
local function equal(actual, expected)
	assert(actual == expected, ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
end

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

local function fixture()
	local records = {
		[7] = {
			Gold = 25,
			SkillXP = { skill_melee = 12 },
			Inventory = {
				Stacks = { item_iron_ore = 4 },
				Items = {
					starter = { DefinitionId = StarterSword },
					upgraded = { DefinitionId = UpgradedSword },
					basic_pickaxe = { DefinitionId = BasicPickaxe },
					upgraded_pickaxe = { DefinitionId = UpgradedPickaxe },
				},
			},
			Equipment = {},
		},
	}
	local playerData = { Calls = 0, FailReason = nil }
	function playerData.GetSnapshot(userId)
		return if records[userId] then copy(records[userId]) else nil
	end
	function playerData.Update(userId, change)
		playerData.Calls += 1
		if playerData.FailReason then
			return false, playerData.FailReason
		end
		local candidate = copy(records[userId])
		if not candidate then
			return false, "NotReady"
		end
		change(candidate)
		records[userId] = candidate
		return true, nil
	end
	return { Records = records, PlayerData = playerData, Service = Equipment.New(playerData) }
end

test("equipment definitions use stable V1 slots and provisional effectiveness tiers", function()
	equal(ItemDefinitions.ById[StarterSword].Equipment.SlotId, EquipmentSlots.Weapon)
	equal(ItemDefinitions.ById[UpgradedSword].Equipment.SlotId, EquipmentSlots.Weapon)
	equal(ItemDefinitions.ById[BasicPickaxe].Equipment.SlotId, EquipmentSlots.Tool)
	equal(ItemDefinitions.ById[UpgradedPickaxe].Equipment.SlotId, EquipmentSlots.Tool)
	equal(ItemDefinitions.ById[StarterSword].Equipment.EffectivenessTier, 1)
	equal(ItemDefinitions.ById[UpgradedSword].Equipment.EffectivenessTier, 2)
	equal(ItemDefinitions.ById[BasicPickaxe].Equipment.EffectivenessTier, 1)
	equal(ItemDefinitions.ById[UpgradedPickaxe].Equipment.EffectivenessTier, 2)
end)

test("equipping requires ownership and slot compatibility", function()
	local f = fixture()
	local missing, missingReason = f.Service.Equip(7, EquipmentSlots.Weapon, "missing")
	equal(missing, nil)
	equal(missingReason, "ItemNotOwned")
	local incompatible, incompatibleReason = f.Service.Equip(7, EquipmentSlots.Tool, "starter")
	equal(incompatible, nil)
	equal(incompatibleReason, "InvalidEquipment")
	f.Records[7].Inventory.Items.unknown = { DefinitionId = "item_unknown" }
	local invalidDefinition, invalidDefinitionReason = f.Service.Equip(7, EquipmentSlots.Weapon, "unknown")
	equal(invalidDefinition, nil)
	equal(invalidDefinitionReason, "InvalidEquipment")
	equal(next(f.Records[7].Equipment), nil)
end)

test("equipment mutations replace a slot, preserve inventory, and can unequip", function()
	local f = fixture()
	local starter = assert(f.Service.Equip(7, EquipmentSlots.Weapon, "starter"))
	equal(starter.DefinitionId, StarterSword)
	equal(f.Records[7].Equipment[EquipmentSlots.Weapon], "starter")
	local upgraded = assert(f.Service.Equip(7, EquipmentSlots.Weapon, "upgraded"))
	equal(upgraded.EffectivenessTier, 2)
	equal(f.Records[7].Equipment[EquipmentSlots.Weapon], "upgraded")
	equal(f.Records[7].Inventory.Items.starter.DefinitionId, StarterSword)
	equal(f.Records[7].Gold, 25)
	equal(f.Records[7].SkillXP.skill_melee, 12)
	local unequipped = assert(f.Service.Unequip(7, EquipmentSlots.Weapon))
	equal(unequipped.InstanceId, "upgraded")
	equal(f.Records[7].Equipment[EquipmentSlots.Weapon], nil)
	local none, reason = f.Service.GetEquippedItem(7, EquipmentSlots.Weapon)
	equal(none, nil)
	equal(reason, "NotEquipped")
end)

test("equipment reads are copy-isolated", function()
	local f = fixture()
	assert(f.Service.Equip(7, EquipmentSlots.Tool, "basic_pickaxe"))
	local snapshot = assert(f.Service.GetSnapshot(7))
	snapshot[EquipmentSlots.Tool].InstanceId = "upgraded_pickaxe"
	snapshot[EquipmentSlots.Tool].EffectivenessTier = 99
	local equipped = assert(f.Service.GetEquippedItem(7, EquipmentSlots.Tool))
	equal(equipped.InstanceId, "basic_pickaxe")
	equal(equipped.EffectivenessTier, 1)
end)

test("invalid input and unavailable PlayerData do not mutate equipment", function()
	local f = fixture()
	for _, attempt in {
		function() return f.Service.Equip(7, "slot_unknown", "starter") end,
		function() return f.Service.Equip(0, EquipmentSlots.Weapon, "starter") end,
		function() return f.Service.Equip(7, EquipmentSlots.Weapon, "") end,
		function() return f.Service.Unequip(7, "slot_unknown") end,
		function() return f.Service.Unequip(0, EquipmentSlots.Weapon) end,
	} do
		local value, reason = attempt()
		equal(value, nil)
		assert(reason == "InvalidSlotId" or reason == "InvalidUserId" or reason == "InvalidInstanceId")
	end
	f.PlayerData.FailReason = "NotReady"
	local unavailable, unavailableReason = f.Service.Equip(7, EquipmentSlots.Weapon, "starter")
	equal(unavailable, nil)
	equal(unavailableReason, "NotReady")
	equal(next(f.Records[7].Equipment), nil)
end)

print(("%d Equipment checks passed"):format(passed))
