--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local SkillIds = require(Shared.SkillIds)
local AscensionIds = require(Shared.AscensionIds)
local StationDefinitions = require(script.Parent.Parent.Plots.StationDefinitions)
local ShopCatalog = require(script.Parent.Parent.Economy.ShopCatalog)
local CraftingDefinitions = require(script.Parent.Parent.Crafting.Definitions)

-- The one hub shop for the vertical slice. Its prices live server-side (ShopCatalog); the client needs
-- them only to present buy/sell options, so a sanitized copy is surfaced here rather than duplicated
-- client-side. Purchase/sell validation and Gold math remain entirely server-authoritative.
local HUB_SHOP_ID = "shop_hub"

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
export type Onboarding = { read GetView: (number) -> (any?, string?) }

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
	Onboarding: Onboarding,
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

		-- Sanitized onboarding view: the current guided step (title/hint/progress/target) or a completion
		-- marker. The server derives completion authoritatively; raw progression flags never appear here.
		local onboarding, onboardingReason = services.Onboarding.GetView(userId)
		if not onboarding then
			return nil, onboardingReason
		end

		-- Sanitized hub-shop catalog: only the item id and its (optional) buy/sell prices, sorted for a
		-- stable order. Never the internal catalog structure. Prices are presentation only; every actual
		-- purchase/sale re-validates the price and Gold server-side through the Economy requests.
		local shop: any = nil
		local hubCatalog = ShopCatalog.ById[HUB_SHOP_ID]
		if hubCatalog then
			local entries: { { ItemDefinitionId: string, BuyPrice: number?, SellPrice: number? } } = {}
			for _, entry in hubCatalog.Entries do
				table.insert(entries, {
					ItemDefinitionId = entry.ItemDefinitionId,
					BuyPrice = entry.BuyPrice,
					SellPrice = entry.SellPrice,
				})
			end
			table.sort(entries, function(a, b): boolean
				return (a.ItemDefinitionId :: string) < (b.ItemDefinitionId :: string)
			end)
			shop = { Id = HUB_SHOP_ID, Entries = entries }
		end

		-- Sanitized Smithing recipes: the requirements the Forge panel presents (output, required level,
		-- inputs, base XP), sorted for a stable order. Server-owned recipe data surfaced for presentation
		-- only; all consumption, output, XP, and batch quantity remain server-authoritative.
		local recipes: { any } = {}
		for _, recipe in CraftingDefinitions.ById do
			local inputs: { { ItemDefinitionId: string, Amount: number } } = {}
			for _, recipeInput in recipe.Inputs do
				table.insert(inputs, { ItemDefinitionId = recipeInput.ItemDefinitionId, Amount = recipeInput.Amount })
			end
			table.insert(recipes, {
				RecipeId = recipe.Id,
				OutputItemId = recipe.OutputItemId,
				OutputAmount = recipe.OutputAmount,
				RequiredSmithingLevel = recipe.RequiredSmithingLevel,
				SmithingXP = recipe.SmithingXP,
				Inputs = inputs,
			})
		end
		table.sort(recipes, function(a, b): boolean
			return (a.RecipeId :: string) < (b.RecipeId :: string)
		end)

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
			Shop = shop,
			Recipes = recipes,
			Onboarding = onboarding,
			OfflineFocusSkillId = focusSkillId,
			-- Retained only for the current session (composition clears it on disconnect); copied
			-- here so a caller mutating the returned model can never affect what a later read sees.
			OfflineReturn = copy(offlineReturnSummaries[userId]),
		}, nil
	end

	return table.freeze(model)
end

return table.freeze(Service)
