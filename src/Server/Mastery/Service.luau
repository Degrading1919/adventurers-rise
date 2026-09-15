--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local SkillIds = require(Shared.SkillIds)
local Definitions = require(script.Parent.Definitions)

export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type SkillState = { Level: number }
export type Skills = {
	read GetStateFromData: (any, string) -> (SkillState?, string?),
}
export type Economy = {
	read DebitGoldToData: (any, number) -> (number?, string?),
}

export type ModifierTotals = { [string]: number }
export type NodeState = {
	Id: string,
	BranchId: string,
	Position: number,
	DisplayName: string,
	Description: string,
	RequiredLevel: number,
	PointCost: number,
	Selected: boolean,
	PrerequisiteSatisfied: boolean,
	Selectable: boolean,
	LockedReason: string?,
}
export type BranchState = {
	Id: string,
	DisplayName: string,
	Nodes: { NodeState },
}
export type State = {
	SkillId: string,
	Level: number,
	EarnedPoints: number,
	SpentPoints: number,
	AvailablePoints: number,
	Branches: { BranchState },
	FreeRespecAvailable: boolean,
	NextRespecGoldCost: number,
}
export type SelectResult = {
	SkillId: string,
	NodeId: string,
	SpentPoints: number,
	AvailablePoints: number,
}
export type RespecResult = {
	SkillId: string,
	WasFree: boolean,
	GoldCost: number,
	ClearedNodeIds: { string },
}

-- One reusable mastery-tree system for every skill; only Melee/Defense/Mining/Smithing have
-- content in Definitions right now, but nothing here special-cases a particular skill or node.
local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function validNodeId(value: any): boolean
	return type(value) == "string" and value ~= ""
end

-- Mastery Point unlock cadence (docs/MASTERY_TREES.md). Earned points are always derived from
-- the player's current authoritative skill level -- never stored as an independent balance.
local POINT_UNLOCK_LEVELS = { 5, 10, 15, 20, 30, 40, 50, 60 }

local function earnedPointsForLevel(level: number): number
	local points = 0
	for _, unlockLevel in POINT_UNLOCK_LEVELS do
		if level >= unlockLevel then
			points += 1
		end
	end
	return points
end

