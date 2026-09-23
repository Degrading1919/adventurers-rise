--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local MasteryIds = require(Shared.MasteryIds)
local SkillIds = require(Shared.SkillIds)

export type Effect = {
	read Type: string,
	-- An additive fractional bonus/reduction (e.g. 0.02 == +2%). Consuming systems sum matching
	-- Effect.Type values across selected nodes and apply the total themselves.
	read Value: number,
}
export type Node = {
	read Id: string,
	read SkillId: string,
	read BranchId: string,
	read Position: number, -- 1-4, sequential within the branch
	read RequiredLevel: number,
	read PointCost: number,
	read DisplayName: string,
	read Description: string,
	read Effect: Effect,
}
export type Branch = {
	read Id: string,
	read SkillId: string,
	read DisplayName: string,
	read Nodes: { Node }, -- length 4, index N == Position N
}
export type SkillTree = {
	read SkillId: string,
	read Branches: { Branch }, -- length 3
}

local MasteryDefinitions = {}

-- Shared framework constants (docs/MASTERY_TREES.md). Do not change without a design update.
local LEVEL_GATES = { 5, 15, 30, 50 }
local NODE_INCREMENTS = { 0.02, 0.02, 0.03, 0.03 } -- sums to +/-10% for a fully completed branch
local ROMAN_NUMERALS = { "I", "II", "III", "IV" }

-- The small explicit set of passive modifier keys. Consuming systems (Combat, Gathering,
-- Crafting, Defense/health, Economy) key off these directly instead of a generic effect language.
local ALLOWED_EFFECT_TYPES: { [string]: boolean } = {
	MeleeDamageBonus = true,
	MeleeAttackIntervalReduction = true,
	MeleeCleaveDamageBonus = true,
	MaxHealthBonus = true,
	IncomingDamageReduction = true,
	RecoveryBonus = true,
	GatheringSpeedBonus = true,
	PrimaryYieldBonus = true,
	RareResourceBonus = true,
	ProcessingSpeedBonus = true,
	MaterialEfficiencyBonus = true,
	CraftedSaleValueBonus = true,
}

local RESPEC_BASE_GOLD_COST = 20
local RESPEC_GOLD_COST_PER_SPENT_POINT = 10

local function percent(value: number): string
	return string.format("%d%%", math.floor(value * 100 + 0.5))
end

local function branch(
	skillId: string,
	branchId: string,
	displayName: string,
	namePrefix: string,
	effectType: string,
	describe: (string) -> string,
	nodeIds: { string }
): Branch
	local nodes: { Node } = {}
	for position = 1, 4 do
		local value = NODE_INCREMENTS[position]
		nodes[position] = table.freeze({
			Id = nodeIds[position],
			SkillId = skillId,
			BranchId = branchId,
			Position = position,
			RequiredLevel = LEVEL_GATES[position],
			PointCost = 1,
			DisplayName = namePrefix .. " " .. ROMAN_NUMERALS[position],
			Description = describe(percent(value)),
			Effect = table.freeze({ Type = effectType, Value = value }),
		})
	end
	return table.freeze({ Id = branchId, SkillId = skillId, DisplayName = displayName, Nodes = table.freeze(nodes) })
end

local function skillTree(skillId: string, branches: { Branch }): SkillTree
	return table.freeze({ SkillId = skillId, Branches = table.freeze(branches) })
end

-- All numerical values are provisional. Each fully completed branch (4 nodes) totals +/-10%,
-- a controlled specialization rather than anything close to a 2x performance swing. At most two
-- branches can be fully completed with the 8 points available by level 60.
local meleeMight = branch(
	SkillIds.Melee,
	MasteryIds.Branches.MeleeMight,
	"Might",
	"Heavy Strikes",
	"MeleeDamageBonus",
	function(p) return "+" .. p .. " melee damage." end,
	MasteryIds.Nodes.MeleeMight
)
local meleeTempo = branch(
	SkillIds.Melee,
	MasteryIds.Branches.MeleeTempo,
	"Tempo",
	"Swift Strikes",
	"MeleeAttackIntervalReduction",
	function(p) return "-" .. p .. " melee attack interval (faster attacks)." end,
	MasteryIds.Nodes.MeleeTempo
)
local meleeCleave = branch(
	SkillIds.Melee,
	MasteryIds.Branches.MeleeCleave,
	"Cleave",
	"Sweeping Strikes",
	"MeleeCleaveDamageBonus",
	function(p) return p .. " of your hit splashed as damage to nearby enemies." end,
	MasteryIds.Nodes.MeleeCleave
)

