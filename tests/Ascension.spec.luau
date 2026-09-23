--!strict

local AscensionIds = require("AscensionIds")
local ProgressionFlagIds = require("ProgressionFlagIds")
local AscensionDefinitions = require("AscensionDefinitions")
local SkillIds = require("SkillIds")
local SkillDefinitions = require("SkillDefinitions")
local Skills = require("SkillsService")
local Ascension = require("AscensionService")

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

-- XP needed to reach a given level under the test curve above (level 1 == 0 XP).
local function xpForLevel(level)
	return (level - 1) * 100
end

local function fixture()
	local records = {
		[7] = {
			Gold = 25,
			SkillXP = {
				[SkillIds.Melee] = 0,
				[SkillIds.Defense] = 0,
				[SkillIds.Mining] = 0,
				[SkillIds.Smithing] = 0,
			},
			Ascension = { RankId = AscensionIds.Adventurer, Flags = {} },
			Inventory = { Stacks = {}, Items = { starter = { DefinitionId = "weapon_sword_starter" } } },
			Equipment = {},
			Plot = { Stations = {} },
			ProgressionFlags = {},
			MasterySelections = {},
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
	local service = Ascension.New(playerData, skills)
	return {
		Records = records,
		PlayerData = playerData,
		Skills = skills,
		Service = service,
	}
end

local function meetAllRequirements(f)
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(8)
	f.Records[7].SkillXP[SkillIds.Defense] = xpForLevel(5)
	f.Records[7].SkillXP[SkillIds.Mining] = xpForLevel(2)
	f.Records[7].SkillXP[SkillIds.Smithing] = xpForLevel(2)
	f.Records[7].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated] = true
end

test("Adventurer and Adept use stable, data-driven Ascension IDs and definitions", function()
	local valid = AscensionDefinitions.Validate(AscensionDefinitions.ById)
	equal(valid, true)
	equal(AscensionIds.ById[AscensionIds.Adventurer], true)
	equal(AscensionIds.ById[AscensionIds.Adept], true)

	local adventurer = AscensionDefinitions.ById[AscensionIds.Adventurer]
	equal(adventurer.Id, AscensionIds.Adventurer)
	equal(adventurer.PreviousRankId, nil)
	equal(adventurer.Requirements, nil)

	local adept = AscensionDefinitions.ById[AscensionIds.Adept]
	equal(adept.Id, AscensionIds.Adept)
	equal(adept.PreviousRankId, AscensionIds.Adventurer)
	assert(adept.Requirements ~= nil)
	-- Offense is a list of alternatives, not a single skill -- future Ranged/Magic thresholds can
	-- be appended without redesigning the service or this definition's shape.
	equal(type(adept.Requirements.Offense.Alternatives), "table")
	equal(#adept.Requirements.Offense.Alternatives, 1)
end)

test("Adept's provisional thresholds match the current design target and use the slice skills", function()
	local requirementsData = AscensionDefinitions.ById[AscensionIds.Adept].Requirements
	equal(requirementsData.Offense.Alternatives[1].SkillId, SkillIds.Melee)
	equal(requirementsData.Offense.Alternatives[1].Level, 8)
	equal(requirementsData.Defense.SkillId, SkillIds.Defense)
	equal(requirementsData.Defense.Level, 5)
	equal(#requirementsData.OverallSkilling.Thresholds, 2)
	equal(requirementsData.OverallSkilling.Thresholds[1].SkillId, SkillIds.Mining)
	equal(requirementsData.OverallSkilling.Thresholds[1].Level, 2)
	equal(requirementsData.OverallSkilling.Thresholds[2].SkillId, SkillIds.Smithing)
	equal(requirementsData.OverallSkilling.Thresholds[2].Level, 2)
	equal(requirementsData.BossMilestoneId, ProgressionFlagIds.GoblinChieftainDefeated)
end)

test("requirement evaluation reports structured per-category progress before anything is met", function()
	local f = fixture()
	local evaluation = assert(f.Service.EvaluateRequirements(7, AscensionIds.Adept))
	equal(evaluation.RankId, AscensionIds.Adept)
	equal(evaluation.Met, false)

	equal(evaluation.Offense.Met, false)
	equal(evaluation.Offense.Alternatives[1].SkillId, SkillIds.Melee)
	equal(evaluation.Offense.Alternatives[1].RequiredLevel, 8)
	equal(evaluation.Offense.Alternatives[1].CurrentLevel, 1)
	equal(evaluation.Offense.Alternatives[1].Met, false)

	equal(evaluation.Defense.Met, false)
	equal(evaluation.Defense.CurrentLevel, 1)

	equal(evaluation.OverallSkilling.Met, false)
	equal(evaluation.OverallSkilling.Thresholds[1].SkillId, SkillIds.Mining)
	equal(evaluation.OverallSkilling.Thresholds[2].SkillId, SkillIds.Smithing)

	equal(evaluation.BossMilestone.MilestoneId, ProgressionFlagIds.GoblinChieftainDefeated)
	equal(evaluation.BossMilestone.Recorded, false)
	equal(evaluation.BossMilestone.Met, false)
end)

test("the offensive requirement is met only once Melee reaches its threshold", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(7)
	local belowThreshold = assert(f.Service.EvaluateRequirements(7, AscensionIds.Adept))
	equal(belowThreshold.Offense.Met, false)
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(8)
	local atThreshold = assert(f.Service.EvaluateRequirements(7, AscensionIds.Adept))
	equal(atThreshold.Offense.Met, true)
	equal(atThreshold.Offense.Alternatives[1].CurrentLevel, 8)
end)

test("the Defense requirement is met only once Defense reaches its threshold", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Defense] = xpForLevel(4)
	local belowThreshold = assert(f.Service.EvaluateRequirements(7, AscensionIds.Adept))
	equal(belowThreshold.Defense.Met, false)
	f.Records[7].SkillXP[SkillIds.Defense] = xpForLevel(5)
	local atThreshold = assert(f.Service.EvaluateRequirements(7, AscensionIds.Adept))
	equal(atThreshold.Defense.Met, true)
end)

test("the overall-skilling requirement needs both Mining and Smithing at their thresholds", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Mining] = xpForLevel(2)
	local onlyMining = assert(f.Service.EvaluateRequirements(7, AscensionIds.Adept))
	equal(onlyMining.OverallSkilling.Met, false)
	equal(onlyMining.OverallSkilling.Thresholds[1].Met, true)
	equal(onlyMining.OverallSkilling.Thresholds[2].Met, false)
	f.Records[7].SkillXP[SkillIds.Smithing] = xpForLevel(2)
	local both = assert(f.Service.EvaluateRequirements(7, AscensionIds.Adept))
	equal(both.OverallSkilling.Met, true)
end)

test("the Goblin Chieftain milestone starts missing and can only be recorded through the trusted API", function()
	local f = fixture()
	local missingMilestone, missingMilestoneReason = f.Service.HasBossMilestone(7, ProgressionFlagIds.GoblinChieftainDefeated)
	equal(missingMilestone, false)
	equal(missingMilestoneReason, nil)
	local evaluationBefore = assert(f.Service.EvaluateRequirements(7, AscensionIds.Adept))
	equal(evaluationBefore.BossMilestone.Met, false)

	local invalidFlag, invalidFlagReason = f.Service.RecordBossMilestone(7, "flag_not_registered")
	equal(invalidFlag, nil)
	equal(invalidFlagReason, "InvalidMilestoneId")
	equal(f.Records[7].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated], nil)

	local recorded = assert(f.Service.RecordBossMilestone(7, ProgressionFlagIds.GoblinChieftainDefeated))
	equal(recorded, true)
	equal(f.Records[7].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated], true)
	equal(assert(f.Service.HasBossMilestone(7, ProgressionFlagIds.GoblinChieftainDefeated)), true)
	local evaluationAfter = assert(f.Service.EvaluateRequirements(7, AscensionIds.Adept))
	equal(evaluationAfter.BossMilestone.Met, true)
