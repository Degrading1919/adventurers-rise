--!strict

local MasteryIds = require("MasteryIds")
local SkillIds = require("SkillIds")
local MasteryDefinitions = require("MasteryDefinitions")
local Mastery = require("MasteryService")
local SkillDefinitions = require("SkillDefinitions")
local Skills = require("SkillsService")
local Economy = require("EconomyService")

local MeleeMight = MasteryIds.Nodes.MeleeMight
local MeleeTempo = MasteryIds.Nodes.MeleeTempo
local DefenseFortitude = MasteryIds.Nodes.DefenseFortitude
local MiningExcavation = MasteryIds.Nodes.MiningExcavation

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

local function xpForLevel(level)
	return (level - 1) * 100
end

local function fixture()
	local records = {
		[7] = {
			Gold = 500,
			SkillXP = {
				[SkillIds.Melee] = 0,
				[SkillIds.Defense] = 0,
				[SkillIds.Mining] = 0,
				[SkillIds.Smithing] = 0,
			},
			MasterySelections = {
				[SkillIds.Melee] = {},
				[SkillIds.Defense] = {},
				[SkillIds.Mining] = {},
				[SkillIds.Smithing] = {},
			},
			MasteryRespecs = {
				[SkillIds.Melee] = false,
				[SkillIds.Defense] = false,
				[SkillIds.Mining] = false,
				[SkillIds.Smithing] = false,
			},
			Inventory = { Stacks = {}, Items = {} },
			Equipment = {},
			ProgressionFlags = {},
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
	local skills = Skills.New(playerData, { Curves = { curve_standard = curve() } })
	local economy = Economy.New(playerData, { NewInstanceId = function() return "unused" end })
	local mastery = Mastery.New(playerData, skills, economy)
	return { Records = records, PlayerData = playerData, Skills = skills, Economy = economy, Service = mastery }
end

test("all four slice skills have exactly 3 branches x 4 nodes with 48 unique stable node IDs", function()
	local valid = MasteryDefinitions.Validate(MasteryDefinitions.ById)
	equal(valid, true)
	local skillIds = { SkillIds.Melee, SkillIds.Defense, SkillIds.Mining, SkillIds.Smithing }
	local allNodeIds = {}
	local nodeCount = 0
	for _, skillId in skillIds do
		local tree = assert(MasteryDefinitions.ById[skillId])
		equal(#tree.Branches, 3)
		for _, branchDef in tree.Branches do
			equal(#branchDef.Nodes, 4)
			for position, node in branchDef.Nodes do
				equal(node.Position, position)
				equal(node.PointCost, 1)
				equal(node.SkillId, skillId)
				equal(node.BranchId, branchDef.Id)
				assert(not allNodeIds[node.Id])
				allNodeIds[node.Id] = true
				nodeCount += 1
			end
		end
	end
	equal(nodeCount, 48)
end)

test("branch identities match the approved design", function()
	local function sortedNames(skillId)
		local names = {}
		for _, branchDef in MasteryDefinitions.ById[skillId].Branches do
			table.insert(names, branchDef.DisplayName)
		end
		table.sort(names)
		return names
	end
	local melee = sortedNames(SkillIds.Melee)
	equal(melee[1], "Cleave")
	equal(melee[2], "Might")
	equal(melee[3], "Tempo")
	local defense = sortedNames(SkillIds.Defense)
	equal(defense[1], "Bulwark")
	equal(defense[2], "Fortitude")
	equal(defense[3], "Resilience")
	local mining = sortedNames(SkillIds.Mining)
	equal(mining[1], "Excavation")
	equal(mining[2], "Extraction")
	equal(mining[3], "Prospecting")
	local smithing = sortedNames(SkillIds.Smithing)
	equal(smithing[1], "Forgemaster")
	equal(smithing[2], "Merchant Smith")
	equal(smithing[3], "Smelter")
end)

test("level gates follow the agreed branch-depth cadence and effect metadata stays conservative", function()
	local mightBranch = MasteryDefinitions.BranchesById[MasteryIds.Branches.MeleeMight]
	equal(mightBranch.Nodes[1].RequiredLevel, 5)
	equal(mightBranch.Nodes[2].RequiredLevel, 15)
	equal(mightBranch.Nodes[3].RequiredLevel, 30)
	equal(mightBranch.Nodes[4].RequiredLevel, 50)
	local total = 0
	for _, node in mightBranch.Nodes do
		equal(node.Effect.Type, "MeleeDamageBonus")
		assert(node.Effect.Value > 0 and node.Effect.Value <= 1)
		total += node.Effect.Value
	end
	-- Well short of anything close to a 2x overall-performance increase from one branch.
	assert(total <= 0.15)
end)

test("malformed mastery trees are rejected by Validate", function()
	local validTree = MasteryDefinitions.ById[SkillIds.Melee]
	local function withBranches(branches)
		return { [SkillIds.Melee] = { SkillId = SkillIds.Melee, Branches = branches } }
	end
	equal(MasteryDefinitions.Validate("not a table"), false)
	equal(MasteryDefinitions.Validate(withBranches({})), false)
	equal(MasteryDefinitions.Validate(withBranches({ validTree.Branches[1], validTree.Branches[2] })), false)
	local dupPositionBranch = {
		Id = validTree.Branches[1].Id,
		SkillId = SkillIds.Melee,
		DisplayName = "Might",
		Nodes = { validTree.Branches[1].Nodes[1], validTree.Branches[1].Nodes[1], validTree.Branches[1].Nodes[3], validTree.Branches[1].Nodes[4] },
	}
	equal(MasteryDefinitions.Validate(withBranches({ dupPositionBranch, validTree.Branches[2], validTree.Branches[3] })), false)
	equal(MasteryDefinitions.Validate({ skill_unknown = validTree }), false)
end)

test("earned Mastery Points follow the exact cadence at every boundary, capped at 8", function()
	local f = fixture()
	local boundaries = {
		{ 1, 0 },
		{ 4, 0 },
		{ 5, 1 },
		{ 9, 1 },
		{ 10, 2 },
		{ 14, 2 },
		{ 15, 3 },
		{ 19, 3 },
		{ 20, 4 },
		{ 29, 4 },
		{ 30, 5 },
		{ 39, 5 },
		{ 40, 6 },
		{ 49, 6 },
		{ 50, 7 },
		{ 59, 7 },
		{ 60, 8 },
	}
	for _, pair in boundaries do
		local level, expected = pair[1], pair[2]
		f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(level)
		equal(assert(f.Service.GetEarnedPoints(7, SkillIds.Melee)), expected)
	end
end)

test("selecting the first branch node requires exactly its level gate", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(4)
	local tooLow, tooLowReason = f.Service.Select(7, SkillIds.Melee, MeleeMight[1])
	equal(tooLow, nil)
	equal(tooLowReason, "InsufficientSkillLevel")
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	local result = assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	equal(result.NodeId, MeleeMight[1])
	equal(result.SpentPoints, 1)
	equal(result.AvailablePoints, 0)
	equal(f.Records[7].MasterySelections[SkillIds.Melee][MeleeMight[1]], true)
end)

test("nodes must be purchased sequentially within a branch", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(15)
	local skip, skipReason = f.Service.Select(7, SkillIds.Melee, MeleeMight[2])
	equal(skip, nil)
	equal(skipReason, "PrerequisiteNodeNotSelected")
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	local second = assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[2]))
	equal(second.SpentPoints, 2)
end)

test("selecting an already-selected node is rejected", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	local duplicate, duplicateReason = f.Service.Select(7, SkillIds.Melee, MeleeMight[1])
	equal(duplicate, nil)
	equal(duplicateReason, "NodeAlreadySelected")
end)

test("selecting beyond earned points is rejected without partial mutation", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	local overspend, overspendReason = f.Service.Select(7, SkillIds.Melee, MeleeTempo[1])
	equal(overspend, nil)
	equal(overspendReason, "InsufficientMasteryPoints")
	equal(f.Records[7].MasterySelections[SkillIds.Melee][MeleeTempo[1]], nil)
end)

test("a node belonging to a different skill and other invalid IDs are rejected", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Defense] = xpForLevel(5)
	local wrongSkill, wrongSkillReason = f.Service.Select(7, SkillIds.Defense, MeleeMight[1])
	equal(wrongSkill, nil)
	equal(wrongSkillReason, "InvalidNodeId")
	local invalidSkill, invalidSkillReason = f.Service.Select(7, "skill_unknown", MeleeMight[1])
	equal(invalidSkill, nil)
	equal(invalidSkillReason, "InvalidSkillId")
	local invalidNode, invalidNodeReason = f.Service.Select(7, SkillIds.Melee, "node_unknown")
	equal(invalidNode, nil)
	equal(invalidNodeReason, "InvalidNodeId")
	local invalidUser, invalidUserReason = f.Service.Select(0, SkillIds.Melee, MeleeMight[1])
	equal(invalidUser, nil)
	equal(invalidUserReason, "InvalidUserId")
end)

test("points earned by one skill cannot be spent in another", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	f.Records[7].SkillXP[SkillIds.Mining] = xpForLevel(5)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	equal(assert(f.Service.GetAvailablePoints(7, SkillIds.Mining)), 1)
	assert(f.Service.Select(7, SkillIds.Mining, MiningExcavation[1]))
	equal(assert(f.Service.GetAvailablePoints(7, SkillIds.Melee)), 0)
	equal(assert(f.Service.GetAvailablePoints(7, SkillIds.Mining)), 0)
end)

test("selecting a node preserves unrelated PlayerData", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	local before = copy(f.Records[7])
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	equal(f.Records[7].Gold, before.Gold)
	equal(f.Records[7].SkillXP[SkillIds.Defense], before.SkillXP[SkillIds.Defense])
	equal(next(f.Records[7].MasterySelections[SkillIds.Defense]), nil)
	equal(next(f.Records[7].Inventory.Stacks), nil)
end)

test("malformed persisted mastery selections fail closed", function()
	local gapped = fixture()
	gapped.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(30)
	gapped.Records[7].MasterySelections[SkillIds.Melee][MeleeMight[3]] = true
	local gappedState, gappedReason = gapped.Service.GetState(7, SkillIds.Melee)
	equal(gappedState, nil)
	equal(gappedReason, "InvalidMasteryState")

	local unknownNode = fixture()
	unknownNode.Records[7].MasterySelections[SkillIds.Melee].not_a_real_node = true
	local unknownState, unknownReason = unknownNode.Service.GetState(7, SkillIds.Melee)
	equal(unknownState, nil)
	equal(unknownReason, "InvalidMasteryState")

	local overspent = fixture()
	overspent.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	overspent.Records[7].MasterySelections[SkillIds.Melee][MeleeMight[1]] = true
	overspent.Records[7].MasterySelections[SkillIds.Melee][MeleeTempo[1]] = true
	local overspentState, overspentReason = overspent.Service.GetState(7, SkillIds.Melee)
	equal(overspentState, nil)
	equal(overspentReason, "InvalidMasteryState")
end)

test("selected node IDs survive a PlayerData copy/save round trip", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	local snapshot = copy(f.Records[7])
	equal(snapshot.MasterySelections[SkillIds.Melee][MeleeMight[1]], true)
	snapshot.MasterySelections[SkillIds.Melee][MeleeMight[1]] = nil
	equal(f.Records[7].MasterySelections[SkillIds.Melee][MeleeMight[1]], true)
end)

test("respec history persists across a simulated leave and rejoin", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	assert(f.Service.Respec(7, SkillIds.Melee))
	-- A brand-new Mastery/Skills/Economy composition bound to the same persisted records
	-- simulates rejoining a fresh session against the same save.
	local skills2 = Skills.New(f.PlayerData, { Curves = { curve_standard = curve() } })
	local economy2 = Economy.New(f.PlayerData, { NewInstanceId = function() return "unused" end })
	local mastery2 = Mastery.New(f.PlayerData, skills2, economy2)
	local state = assert(mastery2.GetState(7, SkillIds.Melee))
	equal(state.FreeRespecAvailable, false)
end)

test("no selected nodes yields a neutral (empty) modifier result", function()
	local f = fixture()
	local modifiers = assert(f.Service.GetModifiers(7, SkillIds.Melee))
	equal(next(modifiers), nil)
end)

test("selected mastery nodes aggregate modifiers additively, per skill, without mutating shared state", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(15)
	f.Records[7].SkillXP[SkillIds.Mining] = xpForLevel(5)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[2]))
	assert(f.Service.Select(7, SkillIds.Mining, MiningExcavation[1]))

	local meleeModifiers = assert(f.Service.GetModifiers(7, SkillIds.Melee))
	equal(meleeModifiers.MeleeDamageBonus, 0.04)
	equal(meleeModifiers.GatheringSpeedBonus, nil)

	local miningModifiers = assert(f.Service.GetModifiers(7, SkillIds.Mining))
	equal(miningModifiers.GatheringSpeedBonus, 0.02)
	equal(miningModifiers.MeleeDamageBonus, nil)

	meleeModifiers.MeleeDamageBonus = 999
	local meleeAgain = assert(f.Service.GetModifiers(7, SkillIds.Melee))
	equal(meleeAgain.MeleeDamageBonus, 0.04)
	equal(MasteryDefinitions.NodesById[MeleeMight[1]].Effect.Value, 0.02)
