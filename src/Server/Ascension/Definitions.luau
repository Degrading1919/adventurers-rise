--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local AscensionIds = require(Shared.AscensionIds)
local SkillIds = require(Shared.SkillIds)
local ProgressionFlagIds = require(Shared.ProgressionFlagIds)

export type SkillThreshold = {
	read SkillId: string,
	read Level: number,
}
-- Met when ANY alternative's skill meets its Level. Only Melee is functional in the slice, but
-- a later Ranged/Magic offensive threshold can be appended here without redesigning the service.
export type OffensiveRequirement = {
	read Alternatives: { SkillThreshold },
}
-- Met only when EVERY threshold is satisfied.
export type OverallSkillingRequirement = {
	read Thresholds: { SkillThreshold },
}
export type Requirements = {
	read Offense: OffensiveRequirement,
	read Defense: SkillThreshold,
	read OverallSkilling: OverallSkillingRequirement,
	read BossMilestoneId: string,
}
-- The permanent reward for HOLDING a rank (absolute totals for that rank, not stacked on lower ranks).
-- Folded into the SAME modifier channels armor/Mastery use: MaxHealthBonus raises max health,
-- IncomingDamageReduction mitigates enemy damage. So Ascending visibly toughens the player.
export type Perk = {
	read MaxHealthBonus: number,
	read IncomingDamageReduction: number,
}
export type RankDefinition = {
	read Id: string,
	read DisplayName: string,
	-- nil only for the starting rank (Adventurer); every other rank chains from one previous rank.
	read PreviousRankId: string?,
	-- nil only for the starting rank; required for every rank reachable through Ascend.
	read Requirements: Requirements?,
	read Perk: Perk,
}

local AscensionDefinitions = {}

local knownSkillIds: { [string]: boolean } = {}
for _, id in SkillIds do
	knownSkillIds[id] = true
end