end)

test("trusted server composition can record the milestone inside one shared PlayerData.Update transaction", function()
	local f = fixture()
	-- Simulates a later boss service composing this call into a larger atomic transaction, once
	-- per eligible participant -- never keyed to whichever attack landed the killing blow.
	local composed, composedReason = nil, nil
	local ok = f.PlayerData.Update(7, function(data)
		composed, composedReason = f.Service.RecordBossMilestoneToData(data, ProgressionFlagIds.GoblinChieftainDefeated)
	end)
	equal(ok, true)
	equal(composed, true)
	equal(composedReason, nil)
	equal(f.Records[7].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated], true)
end)

test("Ascending from Adventurer to Adept persists through the existing PlayerData shape without resetting anything", function()
	local f = fixture()
	meetAllRequirements(f)
	local before = copy(f.Records[7])
	local result = assert(f.Service.Ascend(7, AscensionIds.Adept))
	equal(result.RankId, AscensionIds.Adept)
	equal(f.Records[7].Ascension.RankId, AscensionIds.Adept)
	equal(assert(f.Service.GetState(7)).RankId, AscensionIds.Adept)

	-- Nothing else changed: XP, Gold, items, equipment, plot, mastery, and other flags survive untouched.
	equal(f.Records[7].SkillXP[SkillIds.Melee], before.SkillXP[SkillIds.Melee])
	equal(f.Records[7].SkillXP[SkillIds.Defense], before.SkillXP[SkillIds.Defense])
	equal(f.Records[7].SkillXP[SkillIds.Mining], before.SkillXP[SkillIds.Mining])
	equal(f.Records[7].SkillXP[SkillIds.Smithing], before.SkillXP[SkillIds.Smithing])
	equal(f.Records[7].Gold, before.Gold)
	equal(f.Records[7].Inventory.Items.starter.DefinitionId, before.Inventory.Items.starter.DefinitionId)
	equal(next(f.Records[7].Equipment), nil)
	equal(next(f.Records[7].Plot.Stations), nil)
	equal(next(f.Records[7].MasterySelections), nil)
	equal(f.Records[7].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated], true)
