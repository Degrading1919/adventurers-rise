--!strict

local Definitions = require(script.Parent.Definitions)

export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type SkillState = { Level: number, XP: number }
export type Skills = {
	read AwardXPToData: (any, string, number) -> (SkillState?, string?),
}
export type StationState = {
	StationId: string,
	SocketId: string,
	SkillId: string,
	Tier: number,
	XPPerSecond: number,
	NextUpgradeCostGold: number?,
}
export type Plots = {
	read GetStationFromData: (any, string) -> (StationState?, string?),
}
export type FocusResult = {
	FocusSkillId: string,
	StationId: string,
	StationTier: number,
}
export type ClaimResult = {
	FocusSkillId: string?,
	RawElapsedSeconds: number,
	CreditedElapsedSeconds: number,
	EfficiencyMultiplier: number,
	XPAwarded: number,
	SkillState: SkillState?,
	StationId: string?,
	StationTier: number?,
	Rewarded: boolean,
	Reason: string?,
}

-- Offline training is intentionally the only offline system: it trains one configured combat
-- skill through the player's own Plot/Training station, never gathering/crafting/combat/bosses.
local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function finiteNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and math.abs(value) < math.huge
end

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

function Service.New(playerData: PlayerData, skills: Skills, plots: Plots, clock: () -> number)
	assert(type(playerData) == "table" and type(playerData.GetSnapshot) == "function" and type(playerData.Update) == "function", "OfflineTraining requires PlayerData")
	assert(type(skills) == "table" and type(skills.AwardXPToData) == "function", "OfflineTraining requires Skills")
	assert(type(plots) == "table" and type(plots.GetStationFromData) == "function", "OfflineTraining requires Plots")
	assert(type(clock) == "function", "OfflineTraining requires a trusted server clock")

	local service = {}

	local function offlineStateFor(data: any): ({ FocusSkillId: string, ClaimedThroughAt: number }?, string?)
		local offline = data.OfflineTraining
		if type(offline) ~= "table" or type(offline.FocusSkillId) ~= "string" or not finiteNonNegative(offline.ClaimedThroughAt) then
			return nil, "InvalidOfflineTrainingState"
		end
		return offline, nil
	end

	function service.GetConfiguration(): Definitions.Configuration
		return Definitions.Configuration
	end

	function service.GetFocus(userId: number): (string?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local offline, reason = offlineStateFor(data)
		if not offline then
			return nil, reason
		end
		if offline.FocusSkillId == "" then
			return nil, nil
		end
		return offline.FocusSkillId, nil
	end

	function service.GetFocusStation(userId: number): (StationState?, string?)
		local focusSkillId, reason = service.GetFocus(userId)
		if reason then
			return nil, reason
		end
		if not focusSkillId then
			return nil, "NoFocusSelected"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local stationId = Definitions.StationIdBySkillId[focusSkillId]
		if not stationId then
			return nil, "UnsupportedFocusSkillId"
		end
		return plots.GetStationFromData(data, stationId)
	end

	function service.SetFocus(userId: number, skillId: string): (FocusResult?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if type(skillId) ~= "string" or Definitions.SupportedFocusSkillIds[skillId] ~= true then
			return nil, "UnsupportedFocusSkillId"
		end
		local stationId = Definitions.StationIdBySkillId[skillId]
		if not stationId then
			return nil, "UnsupportedFocusSkillId"
		end

		local result: FocusResult? = nil
		local mutationReason: string? = nil
		local function abort(abortReason: string)
			mutationReason = abortReason
			error(abortReason, 0)
		end
		local ok, updateReason = playerData.Update(userId, function(data)
			local station, stationReason = plots.GetStationFromData(data, stationId :: string)
			if not station then
				abort(stationReason or "InvalidStationState")
			end
			local offline, offlineReason = offlineStateFor(data)
			if not offline then
				abort(offlineReason or "InvalidOfflineTrainingState")
			end
			(offline :: any).FocusSkillId = skillId
			result = {
				FocusSkillId = skillId,
				StationId = stationId :: string,
				StationTier = (station :: StationState).Tier,
			}
		end)
		if not ok then
			return nil, mutationReason or updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	-- One atomic transaction: reads the trusted session timestamp, resolves the configured focus
	-- and station, awards capped offline XP through the existing Skills mutation boundary, and
	-- advances the anti-double-claim ratchet together. A "nothing to award" outcome (no focus, no
	-- prior session, elapsed below threshold, a future timestamp, or the skill already at its XP
	-- cap) is a successful, structured non-reward result, not an error, and never mutates state.
	function service.ClaimOfflineReward(userId: number): (ClaimResult?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end

		local function softResult(focusSkillId: string?, reason: string, rawElapsed: number?): ClaimResult
			return {
				FocusSkillId = focusSkillId,
				RawElapsedSeconds = if rawElapsed then rawElapsed else 0,
				CreditedElapsedSeconds = 0,
				EfficiencyMultiplier = Definitions.Configuration.EfficiencyMultiplier,
				XPAwarded = 0,
				SkillState = nil,
				StationId = nil,
				StationTier = nil,
				Rewarded = false,
				Reason = reason,
			}
		end

		local result: ClaimResult? = nil
		local mutationReason: string? = nil
		local function abort(abortReason: string)
			mutationReason = abortReason
			error(abortReason, 0)
		end
		local ok, updateReason = playerData.Update(userId, function(data)
			local offline, offlineReason = offlineStateFor(data)
			if not offline then
				abort(offlineReason or "InvalidOfflineTrainingState")
			end
			local resolvedOffline = offline :: { FocusSkillId: string, ClaimedThroughAt: number }
			local focusSkillId = resolvedOffline.FocusSkillId
			if focusSkillId == "" then
				result = softResult(nil, "NoFocusSelected")
				return
			end
			if Definitions.SupportedFocusSkillIds[focusSkillId] ~= true then
				abort("UnsupportedFocusSkillId")
			end
			if not finiteNonNegative(data.LastSessionAt) then
				abort("InvalidLastSessionAt")
			end
			if data.LastSessionAt == 0 then
				result = softResult(focusSkillId, "NoPriorSession")
				return
			end

			local now = clock()
			if not finiteNonNegative(now) then
				abort("InvalidClock")
			end
			local windowStart = math.max(data.LastSessionAt, resolvedOffline.ClaimedThroughAt)
			if windowStart > now then
				result = softResult(focusSkillId, "FutureSessionTimestamp")
				return
			end
			local rawElapsed = now - windowStart
			if rawElapsed < Definitions.Configuration.MinimumElapsedSeconds then
				result = softResult(focusSkillId, "ElapsedBelowThreshold", rawElapsed)
				return
			end

			local stationId = Definitions.StationIdBySkillId[focusSkillId]
			if not stationId then
				abort("UnsupportedFocusSkillId")
			end
			local station, stationReason = plots.GetStationFromData(data, stationId :: string)
			if not station then
				abort(stationReason or "InvalidStationState")
			end
			local resolvedStation = station :: StationState

			local creditedElapsed = math.min(rawElapsed, Definitions.Configuration.MaximumOfflineSeconds)
			local xpAmount = resolvedStation.XPPerSecond * Definitions.Configuration.EfficiencyMultiplier * creditedElapsed
			if not finitePositive(xpAmount) then
				abort("InvalidOfflineTrainingRate")
			end

			local awardedState, xpReason = skills.AwardXPToData(data, focusSkillId, xpAmount)
			if not awardedState then
				result = softResult(focusSkillId, xpReason or "XPAwardFailed", rawElapsed)
				return
			end

			resolvedOffline.ClaimedThroughAt = now
			result = {
				FocusSkillId = focusSkillId,
				RawElapsedSeconds = rawElapsed,
				CreditedElapsedSeconds = creditedElapsed,
				EfficiencyMultiplier = Definitions.Configuration.EfficiencyMultiplier,
				XPAwarded = xpAmount,
				SkillState = awardedState,
				StationId = resolvedStation.StationId,
				StationTier = resolvedStation.Tier,
				Rewarded = true,
				Reason = nil,
			}
		end)
		if not ok then
			return nil, mutationReason or updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	return table.freeze(service)
end

return table.freeze(Service)
