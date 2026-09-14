--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local EquipmentSlots = require(Shared.EquipmentSlots)
local ItemDefinitions = require(Shared.ItemDefinitions)
local Definitions = require(script.Parent.Definitions)

export type PlayerData = {
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type Equipment = {
	read GetEquippedItem: (number, string) -> (any?, string?),
}
export type Inventory = {
	read AddStackToData: (any, string, number) -> (number?, string?),
}
export type Skills = {
	read GetStateFromData: (any, string) -> (any?, string?),
	read AwardXPToData: (any, string, number) -> (any?, string?),
}
export type Node = {
	Id: string,
	Eligible: boolean,
	Distance: number,
}
export type NodeResolver = (number, string) -> (Node?, string?)
export type Result = {
	NodeId: string,
	ToolInstanceId: string,
	ToolDefinitionId: string,
	OreDefinitionId: string,
	OreAmount: number,
	TotalOre: number,
	MiningXP: number,
	MiningState: any,
}

local Service = { MaximumElapsedSeconds = 60 }

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= 9007199254740991
end

local function validStableId(value: any): boolean
	return type(value) == "string" and value ~= ""
end

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

local function finiteNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and math.abs(value) < math.huge
end

local function validMiningTool(data: any): boolean
	return type(data) == "table" and finitePositive(data.GatheringRateMultiplier)
end

function Service.New(playerData: PlayerData, equipment: Equipment, inventory: Inventory, skills: Skills, resolveNode: NodeResolver)
	assert(type(playerData) == "table" and type(playerData.Update) == "function", "Gathering requires PlayerData")
	assert(type(equipment) == "table" and type(equipment.GetEquippedItem) == "function", "Gathering requires Equipment")
	assert(type(inventory) == "table" and type(inventory.AddStackToData) == "function", "Gathering requires Inventory")
	assert(type(skills) == "table" and type(skills.GetStateFromData) == "function" and type(skills.AwardXPToData) == "function", "Gathering requires Skills")
	assert(type(resolveNode) == "function", "Gathering requires a trusted node resolver")
	local valid, reason = Definitions.Validate(Definitions.ById)
	assert(valid, reason)

	local service = {}

	local function definitionFor(nodeId: any): (Definitions.Definition?, string?)
		if not validStableId(nodeId) then
			return nil, "InvalidNodeId"
		end
		local definition = Definitions.ById[nodeId]
		if not definition then
			return nil, "InvalidNodeId"
		end
		return definition, nil
	end

	function service.GatherForElapsed(userId: number, nodeId: string, elapsedSeconds: number): (Result?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local definition, definitionReason = definitionFor(nodeId)
		if not definition then
			return nil, definitionReason
		end
		if not finitePositive(elapsedSeconds) or elapsedSeconds > Service.MaximumElapsedSeconds then
			return nil, "InvalidElapsedSeconds"
		end
		local node, nodeReason = resolveNode(userId, nodeId)
		if not node then
			return nil, nodeReason or "InvalidNode"
		end
		if node.Id ~= nodeId or not finiteNonNegative(node.Distance) then
			return nil, "InvalidNode"
		end
		if node.Eligible ~= true then
			return nil, "IneligibleNode"
		end
		if node.Distance > definition.MaximumRange then
			return nil, "NodeOutOfRange"
		end

		local equipped, equippedReason = equipment.GetEquippedItem(userId, EquipmentSlots.Tool)
		if type(equipped) ~= "table" then
			return nil, equippedReason or "NoMiningTool"
		end
		local instanceId = equipped.InstanceId
		local definitionId = equipped.DefinitionId
		if type(instanceId) ~= "string" or instanceId == "" or type(definitionId) ~= "string" or definitionId == "" then
			return nil, "InvalidEquipment"
		end
		local toolInstanceId: string = instanceId
		local toolDefinitionId: string = definitionId
		local toolDefinition = ItemDefinitions.ById[definitionId]
		local mining = if toolDefinition then toolDefinition.Mining else nil
		if not toolDefinition or toolDefinition.Kind ~= "Discrete" or not toolDefinition.Equipment or toolDefinition.Equipment.SlotId ~= EquipmentSlots.Tool or not mining or not validMiningTool(mining) then
			return nil, "InvalidMiningTool"
		end

		local oreAmount = math.floor(definition.OrePerSecond * mining.GatheringRateMultiplier * elapsedSeconds)
		local miningXP = definition.MiningXPPerSecond * mining.GatheringRateMultiplier * elapsedSeconds
		if oreAmount < 1 or oreAmount > 9007199254740991 or not finitePositive(miningXP) then
			return nil, "GatheringIntervalTooShort"
		end

		local result: Result? = nil
		local mutationReason: string? = nil
		local function abort(reason: string)
			mutationReason = reason
			error(reason, 0)
		end
		local ok, updateReason = playerData.Update(userId, function(data)
			local miningState, stateReason = skills.GetStateFromData(data, definition.SkillId)
			if not miningState then
				abort(stateReason or "InvalidMiningState")
			end
			if miningState.Level < definition.RequiredMiningLevel then
				abort("InsufficientMiningLevel")
			end
			local totalOre, inventoryReason = inventory.AddStackToData(data, definition.OutputItemId, oreAmount)
			if type(totalOre) ~= "number" then
				abort(inventoryReason or "InventoryUpdateFailed")
			end
			local resultingOre = totalOre :: number
			local awardedState, xpReason = skills.AwardXPToData(data, definition.SkillId, miningXP)
			if not awardedState then
				abort(xpReason or "XPUpdateFailed")
			end
			result = {
				NodeId = definition.Id,
				ToolInstanceId = toolInstanceId,
				ToolDefinitionId = toolDefinitionId,
				OreDefinitionId = definition.OutputItemId,
				OreAmount = oreAmount,
				TotalOre = resultingOre,
				MiningXP = miningXP,
				MiningState = awardedState,
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