end)

test("modifiers from different branches of the same skill combine into distinct keys", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(10)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	assert(f.Service.Select(7, SkillIds.Melee, MeleeTempo[1]))
	local modifiers = assert(f.Service.GetModifiers(7, SkillIds.Melee))
	equal(modifiers.MeleeDamageBonus, 0.02)
	equal(modifiers.MeleeAttackIntervalReduction, 0.02)
end)

test("the first respec per skill is free and clears only that skill's selections", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	f.Records[7].SkillXP[SkillIds.Defense] = xpForLevel(5)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	assert(f.Service.Select(7, SkillIds.Defense, DefenseFortitude[1]))

	local result = assert(f.Service.Respec(7, SkillIds.Melee))
	equal(result.WasFree, true)
	equal(result.GoldCost, 0)
	equal(#result.ClearedNodeIds, 1)
	equal(result.ClearedNodeIds[1], MeleeMight[1])
	equal(next(f.Records[7].MasterySelections[SkillIds.Melee]), nil)

	-- Defense's own selection and its own free respec remain untouched.
	equal(f.Records[7].MasterySelections[SkillIds.Defense][DefenseFortitude[1]], true)
	equal(assert(f.Service.GetState(7, SkillIds.Defense)).FreeRespecAvailable, true)
	equal(assert(f.Service.GetState(7, SkillIds.Melee)).FreeRespecAvailable, false)
end)

test("a later respec debits the centralized Gold cost and clears selections atomically", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(15)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[2]))
	assert(f.Service.Respec(7, SkillIds.Melee))

	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	local before = f.Records[7].Gold
	local expectedCost = MasteryDefinitions.RespecGoldCost(1)
	local result = assert(f.Service.Respec(7, SkillIds.Melee))
	equal(result.WasFree, false)
	equal(result.GoldCost, expectedCost)
	equal(f.Records[7].Gold, before - expectedCost)
	equal(next(f.Records[7].MasterySelections[SkillIds.Melee]), nil)
