--!strict

local Economy = require(script.Parent.Parent.Economy.Service)
local StationDefinitions = require(script.Parent.StationDefinitions)

export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type Skills = {
	read AwardXP: (number, string, number) -> (any?, string?),
}
export type StationState = {
	StationId: string,
	SocketId: string,
	SkillId: string,
	Tier: number,
	XPPerSecond: number,
	NextUpgradeCostGold: number?,
}

local Service = { MaximumElapsedSeconds = 60 }

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= Economy.MaximumGold
end

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

local function validGold(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value <= Economy.MaximumGold and value % 1 == 0
end

local function validTier(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0
end

local function validateDefinitions()
	local valid, reason = StationDefinitions.Validate(StationDefinitions.ById, Economy.MaximumGold)
	assert(valid, reason)
end

function Service.New(playerData: PlayerData, skills: Skills)
	assert(type(playerData) == "table", "Plots requires a PlayerData service")
	assert(type(skills) == "table" and type(skills.AwardXP) == "function", "Plots requires a Skills service")
	validateDefinitions()

	local service = {}

	local function definitionFor(stationId: any): (StationDefinitions.Definition?, string?)
		if type(stationId) ~= "string" or stationId == "" then
			return nil, "InvalidStationId"
		end
		local definition = StationDefinitions.ById[stationId]
		if not definition then
			return nil, "InvalidStationId"
		end
		return definition, nil
	end

	local function stationStateFor(data: any, definition: StationDefinitions.Definition): (StationState?, string?)
		local plot = data.Plot
		if type(plot) ~= "table" or type(plot.Stations) ~= "table" then
			return nil, "InvalidPlotState"
		end
		local savedState = plot.Stations[definition.Id]
		local tierNumber = 1
		if savedState ~= nil then
			if type(savedState) ~= "table" or not validTier(savedState.Tier) then
				return nil, "InvalidStationState"
			end
			tierNumber = savedState.Tier
		end
		local tier = definition.Tiers[tierNumber]
		if not tier then
			return nil, "InvalidStationState"
		end
		local nextTier = definition.Tiers[tierNumber + 1]
		return {
			StationId = definition.Id,
			SocketId = definition.SocketId,
			SkillId = definition.SkillId,
			Tier = tier.Tier,
			XPPerSecond = tier.XPPerSecond,
			NextUpgradeCostGold = if nextTier then nextTier.UpgradeCostGold else nil,
		}, nil
	end

	function service.GetStation(userId: number, stationId: string): (StationState?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local definition, definitionReason = definitionFor(stationId)
		if not definition then
			return nil, definitionReason
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		return stationStateFor(data, definition)
	end

	-- Trusted server compositions may use this inside one PlayerData.Update transaction (or
	-- against a read-only snapshot) so callers reuse the same authoritative tier/rate resolution
	-- Plot/Training owns, instead of duplicating it.
	function service.GetStationFromData(data: any, stationId: string): (StationState?, string?)
		local definition, definitionReason = definitionFor(stationId)
		if not definition then
			return nil, definitionReason
		end
		return stationStateFor(data, definition)
	end

	function service.UpgradeStation(userId: number, stationId: string): (StationState?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local definition, definitionReason = definitionFor(stationId)
		if not definition then
			return nil, definitionReason
		end

		local result: StationState? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			if not validGold(data.Gold) then
				mutationReason = "InvalidGold"
				return
			end
			local currentState, stateReason = stationStateFor(data, definition)
			if not currentState then
				mutationReason = stateReason
				return
			end
			local nextTier = definition.Tiers[currentState.Tier + 1]
			if not nextTier then
				mutationReason = "MaximumTier"
				return
			end
			if data.Gold < nextTier.UpgradeCostGold then
				mutationReason = "InsufficientGold"
				return
			end
			local stations = data.Plot.Stations
			local savedState = stations[definition.Id]
			if savedState == nil then
				savedState = {}
				stations[definition.Id] = savedState
			end
			savedState.Tier = nextTier.Tier
			data.Gold -= nextTier.UpgradeCostGold
			result = {
				StationId = definition.Id,
				SocketId = definition.SocketId,
				SkillId = definition.SkillId,
				Tier = nextTier.Tier,
				XPPerSecond = nextTier.XPPerSecond,
				NextUpgradeCostGold = if definition.Tiers[nextTier.Tier + 1] then definition.Tiers[nextTier.Tier + 1].UpgradeCostGold else nil,
			}
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	function service.AwardTrainingForElapsed(userId: number, stationId: string, elapsedSeconds: number): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local definition, definitionReason = definitionFor(stationId)
		if not definition then
			return nil, definitionReason
		end
		if not finitePositive(elapsedSeconds) or elapsedSeconds > Service.MaximumElapsedSeconds then
			return nil, "InvalidElapsedSeconds"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local stationState, stateReason = stationStateFor(data, definition)
		if not stationState then
			return nil, stateReason
		end
		local amount = stationState.XPPerSecond * elapsedSeconds
		if not finitePositive(amount) then
			return nil, "InvalidTrainingRate"
		end
		return skills.AwardXP(userId, stationState.SkillId, amount)
	end

	return table.freeze(service)
end

return table.freeze(Service)
