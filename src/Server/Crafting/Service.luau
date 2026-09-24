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
	read GetStackFromData: (any, string) -> (number?, string?),
}
export type Skills = {
	read GetStateFromData: (any, string) -> (any?, string?),
	read AwardXPToData: (any, string, number) -> (any?, string?),
}
-- A batch request: an explicit whole Quantity (>= 1), or Max = true to craft the maximum currently
-- affordable quantity (computed server-side). Omitted/nil is treated as a single craft (Quantity 1),
-- so existing single-craft callers stay compatible.
export type CraftRequest = {
	Quantity: number?,
	Max: boolean?,
}
export type Result = {
	RecipeId: string,
	OutputItemId: string,
	-- Per-craft output amount (unchanged). Quantity is how many crafts this batch performed.
	OutputAmount: number,
	Quantity: number,
	-- First created discrete instance (single-craft compatibility) and the full batch list.
	OutputInstanceId: string?,
	OutputInstanceIds: { string },
	-- Total materials consumed per input across the whole batch, keyed by item id.
	InputsConsumed: { [string]: number },
	-- Total Smithing XP awarded for the batch (base recipe XP * Quantity).
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

-- A single batch request is bounded to a clear maximum rather than allowing magic oversized quantities;
-- Craft Max is expressed through this same bound, never a huge sentinel number.
local MAX_BATCH_QUANTITY = 1000

-- Trusted server systems (a shared or personal Forge) call service.Craft; no recipe logic lives in Studio.
local Service = { MaximumBatchQuantity = MAX_BATCH_QUANTITY }

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= 9007199254740991
end

-- A quantity is valid only if it is a positive whole number within the batch bound. Fractional,
-- negative, zero, non-finite, or over-bound requests fail closed -- the client can never widen this.
local function validBatchQuantity(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and value >= 1 and value <= MAX_BATCH_QUANTITY
end

-- The one approved, deterministic batch material rule: efficiency is applied to the WHOLE batch's base
-- cost and rounded up once, floored at 1. Because ceil is superadditive (ceil(x)+ceil(y) >= ceil(x+y)),
-- a single batch of N is always the cheapest possible -- splitting an equivalent quantity into smaller
-- requests can only ever cost the same or MORE, so no rounding exploit exists. eff is 0 for
-- non-equipment (smelting), so Iron Ore -> Iron Bar is never discounted.
local function inputCost(baseAmount: number, quantity: number, efficiency: number): number
	if quantity <= 0 then
		return 0
	end
	return math.max(1, math.ceil(baseAmount * quantity * (1 - efficiency)))
end

-- Largest whole quantity whose batch input cost still fits in `available`. Since ceil(x) <= a (integer
-- a) iff x <= a, the closed form is floor(available / (base * (1 - eff))); it is then verified against
-- the exact cost to absorb any floating-point edge so the result is deterministic and never over-grants.
local function maxAffordableForInput(available: number, baseAmount: number, efficiency: number): number
	local denominator = baseAmount * (1 - efficiency)
	if denominator <= 0 then
		return 0
	end
	local estimate = math.floor(available / denominator)
	if estimate < 0 then
		estimate = 0
	end
	while estimate > 0 and inputCost(baseAmount, estimate, efficiency) > available do
		estimate -= 1
	end
	while estimate < MAX_BATCH_QUANTITY and inputCost(baseAmount, estimate + 1, efficiency) <= available do
		estimate += 1
	end
	return estimate
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
			and type(inventory.AddDiscreteItemToData) == "function"
			and type(inventory.GetStackFromData) == "function",
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

	-- Crafts `request` crafts of `recipeId` in one atomic, server-authoritative transaction. `request`
	-- is an explicit whole Quantity, Max = true for the maximum currently affordable, or nil for a
	-- single craft (single-craft callers stay compatible). The client never decides how many crafts are
	-- affordable and never awards its own outputs.
	function service.Craft(userId: number, recipeId: string, request: CraftRequest?): (Result?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if request ~= nil and type(request) ~= "table" then
			return nil, "InvalidCraftRequest"
		end
		local definition, definitionReason = definitionFor(recipeId)
		if not definition then
			return nil, definitionReason
		end
		local outputItem = ItemDefinitions.ById[definition.OutputItemId]
		if not outputItem then
			return nil, "InvalidRecipeOutput"
		end
		-- Forgemaster is "material efficiency when forging EQUIPMENT" (docs/MASTERY_TREES.md), so
		-- MaterialEfficiencyBonus applies only to recipes whose output is an equippable item, detected
		-- from the output item's own Equipment metadata. A smelting recipe (Iron Ore -> Iron Bar) is
		-- excluded; the upgraded sword qualifies.
		local outputIsEquipment = outputItem.Equipment ~= nil

		-- Resolve the requested mode up front (cheap validation before opening the transaction). Max is
		-- resolved to an actual quantity inside the transaction, from the same data it will mutate.
		local wantMax = type(request) == "table" and request.Max == true
		local explicitQuantity: number? = nil
		if not wantMax then
			local requested: any = if type(request) == "table" and request.Quantity ~= nil then request.Quantity else 1
			if not validBatchQuantity(requested) then
				return nil, "InvalidQuantity"
			end
			explicitQuantity = requested
		end

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

			-- Both Smithing production branches reduce input material cost, applied to their own recipe
			-- class (docs/MASTERY_TREES.md): Forgemaster's MaterialEfficiencyBonus for EQUIPMENT recipes,
			-- Smelter's ProcessingEfficiencyBonus for ore-to-bar SMELTING (non-equipment) recipes. Craft is
			-- an atomic transaction with no action-time to shorten, so Smelter's "faster and/or more
			-- efficient ore-to-bar processing" is realised as the efficiency half (less ore per bar).
			local efficiencyKey = if outputIsEquipment then "MaterialEfficiencyBonus" else "ProcessingEfficiencyBonus"
			local materialEfficiency = math.clamp(math.max(0, modifierTotal(resolveSmithingModifiers(data), efficiencyKey)), 0, MAX_MATERIAL_EFFICIENCY)

			-- Determine the batch quantity. Craft Max is computed here from authoritative available
			-- materials (the tightest input), bounded by MAX_BATCH_QUANTITY -- never a client-supplied max.
			local quantity: number
			if wantMax then
				local maxQuantity = MAX_BATCH_QUANTITY
				for _, recipeInput in definition.Inputs do
					local available, availableReason = inventory.GetStackFromData(data, recipeInput.ItemDefinitionId)
					if type(available) ~= "number" then
						abort(availableReason or "InvalidInventory")
					end
					maxQuantity = math.min(maxQuantity, maxAffordableForInput(available :: number, recipeInput.Amount, materialEfficiency))
				end
				if maxQuantity < 1 then
					abort("InsufficientItems")
				end
				quantity = maxQuantity
			else
				quantity = explicitQuantity :: number
			end

			-- Consume the whole batch's material cost per input (one aggregate removal each).
			local inputsConsumed: { [string]: number } = {}
			for _, recipeInput in definition.Inputs do
				local cost = inputCost(recipeInput.Amount, quantity, materialEfficiency)
				local _, removeReason = inventory.RemoveStackFromData(data, recipeInput.ItemDefinitionId, cost)
				if removeReason then
					abort(removeReason)
				end
				inputsConsumed[recipeInput.ItemDefinitionId] = cost
			end

			-- Produce the batch output: one aggregate stack, or `quantity` distinct discrete instances
			-- (each created through Inventory's own ownership boundary, so every instance ID is unique).
			local instanceIds: { string } = {}
			if outputItem.Kind == "Stackable" then
				local totalAmount, addReason = inventory.AddStackToData(data, definition.OutputItemId, definition.OutputAmount * quantity)
				if type(totalAmount) ~= "number" then
					abort(addReason or "InventoryUpdateFailed")
				end
			else
				for _ = 1, quantity do
					local discreteItem, addReason = inventory.AddDiscreteItemToData(data, definition.OutputItemId)
					if not discreteItem then
						abort(addReason or "InventoryUpdateFailed")
					end
					table.insert(instanceIds, (discreteItem :: any).InstanceId)
				end
			end

			-- Smithing XP scales with the number of completed crafts (the obvious proportional result).
			local totalXP = definition.SmithingXP * quantity
			local awardedState, xpReason = skills.AwardXPToData(data, definition.SkillId, totalXP)
			if not awardedState then
				abort(xpReason or "XPUpdateFailed")
			end

			result = {
				RecipeId = definition.Id,
				OutputItemId = definition.OutputItemId,
				OutputAmount = definition.OutputAmount,
				Quantity = quantity,
				OutputInstanceId = instanceIds[1],
				OutputInstanceIds = instanceIds,
				InputsConsumed = inputsConsumed,
				SmithingXP = totalXP,
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