function Service.New(playerData: PlayerData, skills: Skills, economy: Economy)
	assert(type(playerData) == "table" and type(playerData.GetSnapshot) == "function" and type(playerData.Update) == "function", "Mastery requires PlayerData")
	assert(type(skills) == "table" and type(skills.GetStateFromData) == "function", "Mastery requires Skills")
	assert(type(economy) == "table" and type(economy.DebitGoldToData) == "function", "Mastery requires Economy")
	local valid, reason = Definitions.Validate(Definitions.ById)
	assert(valid, reason)

	local knownSkillIds: { [string]: boolean } = {}
	for _, id in SkillIds do
		knownSkillIds[id] = true
	end

	local service = {}

	local function treeFor(skillId: any): (Definitions.SkillTree?, string?)
		if type(skillId) ~= "string" or knownSkillIds[skillId] ~= true then
			return nil, "InvalidSkillId"
		end
		local tree = Definitions.ById[skillId]
		if not tree then
			return nil, "SkillHasNoMasteryContent"
		end
		return tree, nil
	end

	local function selectionsFor(data: any, skillId: string): ({ [string]: boolean }?, string?)
		local allSelections = data.MasterySelections
		if type(allSelections) ~= "table" then
			return nil, "InvalidMasteryState"
		end
		local skillSelections = allSelections[skillId]
		if type(skillSelections) ~= "table" then
			return nil, "InvalidMasteryState"
		end
		return skillSelections, nil
	end

	local function respecHistoryFor(data: any): ({ [string]: boolean }?, string?)
		local history = data.MasteryRespecs
		if type(history) ~= "table" then
			return nil, "InvalidMasteryRespecState"
		end
		return history, nil
	end

	-- Structurally validates persisted selections (known nodes, correct skill, sequential
	-- prerequisites, spent <= earned) and fails closed on any corruption. Returns the live
	-- (uncoppied) selection table for trusted in-transaction mutation, plus its spent-point count.
	local function validatedSelections(data: any, skillId: string, tree: Definitions.SkillTree, level: number): ({ [string]: boolean }?, number?, string?)
		local skillSelections, reason = selectionsFor(data, skillId)
		if not skillSelections then
			return nil, nil, reason
		end
		local spent = 0
		for nodeId, isSelected in skillSelections do
			if isSelected ~= true then
				return nil, nil, "InvalidMasteryState"
			end
			local node = Definitions.NodesById[nodeId]
			if not node or node.SkillId ~= skillId then
				return nil, nil, "InvalidMasteryState"
			end
			spent += node.PointCost
		end
		for _, branchDef in tree.Branches do
			local seenGap = false
			for _, node in branchDef.Nodes do
				local isSelected = skillSelections[node.Id] == true
				if isSelected and seenGap then
					return nil, nil, "InvalidMasteryState"
				end
				if not isSelected then
					seenGap = true
				end
			end
		end
		if spent > earnedPointsForLevel(level) then
			return nil, nil, "InvalidMasteryState"
		end
		return skillSelections, spent, nil
	end

	local function aggregateModifiers(tree: Definitions.SkillTree, skillSelections: { [string]: boolean }): ModifierTotals
		local totals: ModifierTotals = {}
		for _, branchDef in tree.Branches do
			for _, node in branchDef.Nodes do
				if skillSelections[node.Id] == true then
					totals[node.Effect.Type] = (totals[node.Effect.Type] or 0) + node.Effect.Value
				end
			end
		end
		return totals
	end

	-- Shared by CanSelect, Select, and the read model so eligibility rules live in one place.
	local function evaluateSelection(
		data: any,
		skillId: string,
		nodeId: string
	): (boolean, string?, Definitions.Node?, { [string]: boolean }?, number?, number?)
		local tree, treeReason = treeFor(skillId)
		if not tree then
			return false, treeReason, nil, nil, nil, nil
		end
		local node = Definitions.NodesById[nodeId]
		if not node or node.SkillId ~= skillId then
			return false, "InvalidNodeId", nil, nil, nil, nil
		end
		local skillState, skillReason = skills.GetStateFromData(data, skillId)
		if not skillState then
			return false, skillReason, node, nil, nil, nil
		end
		local skillSelections, spent, selectionsReason = validatedSelections(data, skillId, tree, skillState.Level)
		if not skillSelections then
			return false, selectionsReason, node, nil, nil, nil
		end
		if skillSelections[nodeId] == true then
			return false, "NodeAlreadySelected", node, skillSelections, spent, nil
		end
		if skillState.Level < node.RequiredLevel then
			return false, "InsufficientSkillLevel", node, skillSelections, spent, nil
		end
		if node.Position > 1 then
			local branchDef = Definitions.BranchesById[node.BranchId]
			local previousNode = branchDef.Nodes[node.Position - 1]
			if skillSelections[previousNode.Id] ~= true then
				return false, "PrerequisiteNodeNotSelected", node, skillSelections, spent, nil
			end
		end
		local earned = earnedPointsForLevel(skillState.Level)
		local available = earned - (spent :: number)
		if available < node.PointCost then
			return false, "InsufficientMasteryPoints", node, skillSelections, spent, available
		end
		return true, nil, node, skillSelections, spent, available
	end

	function service.GetStateFromData(data: any, skillId: string): (State?, string?)
		local tree, treeReason = treeFor(skillId)
		if not tree then
			return nil, treeReason
		end
		local skillState, skillReason = skills.GetStateFromData(data, skillId)
		if not skillState then
			return nil, skillReason
		end
		local level = skillState.Level
		local skillSelections, spent, selectionsReason = validatedSelections(data, skillId, tree, level)
		if not skillSelections then
			return nil, selectionsReason
		end
		local history, historyReason = respecHistoryFor(data)
		if not history then
			return nil, historyReason
		end
		local earned = earnedPointsForLevel(level)
		local available = earned - (spent :: number)
		local usedFreeRespec = history[skillId] == true

		local branches: { BranchState } = {}
		for _, branchDef in tree.Branches do
			local nodeStates: { NodeState } = {}
			for position, node in branchDef.Nodes do
				local selected = skillSelections[node.Id] == true
				local prerequisiteSatisfied = position == 1 or skillSelections[branchDef.Nodes[position - 1].Id] == true
				local selectable = false
				local lockedReason: string? = nil
				if not selected then
					if level < node.RequiredLevel then
						lockedReason = "InsufficientSkillLevel"
					elseif not prerequisiteSatisfied then
						lockedReason = "PrerequisiteNodeNotSelected"
					elseif available < node.PointCost then
						lockedReason = "InsufficientMasteryPoints"
					else
						selectable = true
					end
				end
				table.insert(nodeStates, {
					Id = node.Id,
					BranchId = branchDef.Id,
					Position = node.Position,
					DisplayName = node.DisplayName,
					Description = node.Description,
					RequiredLevel = node.RequiredLevel,
					PointCost = node.PointCost,
					Selected = selected,
					PrerequisiteSatisfied = prerequisiteSatisfied,
					Selectable = selectable,
					LockedReason = lockedReason,
				})
			end
			table.insert(branches, { Id = branchDef.Id, DisplayName = branchDef.DisplayName, Nodes = nodeStates })
		end

		return {
			SkillId = skillId,
			Level = level,
			EarnedPoints = earned,
			SpentPoints = spent :: number,
			AvailablePoints = available,
			Branches = branches,
			FreeRespecAvailable = not usedFreeRespec,
			NextRespecGoldCost = if usedFreeRespec then Definitions.RespecGoldCost(spent :: number) else 0,
		}, nil
	end

	function service.GetState(userId: number, skillId: string): (State?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		return service.GetStateFromData(data, skillId)
	end

	function service.GetEarnedPoints(userId: number, skillId: string): (number?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local _, treeReason = treeFor(skillId)
		if treeReason then
			return nil, treeReason
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local skillState, skillReason = skills.GetStateFromData(data, skillId)
		if not skillState then
			return nil, skillReason
		end
		return earnedPointsForLevel(skillState.Level), nil
	end

	function service.GetSpentPoints(userId: number, skillId: string): (number?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local tree, treeReason = treeFor(skillId)
		if not tree then
			return nil, treeReason
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local skillState, skillReason = skills.GetStateFromData(data, skillId)
		if not skillState then
			return nil, skillReason
		end
		local _, spent, reason = validatedSelections(data, skillId, tree, skillState.Level)
		if not spent then
			return nil, reason
		end
		return spent, nil
	end

	function service.GetAvailablePoints(userId: number, skillId: string): (number?, string?)
		local earned, earnedReason = service.GetEarnedPoints(userId, skillId)
		if not earned then
			return nil, earnedReason
		end
		local spent, spentReason = service.GetSpentPoints(userId, skillId)
		if not spent then
			return nil, spentReason
		end
		return earned - spent, nil
	end

	function service.GetSelectedNodes(userId: number, skillId: string): ({ string }?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local tree, treeReason = treeFor(skillId)
		if not tree then
			return nil, treeReason
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local skillState, skillReason = skills.GetStateFromData(data, skillId)
		if not skillState then
			return nil, skillReason
		end
		local skillSelections, _, reason = validatedSelections(data, skillId, tree, skillState.Level)
		if not skillSelections then
			return nil, reason
		end
		local result: { string } = {}
		for nodeId in skillSelections do
			table.insert(result, nodeId)
		end
		table.sort(result)
		return result, nil
	end

	function service.GetModifiersFromData(data: any, skillId: string): (ModifierTotals?, string?)
		local tree, treeReason = treeFor(skillId)
		if not tree then
			return nil, treeReason
		end
		local skillState, skillReason = skills.GetStateFromData(data, skillId)
		if not skillState then
			return nil, skillReason
		end
		local skillSelections, _, selectionsReason = validatedSelections(data, skillId, tree, skillState.Level)
		if not skillSelections then
			return nil, selectionsReason
		end
		return aggregateModifiers(tree, skillSelections), nil
	end

	function service.GetModifiers(userId: number, skillId: string): (ModifierTotals?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		return service.GetModifiersFromData(data, skillId)
	end

	function service.CanSelect(userId: number, skillId: string, nodeId: string): (boolean?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validNodeId(nodeId) then
			return nil, "InvalidNodeId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local ok, reason = evaluateSelection(data, skillId, nodeId)
		return ok, reason
	end

	function service.Select(userId: number, skillId: string, nodeId: string): (SelectResult?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validNodeId(nodeId) then
			return nil, "InvalidNodeId"
		end

		local result: SelectResult? = nil
		local mutationReason: string? = nil
		local function abort(abortReason: string)
			mutationReason = abortReason
			error(abortReason, 0)
		end
		local ok, updateReason = playerData.Update(userId, function(data)
			local canSelect, reason, node, skillSelections, spent, available = evaluateSelection(data, skillId, nodeId)
			if not canSelect then
				abort(reason or "CannotSelectNode")
			end
			local resolvedNode = node :: Definitions.Node
			local currentSelections = skillSelections :: { [string]: boolean }
			currentSelections[nodeId] = true
			result = {
				SkillId = skillId,
				NodeId = nodeId,
				SpentPoints = (spent :: number) + resolvedNode.PointCost,
				AvailablePoints = (available :: number) - resolvedNode.PointCost,
			}
		end)
		if not ok then
			return nil, mutationReason or updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	function service.Respec(userId: number, skillId: string): (RespecResult?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end

		local result: RespecResult? = nil
		local mutationReason: string? = nil
		local function abort(abortReason: string)
			mutationReason = abortReason
			error(abortReason, 0)
		end
		local ok, updateReason = playerData.Update(userId, function(data)
			local tree, treeReason = treeFor(skillId)
			if not tree then
				abort(treeReason or "InvalidSkillId")
			end
			local skillState, skillReason = skills.GetStateFromData(data, skillId)
			if not skillState then
				abort(skillReason or "InvalidSkillState")
			end
			local skillSelections, spent, selectionsReason = validatedSelections(data, skillId, tree :: Definitions.SkillTree, (skillState :: SkillState).Level)
			if not skillSelections then
				abort(selectionsReason or "InvalidMasteryState")
			end
			local history, historyReason = respecHistoryFor(data)
			if not history then
				abort(historyReason or "InvalidMasteryRespecState")
			end
			local resolvedHistory = history :: { [string]: boolean }
			local alreadyUsedFree = resolvedHistory[skillId] == true
			local goldCost = if alreadyUsedFree then Definitions.RespecGoldCost(spent :: number) else 0
			if goldCost > 0 then
				local _, goldReason = economy.DebitGoldToData(data, goldCost)
				if goldReason then
					abort(goldReason)
				end
			end
			local resolvedSelections = skillSelections :: { [string]: boolean }
			local clearedNodeIds: { string } = {}
			for nodeId in resolvedSelections do
				table.insert(clearedNodeIds, nodeId)
			end
			table.sort(clearedNodeIds)
			for _, nodeId in clearedNodeIds do
				resolvedSelections[nodeId] = nil
			end
			resolvedHistory[skillId] = true
			result = {
				SkillId = skillId,
				WasFree = not alreadyUsedFree,
				GoldCost = goldCost,
				ClearedNodeIds = clearedNodeIds,
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
