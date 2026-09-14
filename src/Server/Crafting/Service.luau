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

-- Trusted server systems (a shared or personal Forge) call service.Craft; no recipe logic lives in Studio.
local Service = {}

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= 9007199254740991
end

local function validStableId(value: any): boolean
	return type(value) == "string" and value ~= ""
end

function Service.New(playerData: PlayerData, inventory: Inventory, skills: Skills)
	assert(type(playerData) == "table" and type(playerData.Update) == "function", "Crafting requires PlayerData")
	assert(
		type(inventory) == "table"
			and type(inventory.AddStackToData) == "function"
			and type(inventory.RemoveStackFromData) == "function"
			and type(inventory.AddDiscreteItemToData) == "function",
		"Crafting requires Inventory"
	)
	assert(type(skills) == "table" and type(skills.GetStateFromData) == "function" and type(skills.AwardXPToData) == "function", "Crafting requires Skills")
	local valid, reason = Definitions.Validate(Definitions.ById)
	assert(valid, reason)

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

			for _, recipeInput in definition.Inputs do
				local _, removeReason = inventory.RemoveStackFromData(data, recipeInput.ItemDefinitionId, recipeInput.Amount)
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
