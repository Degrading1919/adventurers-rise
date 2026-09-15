--!strict

-- Persist these IDs. Add branches/nodes for later skills without changing existing values.
local branches: { [string]: string } = {
	MeleeMight = "mastery_branch_melee_might",
	MeleeTempo = "mastery_branch_melee_tempo",
	MeleeCleave = "mastery_branch_melee_cleave",
	DefenseFortitude = "mastery_branch_defense_fortitude",
	DefenseBulwark = "mastery_branch_defense_bulwark",
	DefenseResilience = "mastery_branch_defense_resilience",
	MiningExcavation = "mastery_branch_mining_excavation",
	MiningExtraction = "mastery_branch_mining_extraction",
	MiningProspecting = "mastery_branch_mining_prospecting",
	SmithingSmelter = "mastery_branch_smithing_smelter",
	SmithingForgemaster = "mastery_branch_smithing_forgemaster",
	SmithingMerchantSmith = "mastery_branch_smithing_merchant_smith",
}

local branchesById: { [string]: boolean } = {}
for _, id in branches do
	branchesById[id] = true
end

-- Node N (1-4) of a branch is "<branchId>_N"; stable because branch IDs never change.
local function nodeId(branchId: string, position: number): string
	return branchId .. "_" .. position
end

local nodes: { [string]: { string } } = {}
local nodesById: { [string]: boolean } = {}
for branchKey, branchId in branches do
	local branchNodes = {}
	for position = 1, 4 do
		local id = nodeId(branchId, position)
		branchNodes[position] = id
		nodesById[id] = true
	end
	nodes[branchKey] = table.freeze(branchNodes)
end

return table.freeze({
	Branches = table.freeze(branches),
	BranchesById = table.freeze(branchesById),
	Nodes = table.freeze(nodes),
	NodesById = table.freeze(nodesById),
})
