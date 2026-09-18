--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local EquipmentSlots = require(Shared.EquipmentSlots)
local ItemDefinitions = require(Shared.ItemDefinitions)
local Definitions = require(script.Parent.Definitions)

export type PlayerData = {
	read GetSnapshot: (number) -> any?,
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
export type ToolInfo = {
	ToolInstanceId: string,
	ToolDefinitionId: string,
	Mining: any,
}
export type ValidateResult = {
	NodeId: string,
	ToolInstanceId: string,
	ToolDefinitionId: string,
}
-- Server-owned Mastery modifier totals for the gatherer's Mining tree (see Mastery.GetModifiers, the
-- single source of truth). Gathering only READS the totals it cares about; it never recomputes nodes.
export type ModifierTotals = { [string]: number }
export type MiningModifierProvider = (number) -> ModifierTotals

local Service = { MaximumElapsedSeconds = 60 }

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

function Service.New(playerData: PlayerData, equipment: Equipment, inventory: Inventory, skills: Skills, resolveNode: NodeResolver, miningModifiers: MiningModifierProvider?)
	assert(type(playerData) == "table" and type(playerData.GetSnapshot) == "function" and type(playerData.Update) == "function", "Gathering requires PlayerData")
	assert(type(equipment) == "table" and type(equipment.GetEquippedItem) == "function", "Gathering requires Equipment")
	assert(type(inventory) == "table" and type(inventory.AddStackToData) == "function", "Gathering requires Inventory")
	assert(type(skills) == "table" and type(skills.GetStateFromData) == "function" and type(skills.AwardXPToData) == "function", "Gathering requires Skills")
	assert(type(resolveNode) == "function", "Gathering requires a trusted node resolver")
	assert(miningModifiers == nil or type(miningModifiers) == "function", "Gathering miningModifiers must be a function when provided")
	local valid, reason = Definitions.Validate(Definitions.ById)
	assert(valid, reason)
	-- Defaults to "no selected Mastery" so callers/tests that do not wire Mastery keep exact prior
	-- ore/XP output. Composition injects the real server-authoritative Mining provider.
	local resolveMiningModifiers: MiningModifierProvider = miningModifiers or function()
		return {}
	end

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

	-- The one place node/range/eligibility/equipped-Tool validation lives. Used both by
	-- GatherForElapsed (before its PlayerData.Update transaction, as before) and by
	-- ValidateForBegin (a read-only pre-check for a trusted session coordinator's Begin request),
	-- so neither duplicates the other's world/equipment checks.
	local function validateEligibility(userId: number, nodeId: string, definition: Definitions.Definition): (Node?, ToolInfo?, string?)
		local node, nodeReason = resolveNode(userId, nodeId)
		if not node then
			return nil, nil, nodeReason or "InvalidNode"
		end
		if node.Id ~= nodeId or not finiteNonNegative(node.Distance) then
			return nil, nil, "InvalidNode"
		end
		if node.Eligible ~= true then
			return nil, nil, "IneligibleNode"
		end
		if node.Distance > definition.MaximumRange then
			return nil, nil, "NodeOutOfRange"
		end

		local equipped, equippedReason = equipment.GetEquippedItem(userId, EquipmentSlots.Tool)
		if type(equipped) ~= "table" then
			return nil, nil, equippedReason or "NoMiningTool"
		end
		local instanceId = equipped.InstanceId
		local definitionId = equipped.DefinitionId
		if type(instanceId) ~= "string" or instanceId == "" or type(definitionId) ~= "string" or definitionId == "" then
			return nil, nil, "InvalidEquipment"
		end
		local toolDefinition = ItemDefinitions.ById[definitionId]
		local mining = if toolDefinition then toolDefinition.Mining else nil
		if not toolDefinition or toolDefinition.Kind ~= "Discrete" or not toolDefinition.Equipment or toolDefinition.Equipment.SlotId ~= EquipmentSlots.Tool or not mining or not validMiningTool(mining) then
			return nil, nil, "InvalidMiningTool"
		end
		return node, { ToolInstanceId = instanceId :: string, ToolDefinitionId = definitionId :: string, Mining = mining }, nil
	end

	-- The one place the Mining-level requirement is checked, against whatever `data` the caller
	-- provides -- the live transactional snapshot for GatherForElapsed, or a read-only
	-- GetSnapshot copy for ValidateForBegin.
	local function validateMiningLevel(data: any, definition: Definitions.Definition): (any?, string?)
		local miningState, stateReason = skills.GetStateFromData(data, definition.SkillId)
		if not miningState then
			return nil, stateReason
		end
		if miningState.Level < definition.RequiredMiningLevel then
			return nil, "InsufficientMiningLevel"
		end
		return miningState, nil
	end

	-- Trusted, non-mutating pre-check for a session coordinator's Begin request: proves the node,
	-- range, eligibility, equipped tool, and Mining level are all currently valid without awarding
	-- any ore or XP. Reuses exactly the same validation the real award path uses.
	function service.ValidateForBegin(userId: number, nodeId: string): (ValidateResult?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local definition, definitionReason = definitionFor(nodeId)
		if not definition then
			return nil, definitionReason
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local miningState, levelReason = validateMiningLevel(data, definition)
		if not miningState then
			return nil, levelReason
		end
		local _node, toolInfo, validateReason = validateEligibility(userId, nodeId, definition)
		if not toolInfo then
			return nil, validateReason
		end
		return { NodeId = definition.Id, ToolInstanceId = toolInfo.ToolInstanceId, ToolDefinitionId = toolInfo.ToolDefinitionId }, nil
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
		local _node, toolInfo, validateReason = validateEligibility(userId, nodeId, definition)
		if not toolInfo then
			return nil, validateReason
		end
		local mining = toolInfo.Mining
		local toolInstanceId = toolInfo.ToolInstanceId
		local toolDefinitionId = toolInfo.ToolDefinitionId

		-- Apply the gatherer's Mining Mastery totals to the trusted per-second output. Both bonuses are
		-- additive fractions clamped to non-negative, and the trusted `elapsedSeconds` is never touched,
		-- so results stay bounded and fully deterministic (no elapsed-time exploit). GatheringSpeedBonus
		-- scales the per-second rate (more ore AND more XP per real second); PrimaryYieldBonus enriches
		-- the ore output only (extra ore per gather, no XP change).
		local miningModifierTotals = resolveMiningModifiers(userId)
		local speedMultiplier = 1 + math.max(0, modifierTotal(miningModifierTotals, "GatheringSpeedBonus"))
		local yieldMultiplier = 1 + math.max(0, modifierTotal(miningModifierTotals, "PrimaryYieldBonus"))

		local oreAmount = math.floor(definition.OrePerSecond * mining.GatheringRateMultiplier * elapsedSeconds * speedMultiplier * yieldMultiplier)
		local miningXP = definition.MiningXPPerSecond * mining.GatheringRateMultiplier * elapsedSeconds * speedMultiplier
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
			local miningState, stateReason = validateMiningLevel(data, definition)
			if not miningState then
				abort(stateReason or "InvalidMiningState")
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
