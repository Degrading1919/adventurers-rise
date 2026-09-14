--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local RecipeIds = require(Shared.RecipeIds)
local ItemDefinitions = require(Shared.ItemDefinitions)
local SkillIds = require(Shared.SkillIds)

export type Input = {
	read ItemDefinitionId: string,
	read Amount: number,
}
export type Definition = {
	read Id: string,
	read DisplayName: string,
	read SkillId: string,
	read RequiredSmithingLevel: number,
	read Inputs: { Input },
	read OutputItemId: string,
	read OutputAmount: number,
	read SmithingXP: number,
	read DurationSeconds: number,
}

local CraftingDefinitions = {}

local function positiveWhole(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

local function input(itemDefinitionId: string, amount: number): Input
	return table.freeze({ ItemDefinitionId = itemDefinitionId, Amount = amount })
end

local function definition(
	id: string,
	displayName: string,
	requiredSmithingLevel: number,
	inputs: { Input },
	outputItemId: string,
	outputAmount: number,
	smithingXP: number,
	durationSeconds: number
): Definition
	return table.freeze({
		Id = id,
		DisplayName = displayName,
		SkillId = SkillIds.Smithing,
		RequiredSmithingLevel = requiredSmithingLevel,
		Inputs = table.freeze(inputs),
		OutputItemId = outputItemId,
		OutputAmount = outputAmount,
		SmithingXP = smithingXP,
		DurationSeconds = durationSeconds,
	})
end

-- Requirements, quantities, XP, and durations are provisional and replaceable data.
local definitions: { [string]: Definition } = {
	[RecipeIds.IronBar] = definition(RecipeIds.IronBar, "Iron Bar", 1, { input("item_iron_ore", 2) }, "item_iron_bar", 1, 6, 2),
	[RecipeIds.SwordUpgraded] = definition(RecipeIds.SwordUpgraded, "Upgraded Iron Sword", 5, { input("item_iron_bar", 3) }, "weapon_sword_upgraded", 1, 20, 4),
}

function CraftingDefinitions.Validate(candidateDefinitions: any): (boolean, string?)
	if type(candidateDefinitions) ~= "table" then
		return false, "Recipe definitions must be a table"
	end
	for recipeId, recipe in candidateDefinitions do
		if type(recipeId) ~= "string" or recipeId == "" or RecipeIds.ById[recipeId] ~= true or type(recipe) ~= "table" or recipe.Id ~= recipeId then
			return false, "Recipe IDs must be stable"
		end
		if type(recipe.DisplayName) ~= "string" or recipe.DisplayName == "" then
			return false, "Recipes require a display name"
		end
		if recipe.SkillId ~= SkillIds.Smithing or not positiveWhole(recipe.RequiredSmithingLevel) then
			return false, "Recipes require a valid Smithing skill and level"
		end
		if type(recipe.Inputs) ~= "table" or #recipe.Inputs == 0 then
			return false, "Recipes require at least one input"
		end
		local seenInputs: { [string]: boolean } = {}
		for _, recipeInput in recipe.Inputs do
			local itemDefinitionId = recipeInput.ItemDefinitionId
			if type(itemDefinitionId) ~= "string" or seenInputs[itemDefinitionId] then
				return false, "Recipe inputs must reference distinct valid items"
			end
			local itemDefinition = ItemDefinitions.ById[itemDefinitionId]
			if not itemDefinition or itemDefinition.Kind ~= "Stackable" or not positiveWhole(recipeInput.Amount) then
				return false, "Recipe inputs must be valid stackable amounts"
			end
			seenInputs[itemDefinitionId] = true
		end
		local outputItem = ItemDefinitions.ById[recipe.OutputItemId]
		if not outputItem then
			return false, "Recipes require a valid output item"
		end
		if outputItem.Kind == "Stackable" then
			if not positiveWhole(recipe.OutputAmount) then
				return false, "Stackable recipe outputs require a positive amount"
			end
		elseif outputItem.Kind == "Discrete" then
			if recipe.OutputAmount ~= 1 then
				return false, "Discrete recipe outputs must produce exactly one instance"
			end
		else
			return false, "Recipes require a known output kind"
		end
		if not finitePositive(recipe.SmithingXP) or not finitePositive(recipe.DurationSeconds) then
			return false, "Recipes require valid XP and duration"
		end
	end
	return true, nil
end

return table.freeze({
	ById = table.freeze(definitions),
	Validate = CraftingDefinitions.Validate,
})
