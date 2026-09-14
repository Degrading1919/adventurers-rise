--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local EnemyIds = require(Shared.EnemyIds)
local ItemDefinitions = require(Shared.ItemDefinitions)
local ProgressionFlagIds = require(Shared.ProgressionFlagIds)

-- The centralized, replaceable participation rule: eligible once accumulated applied damage
-- reaches this fraction of the boss's MaxHealth. Never the killing blow.
export type EligibilityRule = {
	read MinimumContributionFraction: number,
}
export type CommonReward = {
	read GoldAmount: number,
}
export type RareReward = {
	read ItemDefinitionId: string,
	read Amount: number,
	-- Independent per-participant RNG success probability in [0, 1].
	read Chance: number,
}
export type LootTable = {
	read Common: CommonReward,
	read Rare: RareReward,
}
export type Definition = {
	read EnemyDefinitionId: string,
	read Eligibility: EligibilityRule,
	read Loot: LootTable,
	read MilestoneId: string,
}

local BossDefinitions = {}

local function fraction(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value <= 1
end

local function positiveWhole(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function eligibility(minimumContributionFraction: number): EligibilityRule
	return table.freeze({ MinimumContributionFraction = minimumContributionFraction })
end

local function common(goldAmount: number): CommonReward
	return table.freeze({ GoldAmount = goldAmount })
end

local function rare(itemDefinitionId: string, amount: number, chance: number): RareReward
	return table.freeze({ ItemDefinitionId = itemDefinitionId, Amount = amount, Chance = chance })
end

local function loot(commonReward: CommonReward, rareReward: RareReward): LootTable
	return table.freeze({ Common = commonReward, Rare = rareReward })
end

local function definition(enemyDefinitionId: string, eligibilityRule: EligibilityRule, lootTable: LootTable, milestoneId: string): Definition
	return table.freeze({
		EnemyDefinitionId = enemyDefinitionId,
		Eligibility = eligibilityRule,
		Loot = lootTable,
		MilestoneId = milestoneId,
	})
end

-- All values are provisional. Eligibility is 5% of the Chieftain's MaxHealth in applied damage --
-- the smallest reasonable participation floor, expressed as a fraction so it scales automatically
-- if boss health is retuned. Every eligible participant gets the common Gold reward and an
-- independent roll for the rare material; killing blow plays no special role in either.
local definitions: { [string]: Definition } = {
	[EnemyIds.GoblinChieftain] = definition(
		EnemyIds.GoblinChieftain,
		eligibility(0.05),
		loot(common(25), rare("item_chieftain_fang", 1, 0.15)),
		ProgressionFlagIds.GoblinChieftainDefeated
	),
}

function BossDefinitions.Validate(candidateDefinitions: any): (boolean, string?)
	if type(candidateDefinitions) ~= "table" then
		return false, "Boss definitions must be a table"
	end
	for enemyDefinitionId, candidate in candidateDefinitions do
		if type(enemyDefinitionId) ~= "string" or enemyDefinitionId == "" or type(candidate) ~= "table" or candidate.EnemyDefinitionId ~= enemyDefinitionId then
			return false, "Boss definitions must be keyed by a stable enemy definition ID"
		end
		local eligibilityRule = candidate.Eligibility
		if type(eligibilityRule) ~= "table" or not fraction(eligibilityRule.MinimumContributionFraction) then
			return false, "Boss eligibility rules must be a valid fraction"
		end
		local lootTable = candidate.Loot
		if type(lootTable) ~= "table" then
			return false, "Boss definitions require a loot table"
		end
		local commonReward = lootTable.Common
		if type(commonReward) ~= "table" or not positiveWhole(commonReward.GoldAmount) then
			return false, "Common boss rewards require a positive whole Gold amount"
		end
		local rareReward = lootTable.Rare
		if type(rareReward) ~= "table" or not fraction(rareReward.Chance) then
			return false, "Rare boss rewards require a valid RNG chance"
		end
		local rareItem = ItemDefinitions.ById[rareReward.ItemDefinitionId]
		if not rareItem or rareItem.Kind ~= "Stackable" or not positiveWhole(rareReward.Amount) then
			return false, "Rare boss rewards must reference a valid stackable item and amount"
		end
		if type(candidate.MilestoneId) ~= "string" or ProgressionFlagIds.ById[candidate.MilestoneId] ~= true then
			return false, "Boss definitions require a known progression milestone ID"
		end
	end
	return true, nil
end

return table.freeze({
	ById = table.freeze(definitions),
	Validate = BossDefinitions.Validate,
})