local defenseFortitude = branch(
	SkillIds.Defense,
	MasteryIds.Branches.DefenseFortitude,
	"Fortitude",
	"Hardened Body",
	"MaxHealthBonus",
	function(p) return "+" .. p .. " maximum health." end,
	MasteryIds.Nodes.DefenseFortitude
)
local defenseBulwark = branch(
	SkillIds.Defense,
	MasteryIds.Branches.DefenseBulwark,
	"Bulwark",
	"Iron Guard",
	"IncomingDamageReduction",
	function(p) return "-" .. p .. " incoming damage." end,
	MasteryIds.Nodes.DefenseBulwark
)
local defenseResilience = branch(
	SkillIds.Defense,
	MasteryIds.Branches.DefenseResilience,
	"Resilience",
	"Steady Recovery",
	"RecoveryBonus",
	function(p) return "+" .. p .. " health regeneration over time (scaled by your maximum health)." end,
	MasteryIds.Nodes.DefenseResilience
)

local miningExcavation = branch(
	SkillIds.Mining,
	MasteryIds.Branches.MiningExcavation,
	"Excavation",
	"Quick Hands",
	"GatheringSpeedBonus",
	function(p) return "+" .. p .. " gathering speed." end,
	MasteryIds.Nodes.MiningExcavation
)
local miningExtraction = branch(
	SkillIds.Mining,
	MasteryIds.Branches.MiningExtraction,
	"Extraction",
	"Rich Vein",
	"PrimaryYieldBonus",
	function(p) return "+" .. p .. " primary ore yield." end,
	MasteryIds.Nodes.MiningExtraction
)
local miningProspecting = branch(
	SkillIds.Mining,
	MasteryIds.Branches.MiningProspecting,
	"Prospecting",
	"Keen Eye",
	"RareResourceBonus",
	function(p) return "+" .. p .. " rare-resource find chance (reserved for future rare Mining resources)." end,
	MasteryIds.Nodes.MiningProspecting
)

local smithingSmelter = branch(
	SkillIds.Smithing,
	MasteryIds.Branches.SmithingSmelter,
	"Smelter",
	"Efficient Smelting",
	"ProcessingSpeedBonus",
	function(p) return "+" .. p .. " ore-to-bar processing speed." end,
	MasteryIds.Nodes.SmithingSmelter
)
local smithingForgemaster = branch(
	SkillIds.Smithing,
	MasteryIds.Branches.SmithingForgemaster,
	"Forgemaster",
	"Master Forging",
	"MaterialEfficiencyBonus",
	function(p) return "+" .. p .. " material efficiency when forging equipment." end,
	MasteryIds.Nodes.SmithingForgemaster
)
local smithingMerchantSmith = branch(
	SkillIds.Smithing,
	MasteryIds.Branches.SmithingMerchantSmith,
	"Merchant Smith",
	"Trade Savvy",
	"CraftedSaleValueBonus",
	function(p) return "+" .. p .. " Gold when selling goods to the shop." end,
	MasteryIds.Nodes.SmithingMerchantSmith
)

-- Only the four functional vertical-slice skills are populated. Ranged, Magic, Woodcutting,
-- Fletching, and Arcana are not in SkillIds yet; adding their trees later is a data addition.
local trees: { [string]: SkillTree } = {
	[SkillIds.Melee] = skillTree(SkillIds.Melee, { meleeMight, meleeTempo, meleeCleave }),
	[SkillIds.Defense] = skillTree(SkillIds.Defense, { defenseFortitude, defenseBulwark, defenseResilience }),
	[SkillIds.Mining] = skillTree(SkillIds.Mining, { miningExcavation, miningExtraction, miningProspecting }),
	[SkillIds.Smithing] = skillTree(SkillIds.Smithing, { smithingSmelter, smithingForgemaster, smithingMerchantSmith }),
}

