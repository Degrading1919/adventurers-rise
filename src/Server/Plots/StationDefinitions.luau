--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local PlotSockets = require(Shared.PlotSockets)
local SkillIds = require(Shared.SkillIds)

export type Tier = {
	read Tier: number,
	read UpgradeCostGold: number,
	read XPPerSecond: number,
}
export type Definition = {
	read Id: string,
	read SocketId: string,
	read SkillId: string,
	read Tiers: { [number]: Tier },
}

local StationDefinitions = {}

local function tier(number: number, upgradeCostGold: number, xpPerSecond: number): Tier
	return table.freeze({
		Tier = number,
		UpgradeCostGold = upgradeCostGold,
		XPPerSecond = xpPerSecond,
	})
end

local function definition(id: string, socketId: string, skillId: string, tiers: { [number]: Tier }): Definition
	return table.freeze({
		Id = id,
		SocketId = socketId,
		SkillId = skillId,
		Tiers = table.freeze(tiers),
	})
end

-- Rates and costs are provisional. Add later tiers as data without changing station logic.
local definitions: { [string]: Definition } = {
	station_training_melee = definition("station_training_melee", PlotSockets.Melee, SkillIds.Melee, {
		[1] = tier(1, 0, 1),
		[2] = tier(2, 100, 2),
	}),
	station_training_defense = definition("station_training_defense", PlotSockets.Defense, SkillIds.Defense, {
		[1] = tier(1, 0, 1),
		[2] = tier(2, 125, 2),
	}),
}

local function validTier(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0
end

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

local function validGold(value: any, maximumGold: any): boolean
	return type(value) == "number" and value == value and value >= 0 and type(maximumGold) == "number" and value <= maximumGold and value % 1 == 0
end

function StationDefinitions.Validate(candidateDefinitions: any, maximumGold: any): (boolean, string?)
	if type(candidateDefinitions) ~= "table" then
		return false, "Station definitions must be a table"
	end
	for stationId, station in candidateDefinitions do
		if type(stationId) ~= "string" or stationId == "" or type(station) ~= "table" or station.Id ~= stationId then
			return false, "Station IDs must be stable"
		end
		if type(station.SocketId) ~= "string" or PlotSockets.ById[station.SocketId] ~= true then
			return false, "Stations must reference a known socket ID"
		end
		if type(station.SkillId) ~= "string" or station.SkillId == "" or type(station.Tiers) ~= "table" then
			return false, "Stations require a skill ID and tiers"
		end
		local maximumTier = 0
		for tierNumber, stationTier in station.Tiers do
			if not validTier(tierNumber) or type(stationTier) ~= "table" or stationTier.Tier ~= tierNumber then
				return false, "Station tiers must be consecutive positive integers"
			end
			if not validGold(stationTier.UpgradeCostGold, maximumGold) then
				return false, "Station upgrade costs must be valid Gold"
			end
			if not finitePositive(stationTier.XPPerSecond) then
				return false, "Station training rates must be finite positive values"
			end
			maximumTier = math.max(maximumTier, tierNumber)
		end
		if maximumTier < 1 or type(station.Tiers[1]) ~= "table" or station.Tiers[1].UpgradeCostGold ~= 0 then
			return false, "Stations must define a free tier 1"
		end
		for tierNumber = 1, maximumTier do
			if station.Tiers[tierNumber] == nil then
				return false, "Station tiers must be consecutive positive integers"
			end
		end
	end
	return true, nil
end

return table.freeze({
	ById = table.freeze(definitions),
	Validate = StationDefinitions.Validate,
})
