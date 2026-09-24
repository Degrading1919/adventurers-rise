--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local ProgressionFlagIds = require(Shared.ProgressionFlagIds)
local Definitions = require(script.Parent.Definitions)

export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type Skills = {
	read GetStateFromData: (any, string) -> (any?, string?),
}
export type State = {
	RankId: string,
	DisplayName: string,
}
export type SkillThresholdResult = {
	SkillId: string,
	RequiredLevel: number,
	CurrentLevel: number,
	Met: boolean,
}
export type OffenseResult = {
	Alternatives: { SkillThresholdResult },
	Met: boolean,
}
export type OverallSkillingResult = {
	Thresholds: { SkillThresholdResult },
	Met: boolean,
}
export type BossMilestoneResult = {
	MilestoneId: string,
	Recorded: boolean,
	Met: boolean,
}
export type RequirementEvaluation = {
	RankId: string,
	Offense: OffenseResult,
	Defense: SkillThresholdResult,
	OverallSkilling: OverallSkillingResult,
	BossMilestone: BossMilestoneResult,
	Met: boolean,
}
export type AscendResult = {
	RankId: string,
}
-- Forward-looking Ascension goal: the rank the player can work toward next, with its live requirement
-- evaluation. Nil (returned as (nil, nil)) when the player is already at the top of the ladder.
export type NextRankView = {
	RankId: string,
	DisplayName: string,
	Progress: RequirementEvaluation,
	-- What Ascending to this rank permanently grants, so the client can show the payoff up front.
	Perk: Definitions.Perk,
}

-- Trusted server systems (a shared or personal boss encounter) call RecordBossMilestone /
-- RecordBossMilestoneToData once per eligible participant; neither takes or implies a killer.
local Service = {}

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= 9007199254740991
end

local function validMilestoneId(milestoneId: any): boolean
	return type(milestoneId) == "string" and ProgressionFlagIds.ById[milestoneId] == true
end

