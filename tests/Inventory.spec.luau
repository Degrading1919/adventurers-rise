--!strict

local ItemDefinitions = require("ItemDefinitions")
local EquipmentSlots = require("EquipmentSlots")
local Inventory = require("Service")

local Ore = "item_iron_ore"
local Bar = "item_iron_bar"
local StarterSword = "weapon_sword_starter"
local BasicPickaxe = "tool_pickaxe_basic"

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

local function fixture(ids)
	local records = {
		[7] = {
			Gold = 25,
			Inventory = { Stacks = {}, Items = {} },
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
	local nextId = 0
	local service = Inventory.New(playerData, {
		NewInstanceId = function()
			nextId += 1
			return (ids and ids[nextId]) or ("instance_" .. nextId)
		end,
	})
	return { PlayerData = playerData, Records = records, Service = service }
end

test("definitions contain only the required classified slice items", function()
	local expected = {
		[Ore] = "Stackable",
		[Bar] = "Stackable",
		[StarterSword] = "Discrete",
		weapon_sword_upgraded = "Discrete",
		[BasicPickaxe] = "Discrete",
		tool_pickaxe_upgraded = "Discrete",
	}
	local count = 0
	for id, definition in ItemDefinitions.ById do
		equal(definition.Id, id)
		equal(definition.Kind, expected[id])
		count += 1
	end
	equal(count, 6)
	equal(ItemDefinitions.ById[StarterSword].Equipment.SlotId, EquipmentSlots.Weapon)
	equal(ItemDefinitions.ById[BasicPickaxe].Equipment.SlotId, EquipmentSlots.Tool)
end)

test("trusted stack mutations preserve unrelated PlayerData state", function()
	local f = fixture()
	equal(assert(f.Service.AddStack(7, Ore, 5)), 5)
	equal(assert(f.Service.AddStack(7, Ore, 4)), 9)
	equal(assert(f.Service.GetStackCount(7, Ore)), 9)
	equal(assert(f.Service.RemoveStack(7, Ore, 3)), 6)
	equal(f.Records[7].Inventory.Stacks[Ore], 6)
	equal(f.Records[7].Gold, 25)
	equal(next(f.Records[7].Equipment), nil)
	equal(f.PlayerData.Calls, 3)
	equal(assert(f.Service.RemoveStack(7, Ore, 6)), 0)
	equal(f.Records[7].Inventory.Stacks[Ore], nil)
end)

test("discrete items receive server-generated instance IDs and remain independently owned", function()
	local f = fixture({ "instance_sword", "instance_pickaxe" })
	local sword = assert(f.Service.AddDiscreteItem(7, StarterSword))
	local pickaxe = assert(f.Service.AddDiscreteItem(7, BasicPickaxe))
	equal(sword.InstanceId, "instance_sword")
	equal(sword.DefinitionId, StarterSword)
	equal(pickaxe.InstanceId, "instance_pickaxe")
	equal(f.Records[7].Inventory.Items.instance_sword.DefinitionId, StarterSword)
	equal(assert(f.Service.GetDiscreteItem(7, "instance_sword")).DefinitionId, StarterSword)
	local removed = assert(f.Service.RemoveDiscreteItem(7, "instance_sword"))
	equal(removed.DefinitionId, StarterSword)
	equal(f.Records[7].Inventory.Items.instance_sword, nil)
	equal(assert(f.Service.GetDiscreteItem(7, "instance_pickaxe")).DefinitionId, BasicPickaxe)
end)

test("reads are isolated from stored inventory", function()
	local f = fixture({ "instance_sword" })
	assert(f.Service.AddStack(7, Bar, 2))
	assert(f.Service.AddDiscreteItem(7, StarterSword))
	local snapshot = assert(f.Service.GetSnapshot(7))
	snapshot.Stacks[Bar] = 999
	snapshot.Items.instance_sword.DefinitionId = "tool_pickaxe_basic"
	equal(assert(f.Service.GetStackCount(7, Bar)), 2)
	equal(assert(f.Service.GetDiscreteItem(7, "instance_sword")).DefinitionId, StarterSword)
	local item = assert(f.Service.GetDiscreteItem(7, "instance_sword"))
	item.DefinitionId = BasicPickaxe
	equal(assert(f.Service.GetDiscreteItem(7, "instance_sword")).DefinitionId, StarterSword)
end)

test("invalid definitions, amounts, and ownership checks do not mutate PlayerData", function()
	local f = fixture()
	for _, attempt in {
		function() return f.Service.AddStack(7, StarterSword, 1) end,
		function() return f.Service.AddDiscreteItem(7, Ore) end,
		function() return f.Service.AddStack(7, "item_unknown", 1) end,
		function() return f.Service.AddStack(7, Ore, 0) end,
		function() return f.Service.AddStack(7, Ore, -1) end,
		function() return f.Service.AddStack(7, Ore, 1.5) end,
		function() return f.Service.RemoveStack(7, Ore, 1) end,
		function() return f.Service.RemoveDiscreteItem(7, "not_owned") end,
	} do
		local value, reason = attempt()
		equal(value, nil)
		assert(reason == "InvalidItemDefinitionId" or reason == "InvalidAmount" or reason == "InsufficientItems" or reason == "ItemNotOwned")
	end
	equal(f.PlayerData.Calls, 2) -- Underflow and missing ownership are validated inside PlayerData mutations.
	equal(next(f.Records[7].Inventory.Stacks), nil)
	equal(next(f.Records[7].Inventory.Items), nil)
end)

test("overflow, underflow, collisions, and PlayerData failures preserve inventory", function()
	local f = fixture({ "collision", "instance_ok" })
	f.Records[7].Inventory.Stacks[Ore] = Inventory.MaximumStack
	local overflow, overflowReason = f.Service.AddStack(7, Ore, 1)
	equal(overflow, nil)
	equal(overflowReason, "AmountOutOfBounds")
	equal(f.Records[7].Inventory.Stacks[Ore], Inventory.MaximumStack)
	f.Records[7].Inventory.Items.collision = { DefinitionId = StarterSword }
	local collision, collisionReason = f.Service.AddDiscreteItem(7, StarterSword)
	equal(collision, nil)
	equal(collisionReason, "InstanceIdCollision")
	equal(f.Records[7].Inventory.Items.collision.DefinitionId, StarterSword)
	f.PlayerData.FailReason = "NotReady"
	local unavailable, unavailableReason = f.Service.AddStack(7, Ore, 1)
	equal(unavailable, nil)
	equal(unavailableReason, "NotReady")
	equal(f.Records[7].Inventory.Stacks[Ore], Inventory.MaximumStack)
end)

test("equipped discrete items cannot be removed", function()
	local f = fixture({ "instance_sword" })
	assert(f.Service.AddDiscreteItem(7, StarterSword))
	f.Records[7].Equipment[EquipmentSlots.Weapon] = "instance_sword"
	local removed, reason = f.Service.RemoveDiscreteItem(7, "instance_sword")
	equal(removed, nil)
	equal(reason, "ItemEquipped")
	equal(f.Records[7].Inventory.Items.instance_sword.DefinitionId, StarterSword)
end)

print(("%d Inventory checks passed"):format(passed))
