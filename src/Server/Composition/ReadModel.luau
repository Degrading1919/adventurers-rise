--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local SkillIds = require(Shared.SkillIds)
local AscensionIds = require(Shared.AscensionIds)
local StationDefinitions = require(script.Parent.Parent.Plots.StationDefinitions)

-- Composes existing service-owned, already copy-isolated reads into one compact player-facing
-- snapshot. Owns no persistence of its own and never returns internal session/save metadata
-- (SchemaVersion, LastSessionAt, DataStore/session fields never appear here).
export type Economy = { read GetGold: (number) -> (number?, string?) }
export type Skills = { read GetState: (number, string) -> (any?, string?) }
export type Inventory = { read GetSnapshot: (number) -> (any?, string?) }
export type Equipment = { read GetSnapshot: (number) -> (any?, string?) }
export type Plots = { read GetStation: (number, string) -> (any?, string?) }
export type Mastery = { read GetState: (number, string) -> (any?, string?) }
export type Ascension = {
	read GetState: (number) -> (any?, string?),
	read EvaluateRequirements: (number, string) -> (any?, string?),
}
export type OfflineTraining = { read GetFocus: (number) -> (string?, string?) }
export type PlayerHealth = { read GetState: (number) -> (any?, string?) }

export type Services = {
	Economy: Economy,
	Skills: Skills,
	Inventory: Inventory,
	Equipment: Equipment,
	Plots: Plots,
	Mastery: Mastery,
	Ascension: Ascension,
	OfflineTraining: OfflineTraining,
	PlayerHealth: PlayerHealth,
}

local SLICE_SKILL_IDS = { SkillIds.Melee, SkillIds.Defense, SkillIds.Mining, SkillIds.Smithing }

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

function Service.New(services: Services, offlineReturnSummaries: { [number]: any })
	assert(type(services) == "table", "ReadModel requires composed services")
	assert(type(offlineReturnSummaries) == "table", "ReadModel requires the offline-return summary cache")

	local model = {}

	function model.Build(userId: number): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end

		local gold, goldReason = services.Economy.GetGold(userId)
		if not gold then
			return nil, goldReason
		end

		local skills: { [string]: any } = {}
		for _, skillId in SLICE_SKILL_IDS do
			local state, reason = services.Skills.GetState(userId, skillId)
			if not state then
				return nil, reason
			end
			skills[skillId] = state
		end

		local inventory, inventoryReason = services.Inventory.GetSnapshot(userId)
		if not inventory then
			return nil, inventoryReason
		end

		local equipment, equipmentReason = services.Equipment.GetSnapshot(userId)
		if not equipment then
			return nil, equipmentReason
		end

		local plotStations: { [string]: any } = {}
		for stationId in StationDefinitions.ById do
			local station, reason = services.Plots.GetStation(userId, stationId)
			if not station then
				return nil, reason
			end
			plotStations[stationId] = station
		end

		local mastery: { [string]: any } = {}
		for _, skillId in SLICE_SKILL_IDS do
			local state, reason = services.Mastery.GetState(userId, skillId)
			if not state then
				return nil, reason
			end
			mastery[skillId] = state
		end

		local ascensionState, ascensionReason = services.Ascension.GetState(userId)
		if not ascensionState then
			return nil, ascensionReason
		end
		local adeptProgress, progressReason = services.Ascension.EvaluateRequirements(userId, AscensionIds.Adept)
		if not adeptProgress then
			return nil, progressReason
		end

		-- OfflineTraining.GetFocus returns (nil, nil) -- not an error -- when no focus is selected.
		local focusSkillId, focusReason = services.OfflineTraining.GetFocus(userId)
		if focusReason then
			return nil, focusReason
		end

		local health, healthReason = services.PlayerHealth.GetState(userId)
		if not health then
			return nil, healthReason
		end

		return {
			Gold = gold,
			Skills = skills,
			Inventory = inventory,
			Equipment = equipment,
			PlotStations = plotStations,
			Mastery = mastery,
			Ascension = {
				RankId = (ascensionState :: any).RankId,
				AdeptProgress = adeptProgress,
			},
			Health = health,
			OfflineFocusSkillId = focusSkillId,
			-- Retained only for the current session (composition clears it on disconnect); copied
			-- here so a caller mutating the returned model can never affect what a later read sees.
			OfflineReturn = copy(offlineReturnSummaries[userId]),
		}, nil
	end

	return table.freeze(model)
end

return table.freeze(Service)