function Service.New(playerData: PlayerData, skills: Skills)
	assert(type(playerData) == "table" and type(playerData.GetSnapshot) == "function" and type(playerData.Update) == "function", "Ascension requires PlayerData")
	assert(type(skills) == "table" and type(skills.GetStateFromData) == "function", "Ascension requires Skills")
	local valid, reason = Definitions.Validate(Definitions.ById)
	assert(valid, reason)

	local service = {}

	local function rankFor(rankId: any): (Definitions.RankDefinition?, string?)
		if type(rankId) ~= "string" or rankId == "" then
			return nil, "InvalidRankId"
		end
		local rank = Definitions.ById[rankId]
		if not rank then
			return nil, "InvalidRankId"
		end
		return rank, nil
	end

	local function ascensionFor(data: any): (any?, string?)
		local ascension = data.Ascension
		if type(ascension) ~= "table" or type(ascension.RankId) ~= "string" or Definitions.ById[ascension.RankId] == nil or type(ascension.Flags) ~= "table" then
			return nil, "InvalidAscensionState"
		end
		return ascension, nil
	end

	local function progressionFlagsFor(data: any): (any?, string?)
		local flags = data.ProgressionFlags
		if type(flags) ~= "table" then
			return nil, "InvalidProgressionFlags"
		end
		return flags, nil
	end

	function service.GetStateFromData(data: any): (State?, string?)
		local ascension, ascensionReason = ascensionFor(data)
		if not ascension then
			return nil, ascensionReason
		end
		-- ascensionFor already proved the rank id is a known definition.
		local rank = Definitions.ById[ascension.RankId]
		return { RankId = ascension.RankId, DisplayName = rank.DisplayName }, nil
	end

	function service.GetState(userId: number): (State?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		return service.GetStateFromData(data)
	end

	local function evaluateSkillThresholdFromData(data: any, threshold: Definitions.SkillThreshold): (SkillThresholdResult?, string?)
		local state, stateReason = skills.GetStateFromData(data, threshold.SkillId)
		if not state then
			return nil, stateReason
		end
		local currentLevel = (state :: any).Level
		return {
			SkillId = threshold.SkillId,
			RequiredLevel = threshold.Level,
			CurrentLevel = currentLevel,
			Met = currentLevel >= threshold.Level,
		}, nil
	end

	-- Trusted server compositions may use this inside one PlayerData.Update transaction so
	-- Ascend can evaluate requirements against the exact data it is about to mutate.
	function service.EvaluateRequirementsFromData(data: any, rankId: string): (RequirementEvaluation?, string?)
		local rank, rankReason = rankFor(rankId)
		if not rank then
			return nil, rankReason
		end
		local requirementsData = rank.Requirements
		if not requirementsData then
			return nil, "RankHasNoRequirements"
		end
		local flags, flagsReason = progressionFlagsFor(data)
		if not flags then
			return nil, flagsReason
		end

		local alternatives: { SkillThresholdResult } = {}
		local offenseMet = false
		for _, alternative in requirementsData.Offense.Alternatives do
			local result, altReason = evaluateSkillThresholdFromData(data, alternative)
			if not result then
				return nil, altReason
			end
			table.insert(alternatives, result)
			if result.Met then
				offenseMet = true
			end
		end

		local defenseResult, defenseReason = evaluateSkillThresholdFromData(data, requirementsData.Defense)
		if not defenseResult then
			return nil, defenseReason
		end

		local overallThresholds: { SkillThresholdResult } = {}
		local overallMet = true
		for _, thresholdEntry in requirementsData.OverallSkilling.Thresholds do
			local result, thresholdReason = evaluateSkillThresholdFromData(data, thresholdEntry)
			if not result then
				return nil, thresholdReason
			end
			table.insert(overallThresholds, result)
			if not result.Met then
				overallMet = false
			end
		end

		local milestoneId = requirementsData.BossMilestoneId
		local recorded = flags[milestoneId] == true

		return {
			RankId = rankId,
			Offense = { Alternatives = alternatives, Met = offenseMet },
			Defense = defenseResult,
			OverallSkilling = { Thresholds = overallThresholds, Met = overallMet },
			BossMilestone = { MilestoneId = milestoneId, Recorded = recorded, Met = recorded },
			Met = offenseMet and defenseResult.Met and overallMet and recorded,
		}, nil
	end

	function service.EvaluateRequirements(userId: number, rankId: string): (RequirementEvaluation?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		return service.EvaluateRequirementsFromData(data, rankId)
	end

	-- The rank that chains directly from `rankId` (its PreviousRankId points back to it), or nil at the
	-- top of the ladder. Definitions are validated as a linear chain, so at most one rank matches.
	local function nextRankAfter(rankId: string): Definitions.RankDefinition?
		for _, candidate in Definitions.ById do
			if candidate.PreviousRankId == rankId then
				return candidate
			end
		end
		return nil
	end

	-- Progress toward the player's NEXT rank, so a single forward-looking Ascension goal can be surfaced
	-- without hardcoding a rank id. Returns (nil, nil) -- not an error -- when already at the max rank.
	function service.EvaluateNextRankFromData(data: any): (NextRankView?, string?)
		local ascension, ascensionReason = ascensionFor(data)
		if not ascension then
			return nil, ascensionReason
		end
		local nextRank = nextRankAfter(ascension.RankId)
		if not nextRank then
			return nil, nil
		end
		local progress, progressReason = service.EvaluateRequirementsFromData(data, nextRank.Id)
		if not progress then
			return nil, progressReason
		end
		return { RankId = nextRank.Id, DisplayName = nextRank.DisplayName, Progress = progress, Perk = nextRank.Perk }, nil
	end

	-- The permanent perk the player's CURRENT rank grants (the reward they already hold). Read by the
	-- composition so it can fold the perk into the live health/damage-reduction modifier channels.
	function service.GetPerkFromData(data: any): (Definitions.Perk?, string?)
		local ascension, ascensionReason = ascensionFor(data)
		if not ascension then
			return nil, ascensionReason
		end
		return Definitions.ById[ascension.RankId].Perk, nil
	end

	function service.GetPerk(userId: number): (Definitions.Perk?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		return service.GetPerkFromData(data)
	end

	function service.EvaluateNextRank(userId: number): (NextRankView?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		return service.EvaluateNextRankFromData(data)
	end

	function service.Ascend(userId: number, targetRankId: string): (AscendResult?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local targetRank, rankReason = rankFor(targetRankId)
		if not targetRank then
			return nil, rankReason
		end
		if not targetRank.PreviousRankId or not targetRank.Requirements then
			return nil, "RankCannotBeAscendedTo"
		end

		local result: AscendResult? = nil
		local mutationReason: string? = nil
		local function abort(abortReason: string)
			mutationReason = abortReason
			error(abortReason, 0)
		end
		local ok, updateReason = playerData.Update(userId, function(data)
			local ascension, ascensionReason = ascensionFor(data)
			if not ascension then
				abort(ascensionReason or "InvalidAscensionState")
			end
			if (ascension :: any).RankId == targetRankId then
				abort("AlreadyAscended")
			end
			if (ascension :: any).RankId ~= targetRank.PreviousRankId then
				abort("InvalidRankTransition")
			end
			local evaluation, evalReason = service.EvaluateRequirementsFromData(data, targetRankId)
			if not evaluation then
				abort(evalReason or "RequirementEvaluationFailed")
			end
			if not (evaluation :: any).Met then
				abort("RequirementsNotMet")
			end
			(ascension :: any).RankId = targetRankId
			result = { RankId = targetRankId }
		end)
		if not ok then
			return nil, mutationReason or updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	-- Trusted server compositions may use this inside one PlayerData.Update transaction.
	function service.RecordBossMilestoneToData(data: any, milestoneId: string): (boolean?, string?)
		if not validMilestoneId(milestoneId) then
			return nil, "InvalidMilestoneId"
		end
		local flags, flagsReason = progressionFlagsFor(data)
		if not flags then
			return nil, flagsReason
		end
		flags[milestoneId] = true
		return true, nil
	end

	-- Later trusted boss composition calls this once per eligible participant; it never accepts
	-- or infers which attack was the killing blow.
	function service.RecordBossMilestone(userId: number, milestoneId: string): (boolean?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validMilestoneId(milestoneId) then
			return nil, "InvalidMilestoneId"
		end
		local result: boolean? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			result, mutationReason = service.RecordBossMilestoneToData(data, milestoneId)
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	function service.HasBossMilestone(userId: number, milestoneId: string): (boolean?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validMilestoneId(milestoneId) then
			return nil, "InvalidMilestoneId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local flags, flagsReason = progressionFlagsFor(data)
		if not flags then
			return nil, flagsReason
		end
		return flags[milestoneId] == true, nil
	end

	return table.freeze(service)
end

return table.freeze(Service)