local nodesById: { [string]: Node } = {}
local branchesById: { [string]: Branch } = {}
for _, tree in trees do
	for _, branchDef in tree.Branches do
		branchesById[branchDef.Id] = branchDef
		for _, node in branchDef.Nodes do
			nodesById[node.Id] = node
		end
	end
end

local knownSkillIds: { [string]: boolean } = {}
for _, id in SkillIds do
	knownSkillIds[id] = true
end

local function validFraction(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value <= 1 and math.abs(value) < math.huge
end

function MasteryDefinitions.Validate(candidateTrees: any): (boolean, string?)
	if type(candidateTrees) ~= "table" then
		return false, "Mastery trees must be a table"
	end
	local seenNodeIds: { [string]: boolean } = {}
	for skillId, tree in candidateTrees do
		if type(skillId) ~= "string" or knownSkillIds[skillId] ~= true or type(tree) ~= "table" or tree.SkillId ~= skillId then
			return false, "Mastery trees must be keyed by a known skill ID"
		end
		if type(tree.Branches) ~= "table" or #tree.Branches ~= 3 then
			return false, "Each populated skill needs exactly 3 branches"
		end
		for _, branchDef in tree.Branches do
			if type(branchDef) ~= "table" or type(branchDef.Id) ~= "string" or MasteryIds.BranchesById[branchDef.Id] ~= true then
				return false, "Branches must use stable, known IDs"
			end
			if branchDef.SkillId ~= skillId then
				return false, "A branch must belong to exactly one skill"
			end
			if type(branchDef.DisplayName) ~= "string" or branchDef.DisplayName == "" then
				return false, "Branches require a display name"
			end
			if type(branchDef.Nodes) ~= "table" or #branchDef.Nodes ~= 4 then
				return false, "Each branch needs exactly 4 nodes"
			end
			for position, node in branchDef.Nodes do
				if type(node) ~= "table" or type(node.Id) ~= "string" or MasteryIds.NodesById[node.Id] ~= true then
					return false, "Nodes must use stable, known IDs"
				end
				if seenNodeIds[node.Id] then
					return false, "Node IDs must be globally unique"
				end
				seenNodeIds[node.Id] = true
				if node.SkillId ~= skillId or node.BranchId ~= branchDef.Id then
					return false, "A node must belong to exactly one skill and branch"
				end
				if node.Position ~= position then
					return false, "Node positions must be exactly 1-4, in order, within their branch"
				end
				if node.RequiredLevel ~= LEVEL_GATES[position] then
					return false, "Node required levels must match the agreed branch-depth gates"
				end
				if node.PointCost ~= 1 then
					return false, "Node point cost must currently be 1"
				end
				if type(node.DisplayName) ~= "string" or node.DisplayName == "" then
					return false, "Nodes require a display name"
				end
				if type(node.Description) ~= "string" or node.Description == "" then
					return false, "Nodes require a description"
				end
				local effect = node.Effect
				if type(effect) ~= "table" or type(effect.Type) ~= "string" or ALLOWED_EFFECT_TYPES[effect.Type] ~= true then
					return false, "Node effect type must be a known modifier key"
				end
				if not validFraction(effect.Value) then
					return false, "Node effect value must be a valid positive fraction"
				end
			end
		end
	end
	return true, nil
end

function MasteryDefinitions.RespecGoldCost(spentPoints: number): number
	return RESPEC_BASE_GOLD_COST + RESPEC_GOLD_COST_PER_SPENT_POINT * spentPoints
end

return table.freeze({
	ById = table.freeze(trees),
	NodesById = table.freeze(nodesById),
	BranchesById = table.freeze(branchesById),
	Validate = MasteryDefinitions.Validate,
	RespecGoldCost = MasteryDefinitions.RespecGoldCost,
})