end)

test("insufficient Gold for a paid respec fails without mutating anything", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	assert(f.Service.Respec(7, SkillIds.Melee))
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	f.Records[7].Gold = 0
	local before = copy(f.Records[7])
	local result, reason = f.Service.Respec(7, SkillIds.Melee)
	equal(result, nil)
	equal(reason, "InsufficientGold")
	equal(f.Records[7].Gold, before.Gold)
	equal(f.Records[7].MasterySelections[SkillIds.Melee][MeleeMight[1]], true)
	equal(f.Records[7].MasteryRespecs[SkillIds.Melee], before.MasteryRespecs[SkillIds.Melee])
end)

test("respec never touches XP or unrelated PlayerData", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	local before = copy(f.Records[7])
	assert(f.Service.Respec(7, SkillIds.Melee))
	equal(f.Records[7].SkillXP[SkillIds.Melee], before.SkillXP[SkillIds.Melee])
	equal(f.Records[7].SkillXP[SkillIds.Defense], before.SkillXP[SkillIds.Defense])
	equal(next(f.Records[7].Equipment), nil)
	equal(next(f.Records[7].Inventory.Stacks), nil)
end)

test("a respec with no selected nodes is rejected and leaves PlayerData unchanged", function()
	local unusedFree = fixture()
	local beforeUnused = copy(unusedFree.Records[7])
	local unusedResult, unusedReason = unusedFree.Service.Respec(7, SkillIds.Melee)
	equal(unusedResult, nil)
	equal(unusedReason, "NoMasterySelections")
	equal(unusedFree.Records[7].Gold, beforeUnused.Gold)
	equal(next(unusedFree.Records[7].MasterySelections[SkillIds.Melee]), nil)
	equal(unusedFree.Records[7].MasteryRespecs[SkillIds.Melee], beforeUnused.MasteryRespecs[SkillIds.Melee])

	local usedFree = fixture()
	usedFree.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	assert(usedFree.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	assert(usedFree.Service.Respec(7, SkillIds.Melee))
	local beforeUsed = copy(usedFree.Records[7])
	local usedResult, usedReason = usedFree.Service.Respec(7, SkillIds.Melee)
	equal(usedResult, nil)
	equal(usedReason, "NoMasterySelections")
	equal(usedFree.Records[7].Gold, beforeUsed.Gold)
	equal(next(usedFree.Records[7].MasterySelections[SkillIds.Melee]), nil)
	equal(usedFree.Records[7].MasteryRespecs[SkillIds.Melee], beforeUsed.MasteryRespecs[SkillIds.Melee])
end)

test("the read model never reports a payable respec cost when nothing is selected", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	assert(f.Service.Respec(7, SkillIds.Melee))
	local state = assert(f.Service.GetState(7, SkillIds.Melee))
	equal(state.FreeRespecAvailable, false)
	equal(state.SpentPoints, 0)
	equal(state.NextRespecGoldCost, 0)
end)

test("GetAvailablePoints derives earned and spent from one consistent snapshot", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(15)
	assert(f.Service.Select(7, SkillIds.Melee, MeleeMight[1]))
	local earned = assert(f.Service.GetEarnedPoints(7, SkillIds.Melee))
	local spent = assert(f.Service.GetSpentPoints(7, SkillIds.Melee))
	local available = assert(f.Service.GetAvailablePoints(7, SkillIds.Melee))
	equal(available, earned - spent)
	equal(available, 2)
end)

test("malformed or missing persisted respec history fails closed instead of defaulting to unused", function()
	local missing = fixture()
	missing.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	missing.Records[7].MasterySelections[SkillIds.Melee][MeleeMight[1]] = true
	missing.Records[7].MasteryRespecs[SkillIds.Melee] = nil
	local missingState, missingReason = missing.Service.GetState(7, SkillIds.Melee)
	equal(missingState, nil)
	equal(missingReason, "InvalidMasteryRespecState")
	local missingRespec, missingRespecReason = missing.Service.Respec(7, SkillIds.Melee)
	equal(missingRespec, nil)
	equal(missingRespecReason, "InvalidMasteryRespecState")
	equal(missing.Records[7].MasterySelections[SkillIds.Melee][MeleeMight[1]], true)

	local malformed = fixture()
	malformed.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(5)
	malformed.Records[7].MasterySelections[SkillIds.Melee][MeleeMight[1]] = true
	malformed.Records[7].MasteryRespecs[SkillIds.Melee] = "not_a_boolean"
	local malformedState, malformedReason = malformed.Service.GetState(7, SkillIds.Melee)
	equal(malformedState, nil)
	equal(malformedReason, "InvalidMasteryRespecState")
	local malformedRespec, malformedRespecReason = malformed.Service.Respec(7, SkillIds.Melee)
	equal(malformedRespec, nil)
	equal(malformedRespecReason, "InvalidMasteryRespecState")
	equal(malformed.Records[7].MasterySelections[SkillIds.Melee][MeleeMight[1]], true)
end)

print(("%d Mastery checks passed"):format(passed))