end)

test("Ascending again to the already-owned rank is rejected", function()
	local f = fixture()
	meetAllRequirements(f)
	assert(f.Service.Ascend(7, AscensionIds.Adept))
	local duplicate, duplicateReason = f.Service.Ascend(7, AscensionIds.Adept)
	equal(duplicate, nil)
	equal(duplicateReason, "AlreadyAscended")
	equal(f.Records[7].Ascension.RankId, AscensionIds.Adept)
end)

test("invalid rank IDs, transitions, and unmet requirements are all rejected without mutation", function()
	local f = fixture()
	local invalidRank, invalidRankReason = f.Service.Ascend(7, "ascension_unknown")
	equal(invalidRank, nil)
	equal(invalidRankReason, "InvalidRankId")

	local toStartingRank, toStartingRankReason = f.Service.Ascend(7, AscensionIds.Adventurer)
	equal(toStartingRank, nil)
	equal(toStartingRankReason, "RankCannotBeAscendedTo")

	local notMet, notMetReason = f.Service.Ascend(7, AscensionIds.Adept)
	equal(notMet, nil)
	equal(notMetReason, "RequirementsNotMet")
	equal(f.Records[7].Ascension.RankId, AscensionIds.Adventurer)

	f.Records[7].Ascension.RankId = "ascension_ghost"
	meetAllRequirements(f)
	local corrupted, corruptedReason = f.Service.Ascend(7, AscensionIds.Adept)
	equal(corrupted, nil)
	equal(corruptedReason, "InvalidAscensionState")
	equal(f.Records[7].Ascension.RankId, "ascension_ghost")
end)

test("the rank/requirement architecture stays data-driven: Ascend follows the definition's PreviousRankId chain generically", function()
	local f = fixture()
	-- Even fully qualified, ascending is only valid from the rank the definition names as previous;
	-- the service contains no Adventurer/Adept-specific branching, only generic chain comparison.
	meetAllRequirements(f)
	f.Records[7].Ascension.RankId = AscensionIds.Adept
	local alreadyPastPrevious, alreadyPastPreviousReason = f.Service.Ascend(7, AscensionIds.Adept)
	equal(alreadyPastPrevious, nil)
	equal(alreadyPastPreviousReason, "AlreadyAscended")
end)

local function meetAllVanguardRequirements(f)
	f.Records[7].SkillXP[SkillIds.Melee] = xpForLevel(15)
	f.Records[7].SkillXP[SkillIds.Defense] = xpForLevel(12)
	f.Records[7].SkillXP[SkillIds.Mining] = xpForLevel(8)
	f.Records[7].SkillXP[SkillIds.Smithing] = xpForLevel(10)
	f.Records[7].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated] = true
	f.Records[7].ProgressionFlags[ProgressionFlagIds.BanditWarlordDefeated] = true
end

test("Vanguard is a stable rank chaining from Adept, gated on the steel tier and the second boss", function()
	equal(AscensionIds.ById[AscensionIds.Vanguard], true)
	local valid = AscensionDefinitions.Validate(AscensionDefinitions.ById)
	equal(valid, true)
	local vanguard = AscensionDefinitions.ById[AscensionIds.Vanguard]
	equal(vanguard.DisplayName, "Vanguard")
	equal(vanguard.PreviousRankId, AscensionIds.Adept)
	local r = vanguard.Requirements
	equal(r.Offense.Alternatives[1].SkillId, SkillIds.Melee)
	equal(r.Offense.Alternatives[1].Level, 15)
	equal(r.Defense.Level, 12)
	-- Overall-skilling now reaches the steel-tier levels (Mining/Smithing), above Adept's 2/2.
	equal(r.OverallSkilling.Thresholds[1].Level, 8)
	equal(r.OverallSkilling.Thresholds[2].Level, 10)
	-- The end-game boss milestone ties Vanguard to actually defeating the Bandit Warlord.
	equal(r.BossMilestoneId, ProgressionFlagIds.BanditWarlordDefeated)
	-- Vanguard grants a real permanent payoff (more max health + starts mitigating hits).
	equal(vanguard.Perk.MaxHealthBonus, 0.20)
	equal(vanguard.Perk.IncomingDamageReduction, 0.05)
end)

