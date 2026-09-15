--!strict

local GatheringNodeIds = require("GatheringNodeIds")
local GatheringDefinitions = require("GatheringDefinitions")
local ItemDefinitions = require("ItemDefinitions")
local EquipmentSlots = require("EquipmentSlots")
local Inventory = require("InventoryService")
local Equipment = require("EquipmentService")
local SkillIds = require("SkillIds")
local SkillDefinitions = require("SkillDefinitions")
local Skills = require("SkillsService")
local Gathering = require("GatheringService")

local IronNode = "node_iron_ore"
local IronOre = "item_iron_ore"

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

local function curve()
	local thresholds = {}
	for level = 1, SkillDefinitions.LevelCap do
		thresholds[level] = (level - 1) * 100
	end
	return { MaximumXP = 6000, Thresholds = thresholds }
end

local function fixture()
	local records = {
		[7] = {
			Gold = 25,
			SkillXP = {
				[SkillIds.Melee] = 50,
				[SkillIds.Defense] = 0,
				[SkillIds.Mining] = 100,
				[SkillIds.Smithing] = 0,
			},
			Inventory = {
				Stacks = {},
				Items = {
					basic = { DefinitionId = "tool_pickaxe_basic" },
					upgraded = { DefinitionId = "tool_pickaxe_upgraded" },
					starter_sword = { DefinitionId = "weapon_sword_starter" },
				},
			},
			Equipment = { [EquipmentSlots.Tool] = "basic" },
			Plot = { Stations = {} },
			ProgressionFlags = { flag_intro_complete = true },
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
		local ok = pcall(change, candidate)
		if not ok then
			return false, "InvalidMutation"
		end
		records[userId] = candidate
		return true, nil
	end
	local nodes = {
		[IronNode] = { Eligible = true, Distance = 5 },
	}
	local function resolveNode(_, nodeId)
		local node = nodes[nodeId]
		if not node then
			return nil, "NodeNotFound"
		end
		return { Id = nodeId, Eligible = node.Eligible, Distance = node.Distance }, nil
	end
	local inventory = Inventory.New(playerData, { NewInstanceId = function() return "unused" end })
	local equipment = Equipment.New(playerData)
	local skills = Skills.New(playerData, { Curves = { curve_standard = curve() } })
	local service = Gathering.New(playerData, equipment, inventory, skills, resolveNode)
	return {
		Records = records,
		PlayerData = playerData,
		Nodes = nodes,
		Inventory = inventory,
		Equipment = equipment,
		Skills = skills,
		Service = service,
	}
end

test("Iron Ore uses a stable nondepleting gathering definition", function()
	local valid = GatheringDefinitions.Validate(GatheringDefinitions.ById)
	equal(valid, true)
	equal(GatheringNodeIds.ById[GatheringNodeIds.IronOre], true)
	local node = GatheringDefinitions.ById[IronNode]
	equal(node.Id, IronNode)
	equal(node.OutputItemId, IronOre)
	equal(node.SkillId, SkillIds.Mining)
	equal(node.RequiredMiningLevel, 1)
	equal(node.MaximumRange, 12)
	equal(node.IsDepleting, false)
end)

test("basic and upgraded pickaxes use centralized mining effectiveness", function()
	local basic = assert(ItemDefinitions.ById["tool_pickaxe_basic"].Mining)
	local upgraded = assert(ItemDefinitions.ById["tool_pickaxe_upgraded"].Mining)
	equal(ItemDefinitions.ById["tool_pickaxe_basic"].Equipment.SlotId, EquipmentSlots.Tool)
	equal(ItemDefinitions.ById["tool_pickaxe_upgraded"].Equipment.SlotId, EquipmentSlots.Tool)
	assert(basic.GatheringRateMultiplier < upgraded.GatheringRateMultiplier)
	local f = fixture()
	local basicResult = assert(f.Service.GatherForElapsed(7, IronNode, 2))
	equal(basicResult.OreAmount, 2)
	equal(basicResult.MiningXP, 4)
	assert(f.Equipment.Equip(7, EquipmentSlots.Tool, "upgraded"))
	local upgradedResult = assert(f.Service.GatherForElapsed(7, IronNode, 2))
	equal(upgradedResult.OreAmount, 4)
	equal(upgradedResult.MiningXP, 8)
	equal(f.Records[7].Inventory.Stacks[IronOre], 6)
	equal(f.Records[7].SkillXP[SkillIds.Mining], 112)
end)

test("gathering requires an equipped compatible Mining tool", function()
	local f = fixture()
	f.Records[7].Equipment[EquipmentSlots.Tool] = nil
	local missing, missingReason = f.Service.GatherForElapsed(7, IronNode, 2)
	equal(missing, nil)
	equal(missingReason, "NotEquipped")
	f.Records[7].Equipment[EquipmentSlots.Tool] = "starter_sword"
	local wrong, wrongReason = f.Service.GatherForElapsed(7, IronNode, 2)
	equal(wrong, nil)
	equal(wrongReason, "InvalidEquipment")
	equal(f.Records[7].Inventory.Stacks[IronOre], nil)
	-- Iron Ore requires Mining level 1, the floor every player starts at, so the "InsufficientMiningLevel"
	-- rejection path in Gathering/Service.luau has no reachable case with the current single resource;
	-- it remains in place for a future higher-tier node.
end)

test("a fresh level-1 Mining player can gather Iron Ore and begin earning Mining XP", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Mining] = 0
	equal(assert(f.Skills.GetState(7, SkillIds.Mining)).Level, 1)
	local result = assert(f.Service.GatherForElapsed(7, IronNode, 2))
	equal(result.OreAmount, 2)
	equal(result.MiningXP, 4)
	equal(result.TotalOre, 2)
	equal(f.Records[7].Inventory.Stacks[IronOre], 2)
	equal(f.Records[7].SkillXP[SkillIds.Mining], 4)
	equal(result.MiningState.Level, 1)
end)

test("trusted node eligibility, range, IDs, and elapsed bounds are validated", function()
	local f = fixture()
	for _, attempt in {
		function() return f.Service.GatherForElapsed(0, IronNode, 2) end,
		function() return f.Service.GatherForElapsed(7, "node_unknown", 2) end,
		function() return f.Service.GatherForElapsed(7, IronNode, 0) end,
		function() return f.Service.GatherForElapsed(7, IronNode, 0 / 0) end,
		function() return f.Service.GatherForElapsed(7, IronNode, Gathering.MaximumElapsedSeconds + 1) end,
	} do
		local result, reason = attempt()
		equal(result, nil)
		assert(reason == "InvalidUserId" or reason == "InvalidNodeId" or reason == "InvalidElapsedSeconds")
	end
	f.Nodes[IronNode].Eligible = false
	local ineligible, ineligibleReason = f.Service.GatherForElapsed(7, IronNode, 2)
	equal(ineligible, nil)
	equal(ineligibleReason, "IneligibleNode")
	f.Nodes[IronNode].Eligible = true
	f.Nodes[IronNode].Distance = GatheringDefinitions.ById[IronNode].MaximumRange + 0.01
	local distant, distantReason = f.Service.GatherForElapsed(7, IronNode, 2)
	equal(distant, nil)
	equal(distantReason, "NodeOutOfRange")
	equal(f.PlayerData.Calls, 0)
end)

test("continuous elapsed gathering awards ore and Mining XP while preserving unrelated state", function()
	local f = fixture()
	local before = copy(f.Records[7])
	local tooShort, tooShortReason = f.Service.GatherForElapsed(7, IronNode, 0.5)
	equal(tooShort, nil)
	equal(tooShortReason, "GatheringIntervalTooShort")
	local result = assert(f.Service.GatherForElapsed(7, IronNode, 3))
	equal(result.OreAmount, 3)
	equal(result.TotalOre, 3)
	equal(result.MiningXP, 6)
	equal(result.MiningState.XP, 106)
	equal(f.Records[7].Gold, before.Gold)
	equal(f.Records[7].SkillXP[SkillIds.Melee], before.SkillXP[SkillIds.Melee])
	equal(f.Records[7].ProgressionFlags.flag_intro_complete, true)
	equal(next(f.Records[7].Plot.Stations), nil)
end)

test("stack and XP failures roll back the combined gathering transaction", function()
	local f = fixture()
	f.Records[7].Inventory.Stacks[IronOre] = Inventory.MaximumStack
	local overflow, overflowReason = f.Service.GatherForElapsed(7, IronNode, 2)
	equal(overflow, nil)
	equal(overflowReason, "AmountOutOfBounds")
	equal(f.Records[7].Inventory.Stacks[IronOre], Inventory.MaximumStack)
	equal(f.Records[7].SkillXP[SkillIds.Mining], 100)
	f.Records[7].Inventory.Stacks[IronOre] = nil
	f.Records[7].SkillXP[SkillIds.Mining] = 6000
	local capped, cappedReason = f.Service.GatherForElapsed(7, IronNode, 2)
	equal(capped, nil)
	equal(cappedReason, "XPOutOfBounds")
	equal(f.Records[7].Inventory.Stacks[IronOre], nil)
	equal(f.Records[7].SkillXP[SkillIds.Mining], 6000)
end)

test("ValidateForBegin proves node/tool/level validity without awarding any ore or XP", function()
	local f = fixture()
	local before = copy(f.Records[7])
	local ok = assert(f.Service.ValidateForBegin(7, IronNode))
	equal(ok.NodeId, IronNode)
	equal(ok.ToolInstanceId, "basic")
	equal(ok.ToolDefinitionId, "tool_pickaxe_basic")
	equal(f.Records[7].Inventory.Stacks[IronOre], before.Inventory.Stacks[IronOre])
	equal(f.Records[7].SkillXP[SkillIds.Mining], before.SkillXP[SkillIds.Mining])
	equal(f.PlayerData.Calls, 0)
end)

test("ValidateForBegin rejects exactly what GatherForElapsed would reject, via the same checks", function()
	local f = fixture()
	f.Records[7].Equipment[EquipmentSlots.Tool] = nil
	local missing, missingReason = f.Service.ValidateForBegin(7, IronNode)
	equal(missing, nil)
	equal(missingReason, "NotEquipped")

	f.Records[7].Equipment[EquipmentSlots.Tool] = "basic"
	f.Nodes[IronNode].Eligible = false
	local ineligible, ineligibleReason = f.Service.ValidateForBegin(7, IronNode)
	equal(ineligible, nil)
	equal(ineligibleReason, "IneligibleNode")

	f.Nodes[IronNode].Eligible = true
	f.Nodes[IronNode].Distance = GatheringDefinitions.ById[IronNode].MaximumRange + 0.01
	local distant, distantReason = f.Service.ValidateForBegin(7, IronNode)
	equal(distant, nil)
	equal(distantReason, "NodeOutOfRange")
end)

print(("%d Gathering checks passed"):format(passed))
