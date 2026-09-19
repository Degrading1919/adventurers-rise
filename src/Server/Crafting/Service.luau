--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local ItemDefinitions = require(Shared.ItemDefinitions)
local Definitions = require(script.Parent.Definitions)

export type PlayerData = {
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type Inventory = {
	read AddStackToData: (any, string, number) -> (number?, string?),
	read RemoveStackFromData: (any, string, number) -> (number?, string?),
	read AddDiscreteItemToData: (any, string) -> ({ InstanceId: string, DefinitionId: string }?, string?),
}
export type Skills = {
	read GetStateFromData: (any, string) -> (any?, string?),
	read AwardXPToData: (any, string, number) -> (any?, string?),
}
export type Result = {
	RecipeId: string,
	OutputItemId: string,
	OutputAmount: number,
	OutputInstanceId: string?,
	SmithingXP: number,
	SmithingState: any,
}

-- Server-owned Mastery modifier totals for the crafter's Smithing tree (see Mastery.GetModifiers, the
-- single source of truth). Read from the same transactional `data` being mutated, so a selection/respec
-- is applied atomically with the craft. Crafting only READS the totals it can truthfully honor today.
export type ModifierTotals = { [string]: number }
export type SmithingModifierProvider = (any) -> ModifierTotals

-- Keeps a fully-stacked material efficiency below 1 so every input still costs at least a positive
-- amount (never free or negative). Current slice data caps a completed Forgemaster branch at 0.10.
local MAX_MATERIAL_EFFICIENCY = 0.9

-- Trusted server systems (a shared or personal Forge) call service.Craft; no recipe logic lives in Studio.
local Service = {}

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= 9007199254740991
end

-- Reads one modifier total defensively; a missing/non-finite entry contributes nothing (never a bonus).
local function modifierTotal(totals: any, key: string): number
	if type(totals) ~= "table" then
		return 0
	end
	local value = totals[key]
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return value
end

local function validStableId(value: any): boolean
	return type(value) == "string" and value ~= ""
end

function Service.New(playerData: PlayerData, inventory: Inventory, skills: Skills, smithingModifiers: SmithingModifierProvider?)
	assert(type(playerData) == "table" and type(playerData.Update) == "function", "Crafting requires PlayerData")
	assert(
		type(inventory) == "table"
			and type(inventory.AddStackToData) == "function"
			and type(inventory.RemoveStackFromData) == "function"
			and type(inventory.AddDiscreteItemToData) == "function",
		"Crafting requires Inventory"
	)
	assert(type(skills) == "table" and type(skills.GetStateFromData) == "function" and type(skills.AwardXPToData) == "function", "Crafting requires Skills")
	assert(smithingModifiers == nil or type(smithingModifiers) == "function", "Crafting smithingModifiers must be a function when provided")
	local valid, reason = Definitions.Validate(Definitions.ById)
	assert(valid, reason)
	-- Defaults to "no selected Mastery" so callers/tests that do not wire Mastery keep exact prior
	-- material consumption. Composition injects the real server-authoritative Smithing provider.
	local resolveSmithingModifiers: SmithingModifierProvider = smithingModifiers or function()
		return {}
	end

	local service = {}

	local function definitionFor(recipeId: any): (Definitions.Definition?, string?)
		if not validStableId(recipeId) then
			return nil, "InvalidRecipeId"
		end
		local definition = Definitions.ById[recipeId]
		if not definition then
			return nil, "InvalidRecipeId"
		end
		return definition, nil
	end

	function service.Craft(userId: number, recipeId: string): (Result?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local definition, definitionReason = definitionFor(recipeId)
		if not definition then
			return nil, definitionReason
		end
		local outputItem = ItemDefinitions.ById[definition.OutputItemId]
		if not outputItem then
			return nil, "InvalidRecipeOutput"
		end
		-- Forgemaster is defined as "material efficiency when forging EQUIPMENT" (docs/MASTERY_TREES.md),
		-- so MaterialEfficiencyBonus applies only to recipes whose output is an equippable item. Detected
		-- from the output item's own Equipment metadata -- never a hard-coded recipe ID -- so a smelting
		-- recipe (Iron Ore -> Iron Bar) is excluded while the upgraded sword qualifies.
		local outputIsEquipment = outputItem.Equipment ~= nil

		local result: Result? = nil
		local mutationReason: string? = nil
		local function abort(abortReason: string)
			mutationReason = abortReason
			error(abortReason, 0)
		end
		local ok, updateReason = playerData.Update(userId, function(data)
			local smithingState, stateReason = skills.GetStateFromData(data, definition.SkillId)
			if not smithingState then
				abort(stateReason or "InvalidSmithingState")
			end
			if (smithingState :: any).Level < definition.RequiredSmithingLevel then
				abort("InsufficientSmithingLevel")
			end

			-- MaterialEfficiencyBonus (equipment crafts only, per above) reduces how much of each input the
			-- craft consumes, via a deliberately SAFE rounding: ceil of the reduced amount, floored at 1, so
			-- a craft is never free or negative-cost and a player never receives more discount than earned.
			-- No exaggerated rounding is used to force a small bonus to "show" on a tiny recipe: at the
			-- configured +2%..+10% Forgemaster values, a single 2- or 3-unit recipe rounds to no change (a
			-- whole unit is only saved once the reduction crosses an integer, e.g. eff >= 1/amount).
			-- Meaningful realization of the configured percentages is therefore BLOCKED on the already-
			-- required batch-crafting work (a batch multiplies the effective quantity, letting the same
			-- percentage save whole units). ProcessingSpeedBonus is intentionally NOT consumed here: Craft
			-- is an atomic transaction with no authoritative action-time to shorten, and fabricating a delay
			-- would not be trustworthy.
			local materialEfficiency = if outputIsEquipment
				then math.clamp(math.max(0, modifierTotal(resolveSmithingModifiers(data), "MaterialEfficiencyBonus")), 0, MAX_MATERIAL_EFFICIENCY)
				else 0
			for _, recipeInput in definition.Inputs do
				local requiredAmount = math.max(1, math.ceil(recipeInput.Amount * (1 - materialEfficiency)))
				local _, removeReason = inventory.RemoveStackFromData(data, recipeInput.ItemDefinitionId, requiredAmount)
				if removeReason then
					abort(removeReason)
				end
			end

			local outputInstanceId: string? = nil
			if outputItem.Kind == "Stackable" then
				local totalAmount, addReason = inventory.AddStackToData(data, definition.OutputItemId, definition.OutputAmount)
				if type(totalAmount) ~= "number" then
					abort(addReason or "InventoryUpdateFailed")
				end
			else
				-- Inventory is the sole owner of discrete-item creation, including instance-ID generation.
				local discreteItem, addReason = inventory.AddDiscreteItemToData(data, definition.OutputItemId)
				if not discreteItem then
					abort(addReason or "InventoryUpdateFailed")
				end
				outputInstanceId = (discreteItem :: any).InstanceId
			end

			local awardedState, xpReason = skills.AwardXPToData(data, definition.SkillId, definition.SmithingXP)
			if not awardedState then
				abort(xpReason or "XPUpdateFailed")
			end

			result = {
				RecipeId = definition.Id,
				OutputItemId = definition.OutputItemId,
				OutputAmount = definition.OutputAmount,
				OutputInstanceId = outputInstanceId,
				SmithingXP = definition.SmithingXP,
				SmithingState = awardedState,
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