local function positiveWhole(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function finiteNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

local function skillThreshold(skillId: string, level: number): SkillThreshold
	return table.freeze({ SkillId = skillId, Level = level })
end

local function offense(alternatives: { SkillThreshold }): OffensiveRequirement
	return table.freeze({ Alternatives = table.freeze(alternatives) })
end

local function overallSkilling(thresholds: { SkillThreshold }): OverallSkillingRequirement
	return table.freeze({ Thresholds = table.freeze(thresholds) })
end

local function requirements(offenseReq: OffensiveRequirement, defenseReq: SkillThreshold, overallReq: OverallSkillingRequirement, bossMilestoneId: string): Requirements
	return table.freeze({
		Offense = offenseReq,
		Defense = defenseReq,
		OverallSkilling = overallReq,
		BossMilestoneId = bossMilestoneId,
	})
end

local function perk(maxHealthBonus: number, incomingDamageReduction: number): Perk
	return table.freeze({ MaxHealthBonus = maxHealthBonus, IncomingDamageReduction = incomingDamageReduction })
end

local function rank(id: string, displayName: string, previousRankId: string?, requirementsData: Requirements?, perkData: Perk): RankDefinition
	return table.freeze({
		Id = id,
		DisplayName = displayName,
		PreviousRankId = previousRankId,
		Requirements = requirementsData,
		Perk = perkData,
	})
end

-- All thresholds are provisional. Offense/Defense follow the current Ascension I design target
-- (Offense ~8, Defense ~5). The overall-skilling requirement is the smallest pair that is still a
-- genuine check rather than the always-true level-1 baseline: level 2 in each of Mining and
-- Smithing, one step past the slice's own Iron Ore/Iron Bar unlock levels.
-- Rank perks are absolute totals for holding that rank and rise with it, so each Ascension is a real,
-- felt power step: Adept toughens you (+8% max health), Vanguard more so and starts mitigating hits.
local definitions: { [string]: RankDefinition } = {
	[AscensionIds.Adventurer] = rank(AscensionIds.Adventurer, "Adventurer", nil, nil, perk(0, 0)),
	[AscensionIds.Adept] = rank(
		AscensionIds.Adept,
		"Adept",
		AscensionIds.Adventurer,
		requirements(
			offense({ skillThreshold(SkillIds.Melee, 8) }),
			skillThreshold(SkillIds.Defense, 5),
			overallSkilling({ skillThreshold(SkillIds.Mining, 2), skillThreshold(SkillIds.Smithing, 2) }),
			ProgressionFlagIds.GoblinChieftainDefeated
		),
		perk(0.08, 0)
	),
	-- Vanguard (Ascension II): the mid-game rank gate. Thresholds sit meaningfully above Adept and are
	-- tuned to the content built for this region — the steel production tier (Mining/Smithing) and the
	-- second boss (Bandit Warlord). Reaching it means the player has genuinely worked the whole loop:
	-- fought up the melee ladder, hardened Defense, mined+smithed into steel, and beaten the Warlord.
	[AscensionIds.Vanguard] = rank(
		AscensionIds.Vanguard,
		"Vanguard",
		AscensionIds.Adept,
		requirements(
			offense({ skillThreshold(SkillIds.Melee, 15) }),
			skillThreshold(SkillIds.Defense, 12),
			overallSkilling({ skillThreshold(SkillIds.Mining, 8), skillThreshold(SkillIds.Smithing, 10) }),
			ProgressionFlagIds.BanditWarlordDefeated
		),
		perk(0.20, 0.05)
	),
}

local function validSkillThreshold(value: any): boolean
	return type(value) == "table" and type(value.SkillId) == "string" and knownSkillIds[value.SkillId] == true and positiveWhole(value.Level)
end

function AscensionDefinitions.Validate(candidateDefinitions: any): (boolean, string?)
	if type(candidateDefinitions) ~= "table" then
		return false, "Ascension definitions must be a table"
	end
	for rankId, candidate in candidateDefinitions do
		if type(rankId) ~= "string" or rankId == "" or AscensionIds.ById[rankId] ~= true or type(candidate) ~= "table" or candidate.Id ~= rankId then
			return false, "Ascension rank IDs must be stable"
		end
		if type(candidate.DisplayName) ~= "string" or candidate.DisplayName == "" then
			return false, "Ascension ranks require a display name"
		end
		local perkData = candidate.Perk
		if type(perkData) ~= "table" or not finiteNonNegative(perkData.MaxHealthBonus) or not finiteNonNegative(perkData.IncomingDamageReduction) then
			return false, "Ascension ranks require a valid perk (non-negative MaxHealthBonus and IncomingDamageReduction)"
		end
		if candidate.PreviousRankId ~= nil then
			if type(candidate.PreviousRankId) ~= "string" or AscensionIds.ById[candidate.PreviousRankId] ~= true or candidate.PreviousRankId == rankId then
				return false, "Ascension previous rank IDs must reference a different known rank"
			end
		end
		local requirementsData = candidate.Requirements
		if candidate.PreviousRankId == nil then
			if requirementsData ~= nil then
				return false, "The starting rank must not declare requirements"
			end
		else
			if type(requirementsData) ~= "table" then
				return false, "Non-starting ranks require requirements"
			end
			local offenseReq = requirementsData.Offense
			if type(offenseReq) ~= "table" or type(offenseReq.Alternatives) ~= "table" or #offenseReq.Alternatives == 0 then
				return false, "Offense requirements need at least one alternative"
			end
			for _, alternative in offenseReq.Alternatives do
				if not validSkillThreshold(alternative) then
					return false, "Offense alternatives must be valid skill thresholds"
				end
			end
			if not validSkillThreshold(requirementsData.Defense) then
				return false, "Defense requirement must be a valid skill threshold"
			end
			local overallReq = requirementsData.OverallSkilling
			if type(overallReq) ~= "table" or type(overallReq.Thresholds) ~= "table" or #overallReq.Thresholds == 0 then
				return false, "Overall-skilling requirement needs at least one threshold"
			end
			for _, thresholdEntry in overallReq.Thresholds do
				if not validSkillThreshold(thresholdEntry) then
					return false, "Overall-skilling thresholds must be valid skill thresholds"
				end
			end
			if type(requirementsData.BossMilestoneId) ~= "string" or ProgressionFlagIds.ById[requirementsData.BossMilestoneId] ~= true then
				return false, "Boss milestone ID must be a known progression flag"
			end
		end
	end

	-- The rank graph MUST be a single linear chain: exactly one starting rank (no PreviousRankId) and at
	-- most one successor per rank, with every rank reaching the start by following PreviousRankId (no
	-- branches, no cycles). This guarantees "the player's next rank" is always well-defined -- the service
	-- picks the unique successor of the current rank, so a branch would make that nondeterministic.
	local rootCount = 0
	local successorsByPrevious: { [string]: number } = {}
	local total = 0
	for _, candidate in candidateDefinitions do
		total += 1
		if candidate.PreviousRankId == nil then
			rootCount += 1
		else
			local count = (successorsByPrevious[candidate.PreviousRankId] or 0) + 1
			successorsByPrevious[candidate.PreviousRankId] = count
			if count > 1 then
				return false, "Ascension ranks must form a single chain: multiple successors for " .. candidate.PreviousRankId
			end
		end
	end
	if rootCount ~= 1 then
		return false, "Ascension ranks require exactly one starting rank"
	end
	for rankId, candidate in candidateDefinitions do
		local steps = 0
		local cursor = candidate
		while cursor.PreviousRankId ~= nil do
			cursor = candidateDefinitions[cursor.PreviousRankId]
			steps += 1
			if steps > total then
				return false, "Ascension rank chain must be acyclic: " .. rankId
			end
		end
	end
	return true, nil
end

return table.freeze({
	ById = table.freeze(definitions),
	Validate = AscensionDefinitions.Validate,
})
