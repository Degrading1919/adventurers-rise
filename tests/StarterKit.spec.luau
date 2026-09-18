--!strict

local EquipmentSlots = require("EquipmentSlots")
local ProgressionFlagIds = require("ProgressionFlagIds")
local Inventory = require("InventoryService")
local Equipment = require("EquipmentService")
local StarterKit = require("StarterKitService")

local StarterSword = "weapon_sword_starter"
local BasicPickaxe = "tool_pickaxe_basic"
local UpgradedSword = "weapon_sword_upgraded"
local FLAG = ProgressionFlagIds.StarterKitGranted

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

-- Fresh player record: no flag, empty inventory, nothing equipped.
local function freshRecord()
	return {
		Gold = 0,
		ProgressionFlags = {},
		Inventory = { Stacks = {}, Items = {} },
		Equipment = {},
	}
end

-- Minimal trusted PlayerData boundary mirroring the real one: mutations run against a copy and only
-- commit if the change function returns without error, so an aborted grant rolls back completely.
local function newPlayerData(records)
	local playerData = {}
	function playerData.GetSnapshot(userId)
		return if records[userId] then copy(records[userId]) else nil
	end
	function playerData.Update(userId, change)
		local candidate = copy(records[userId])
		if not candidate then
			return false, "NotReady"
		end
		local ok = pcall(change, candidate)
		if not ok then
			return false, "InvalidMutation"
		end
		records[userId] = candidate
		return true, nil
	end
	return playerData
end

-- Builds a service stack over the given records. `newInstanceId` lets a test force a discrete-item
-- creation failure. A "rejoin" is modelled by calling this again with the SAME records table.
local function stack(records, newInstanceId)
	local serial = 0
	local generator = newInstanceId
		or function()
			serial += 1
			return "instance_" .. serial
		end
	local playerData = newPlayerData(records)
	local inventory = Inventory.New(playerData, { NewInstanceId = generator })
	local equipment = Equipment.New(playerData)
	local service = StarterKit.New(playerData, inventory, equipment)
	return { PlayerData = playerData, Inventory = inventory, Equipment = equipment, Service = service }
end

local function countByDefinition(record, definitionId)
	local count = 0
	for _, item in record.Inventory.Items do
		if item.DefinitionId == definitionId then
			count += 1
		end
	end
	return count
end

test("fresh player: grants the starter sword and pickaxe, equips both, and sets the persistent flag", function()
	local records = { [7] = freshRecord() }
	local s = stack(records)
	local summary = assert(s.Service.EnsureForUser(7))
	equal(summary.Granted, true)
	equal(summary.Equipped[EquipmentSlots.Weapon], true)
	equal(summary.Equipped[EquipmentSlots.Tool], true)
	equal(records[7].ProgressionFlags[FLAG], true)
	equal(countByDefinition(records[7], StarterSword), 1)
	equal(countByDefinition(records[7], BasicPickaxe), 1)
	local weapon = assert(s.Equipment.GetEquippedItem(7, EquipmentSlots.Weapon))
	equal(weapon.DefinitionId, StarterSword)
	local tool = assert(s.Equipment.GetEquippedItem(7, EquipmentSlots.Tool))
	equal(tool.DefinitionId, BasicPickaxe)
end)

test("calling EnsureForUser again never grants a second kit", function()
	local records = { [7] = freshRecord() }
	local s = stack(records)
	assert(s.Service.EnsureForUser(7))
	local second = assert(s.Service.EnsureForUser(7))
	equal(second.Granted, false)
	equal(countByDefinition(records[7], StarterSword), 1)
	equal(countByDefinition(records[7], BasicPickaxe), 1)
end)

test("a rejoin (fresh service stack over the persisted record) does not duplicate the kit", function()
	local records = { [7] = freshRecord() }
	assert(stack(records).Service.EnsureForUser(7))
	-- New server session, same persisted data: the flag already set must suppress a second grant.
	local rejoined = assert(stack(records).Service.EnsureForUser(7))
	equal(rejoined.Granted, false)
	equal(countByDefinition(records[7], StarterSword), 1)
	equal(countByDefinition(records[7], BasicPickaxe), 1)
end)

test("already-equipped upgraded gear is preserved; the starter sword is not force-re-equipped", function()
	local records = { [7] = freshRecord() }
	local s = stack(records)
	assert(s.Service.EnsureForUser(7))
	-- Player later smiths and equips the upgraded sword into the weapon slot.
	local upgraded = assert(s.Inventory.AddDiscreteItem(7, UpgradedSword))
	assert(s.Equipment.Equip(7, EquipmentSlots.Weapon, upgraded.InstanceId))
	-- A later ready session runs the kit again; it must not revert the weapon slot to the starter.
	local again = assert(s.Service.EnsureForUser(7))
	equal(again.Granted, false)
	local weapon = assert(s.Equipment.GetEquippedItem(7, EquipmentSlots.Weapon))
	equal(weapon.DefinitionId, UpgradedSword)
end)

test("a grant that fails partway commits nothing: no flag, no partial items", function()
	local records = { [7] = freshRecord() }
	-- Succeed for the sword, fail for the pickaxe: the whole transaction must roll back.
	local calls = 0
	local s = stack(records, function()
		calls += 1
		if calls == 1 then
			return "instance_only"
		end
		return "" -- invalid id -> AddDiscreteItemToData fails -> StarterKit aborts
	end)
	local summary, reason = s.Service.EnsureForUser(7)
	equal(summary, nil)
	assert(reason ~= nil, "a failed grant must report a reason")
	equal(records[7].ProgressionFlags[FLAG], nil)
	equal(countByDefinition(records[7], StarterSword), 0)
	equal(countByDefinition(records[7], BasicPickaxe), 0)
	equal(next(records[7].Inventory.Items), nil)
end)

print(("%d StarterKit checks passed"):format(passed))