test("rank perks are exposed for both the current rank and the next rank", function()
	local f = fixture()
	-- Adventurer's perk is the baseline (no bonus).
	local adventurerPerk = assert(f.Service.GetPerk(7))
	equal(adventurerPerk.MaxHealthBonus, 0)
	equal(adventurerPerk.IncomingDamageReduction, 0)
	-- The next rank carries the perk Ascending to it would grant, so the client can show the payoff.
	equal(assert(f.Service.EvaluateNextRank(7)).Perk.MaxHealthBonus, 0.08)
	-- As an Adept, GetPerk returns Adept's perk and the next rank's perk is Vanguard's.
	f.Records[7].Ascension.RankId = AscensionIds.Adept
	equal(assert(f.Service.GetPerk(7)).MaxHealthBonus, 0.08)
	equal(assert(f.Service.EvaluateNextRank(7)).Perk.MaxHealthBonus, 0.20)
end)

test("GetState surfaces the current rank's display name", function()
	local f = fixture()
	local state = assert(f.Service.GetState(7))
	equal(state.RankId, AscensionIds.Adventurer)
	equal(state.DisplayName, "Adventurer")
	f.Records[7].Ascension.RankId = AscensionIds.Vanguard
	equal(assert(f.Service.GetState(7)).DisplayName, "Vanguard")
end)

test("EvaluateNextRank targets the next rank in the chain and returns nothing at the top", function()
	local f = fixture()
	-- Adventurer -> next is Adept.
	local fromAdventurer = assert(f.Service.EvaluateNextRank(7))
	equal(fromAdventurer.RankId, AscensionIds.Adept)
	equal(fromAdventurer.DisplayName, "Adept")
	equal(fromAdventurer.Progress.RankId, AscensionIds.Adept)
	-- Adept -> next is Vanguard.
	f.Records[7].Ascension.RankId = AscensionIds.Adept
	local fromAdept = assert(f.Service.EvaluateNextRank(7))
	equal(fromAdept.RankId, AscensionIds.Vanguard)
	equal(fromAdept.Progress.RankId, AscensionIds.Vanguard)
	-- Vanguard is the top: (nil, nil), not an error.
	f.Records[7].Ascension.RankId = AscensionIds.Vanguard
	local atTop, atTopReason = f.Service.EvaluateNextRank(7)
	equal(atTop, nil)
	equal(atTopReason, nil)
end)

test("a fully-qualified Adept ascends to Vanguard through the same generic chain", function()
	local f = fixture()
	meetAllVanguardRequirements(f)
	f.Records[7].Ascension.RankId = AscensionIds.Adept
	local nextRank = assert(f.Service.EvaluateNextRank(7))
	equal(nextRank.Progress.Met, true)
	local result = assert(f.Service.Ascend(7, AscensionIds.Vanguard))
	equal(result.RankId, AscensionIds.Vanguard)
	equal(f.Records[7].Ascension.RankId, AscensionIds.Vanguard)
end)

test("Validate rejects a branching rank graph so 'next rank' stays well-defined", function()
	local branching = {}
	for id, def in AscensionDefinitions.ById do
		branching[id] = def
	end
	-- Rebuild Vanguard as a plain copy that (wrongly) also chains from Adventurer, giving Adventurer two
	-- successors (Adept AND Vanguard) -- exactly the branch the chain check must reject.
	local vanguard = AscensionDefinitions.ById[AscensionIds.Vanguard]
	local clone = {}
	for key, value in vanguard do
		clone[key] = value
	end
	clone.PreviousRankId = AscensionIds.Adventurer
	branching[AscensionIds.Vanguard] = clone
	local ok, reason = AscensionDefinitions.Validate(branching)
	equal(ok, false)
	assert(type(reason) == "string" and reason:find("single chain") ~= nil, "expected a single-chain rejection, got " .. tostring(reason))
end)

print(("%d Ascension checks passed"):format(passed))
