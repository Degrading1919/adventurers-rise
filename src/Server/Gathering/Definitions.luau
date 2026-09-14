--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local GatheringNodeIds = require(Shared.GatheringNodeIds)
local ItemDefinitions = require(Shared.ItemDefinitions)
local SkillIds = require(Shared.SkillIds)

export type Definition = {
	read Id: string,
	read DisplayName: string,
	read OutputItemId: string,
	read SkillId: string,
	read RequiredMiningLevel: number,
	read MaximumRange: number,
	read IsDepleting: boolean,
	read OrePerSecond: number,
	read MiningXPPerSecond: number,
}

local GatheringDefinitions = {}

local function positiveWhole(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

local function definition(id: string, displayName: string, outputItemId: string, requiredMiningLevel: number, maximumRange: number, orePerSecond: number, miningXPPerSecond: number): Definition
	return table.freeze({
		Id = id,
		DisplayName = displayName,
		OutputItemId = outputItemId,
		SkillId = SkillIds.Mining,
		RequiredMiningLevel = requiredMiningLevel,
		MaximumRange = maximumRange,
		IsDepleting = false,
		OrePerSecond = orePerSecond,
		MiningXPPerSecond = miningXPPerSecond,
	})
end

-- These requirements, range, yields, and XP rates are provisional and replaceable data.
local definitions: { [string]: Definition } = {
	[GatheringNodeIds.IronOre] = definition(GatheringNodeIds.IronOre, "Iron Ore", "item_iron_ore", 1, 12, 1, 2),
}

function GatheringDefinitions.Validate(candidateDefinitions: any): (boolean, string?)
	if type(candidateDefinitions) ~= "table" then
		return false, "Gathering definitions must be a table"
	end
	for nodeId, node in candidateDefinitions do
		if type(nodeId) ~= "string" or nodeId == "" or GatheringNodeIds.ById[nodeId] ~= true or type(node) ~= "table" or node.Id ~= nodeId then
			return false, "Gathering node IDs must be stable"
		end
		if type(node.DisplayName) ~= "string" or node.DisplayName == "" then
			return false, "Gathering nodes require a display name"
		end
		local item = ItemDefinitions.ById[node.OutputItemId]
		if not item or item.Kind ~= "Stackable" or node.SkillId ~= SkillIds.Mining then
			return false, "Gathering nodes require valid output and Mining skill IDs"
		end
		if not positiveWhole(node.RequiredMiningLevel) or not finitePositive(node.MaximumRange) or node.IsDepleting ~= false or not finitePositive(node.OrePerSecond) or not finitePositive(node.MiningXPPerSecond) then
			return false, "Gathering node rates and requirements must be valid"
		end
	end
	return true, nil
end

return table.freeze({
	ById = table.freeze(definitions),
	Validate = GatheringDefinitions.Validate,
})
