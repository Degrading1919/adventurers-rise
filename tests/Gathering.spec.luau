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

local function fixture(miningModifiers)
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
	local service = Gathering.New(playerData, equipment, inventory, skills, resolveNode, miningModifiers)
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

test("Coal is a second stable gathering node, gated above iron and yielding its own resource", function()
	equal(GatheringNodeIds.ById[GatheringNodeIds.Coal], true)
	local coal = GatheringDefinitions.ById[GatheringNodeIds.Coal]
	equal(coal.Id, GatheringNodeIds.Coal)
	equal(coal.OutputItemId, "item_coal")
	equal(coal.SkillId, SkillIds.Mining)
	equal(coal.IsDepleting, false)
	assert(coal.RequiredMiningLevel > 1, "coal should be gated above the starting iron node")
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

-- ===== Mining Mastery: GatheringSpeedBonus + PrimaryYieldBonus =====
-- The fixture injects a provider standing in for Mastery.GetModifiers(userId, Mining). With the basic
-- pickaxe the base rate is 1 ore/s and 2 Mining XP/s, so a 2s gather yields 2 ore / 4 XP with no nodes.

test("no Mining selections preserve the exact base ore and XP", function()
	local f = fixture(function() return {} end)
	local result = assert(f.Service.GatherForElapsed(7, IronNode, 2))
	equal(result.OreAmount, 2)
	equal(result.MiningXP, 4)
end)

test("GatheringSpeedBonus raises both ore throughput and Mining XP per real second", function()
	local f = fixture(function() return { GatheringSpeedBonus = 0.5 } end)
	local result = assert(f.Service.GatherForElapsed(7, IronNode, 2))
	equal(result.OreAmount, 3) -- floor(1 * 1 * 2 * 1.5)
	equal(result.MiningXP, 6) -- 2 * 1 * 2 * 1.5
	equal(f.Records[7].Inventory.Stacks[IronOre], 3)
end)

test("PrimaryYieldBonus enriches ore output only and never inflates Mining XP", function()
	local f = fixture(function() return { PrimaryYieldBonus = 0.5 } end)
	local result = assert(f.Service.GatherForElapsed(7, IronNode, 2))
	equal(result.OreAmount, 3) -- floor(1 * 1 * 2 * 1.5)
	equal(result.MiningXP, 4) -- unchanged: yield does not touch XP
end)

test("speed and yield stack on ore per Mastery.GetModifiers while only speed affects XP", function()
	local f = fixture(function() return { GatheringSpeedBonus = 0.5, PrimaryYieldBonus = 0.5 } end)
	local result = assert(f.Service.GatherForElapsed(7, IronNode, 2))
	equal(result.OreAmount, 4) -- floor(1 * 1 * 2 * 1.5 * 1.5) == floor(4.5)
	equal(result.MiningXP, 6) -- 2 * 1 * 2 * 1.5
end)

test("Mining modifiers scale outputs deterministically without touching trusted elapsed time", function()
	-- Same trusted elapsed -> identical result every time (floor is deterministic, no RNG).
	local f = fixture(function() return { GatheringSpeedBonus = 0.5 } end)
	local first = assert(f.Service.GatherForElapsed(7, IronNode, 2))
	local second = assert(fixture(function() return { GatheringSpeedBonus = 0.5 } end).Service.GatherForElapsed(7, IronNode, 2))
	equal(first.OreAmount, second.OreAmount)
	equal(first.MiningXP, second.MiningXP)
	-- The elapsed cap is still enforced regardless of any bonus, so time cannot be inflated.
	local capped, cappedReason = f.Service.GatherForElapsed(7, IronNode, Gathering.MaximumElapsedSeconds + 1)
	equal(capped, nil)
	equal(cappedReason, "InvalidElapsedSeconds")
end)

test("spoofed or non-numeric Mining modifier values contribute no bonus", function()
	local f = fixture(function() return { GatheringSpeedBonus = "9", PrimaryYieldBonus = 0.5, Junk = 1 } end)
	local result = assert(f.Service.GatherForElapsed(7, IronNode, 2))
	equal(result.OreAmount, 3) -- string speed ignored; only the numeric yield applies
	equal(result.MiningXP, 4) -- speed string ignored, so XP stays at base
end)

test("a respec clearing Mining nodes restores base ore/XP immediately", function()
	local bonus = 0.5
	local f = fixture(function() return { GatheringSpeedBonus = bonus } end)
	equal(assert(f.Service.GatherForElapsed(7, IronNode, 2)).OreAmount, 3)
	bonus = 0
	equal(assert(f.Service.GatherForElapsed(7, IronNode, 2)).OreAmount, 2)
end)

test("a non-function Mining modifier provider is rejected", function()
	local ok = pcall(function()
		return fixture(5)
	end)
	equal(ok, false)
end)

-- ===== Deterministic fractional ore across settlements, using the REAL configured Mastery values =====
-- Base rate is 1 ore/s (Iron Ore 1 ore/s x basic pickaxe 1). The real per-node bonus is +0.02 and a
-- fully completed branch is +0.10. Flooring each ~1s settlement independently used to discard that
-- fraction entirely; a server-owned carry now makes cumulative ore a pure floor of cumulative
-- rate*elapsed, so repeated short settlements realize the same total as one equivalent long settlement.

local function repeatedOre(bonus, seconds, chunk)
	local f = fixture(function()
		return bonus
	end)
	local total = 0
	local remaining = seconds
	while remaining > 0 do
		local this = math.min(chunk, remaining)
		total += assert(f.Service.GatherForElapsed(7, IronNode, this)).OreAmount
		remaining -= this
	end
	return total
end

local function oneShotOre(bonus, seconds)
	return assert(fixture(function()
		return bonus
	end).Service.GatherForElapsed(7, IronNode, seconds)).OreAmount
end

test("real +10% GatheringSpeedBonus: 15x1s realizes the +1 extra ore and matches one 15s settlement", function()
	-- rate 1.10 over 15s -> floor(16.5) = 16 (base 15). Independent per-settlement flooring gives only 15.
	equal(repeatedOre({ GatheringSpeedBonus = 0.10 }, 15, 1), 16)
	equal(oneShotOre({ GatheringSpeedBonus = 0.10 }, 15), 16)
	equal(oneShotOre({}, 15), 15) -- no-Mastery baseline
end)

test("real +2% PrimaryYieldBonus: 60x1s realizes the +1 extra ore and matches one 60s settlement", function()
	-- rate 1.02 over 60s -> floor(61.2) = 61 (base 60). At ~1s chunks the old code produced only 60.
	equal(repeatedOre({ PrimaryYieldBonus = 0.02 }, 60, 1), 61)
	equal(oneShotOre({ PrimaryYieldBonus = 0.02 }, 60), 61)
	equal(oneShotOre({}, 60), 60)
end)

test("cumulative ore is chunk-size independent for a real +2% bonus (1s vs 5s vs one 60s)", function()
	equal(repeatedOre({ GatheringSpeedBonus = 0.02 }, 60, 1), 61)
	equal(repeatedOre({ GatheringSpeedBonus = 0.02 }, 60, 5), 61)
	equal(repeatedOre({ GatheringSpeedBonus = 0.02 }, 60, 60), 61)
end)

test("ResetCarry drops the in-progress fraction so a fresh session starts clean", function()
	local f = fixture(function()
		return { GatheringSpeedBonus = 0.10 }
	end)
	-- Accrue a partial carry (rate 1.10 over 1s -> 1 ore, 0.10 carried).
	equal(assert(f.Service.GatherForElapsed(7, IronNode, 1)).OreAmount, 1)
	f.Service.ResetCarry(7)
	-- With the carry cleared, five 1s settlements yield floor(1.10*5)=5, not 6 (no inherited 0.10).
	local total = 0
	for _ = 1, 5 do
		total += assert(f.Service.GatherForElapsed(7, IronNode, 1)).OreAmount
	end
	equal(total, 5)
end)

print(("%d Gathering checks passed"):format(passed))
