--!strict

local EnemyIds = require(game:GetService("ReplicatedStorage").Shared.EnemyIds)

export type LevelRange = {
	read Minimum: number,
	read Maximum: number,
}
export type Scaling = {
	read BaseHealth: number,
	read HealthPerLevel: number,
	read BaseDamage: number,
	read DamagePerLevel: number,
	read BaseGoldReward: number,
	read GoldRewardPerLevel: number,
}
export type Aggression = {
	read MinimumEnemyLevelDelta: number,
}
-- The minimum marker distinguishing shared bosses from normal enemies. RewardModel documents
-- that boss rewards are intended to be split per eligible participant, never owned by whichever
-- attack happens to land the killing blow; no participation/reward system is implemented yet.
export type BossMetadata = {
	read IsBoss: true,
	read RewardModel: "Participation",
}
export type Definition = {
	read Id: string,
	read DisplayName: string,
	read LevelRange: LevelRange,
	read Scaling: Scaling,
	read Aggression: Aggression,
	read Boss: BossMetadata?,
}

local EnemyDefinitions = {}

local function positiveWhole(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function nonNegativeWhole(value: any): boolean
	return type(value) == "number" and value >= 0 and value % 1 == 0 and value <= 9007199254740991
end

local function whole(value: any): boolean
	return type(value) == "number" and value % 1 == 0 and math.abs(value) <= 9007199254740991
end

local function levelRange(minimum: number, maximum: number): LevelRange
	return table.freeze({ Minimum = minimum, Maximum = maximum })
end

local function scaling(baseHealth: number, healthPerLevel: number, baseDamage: number, damagePerLevel: number, baseGoldReward: number, goldRewardPerLevel: number): Scaling
	return table.freeze({
		BaseHealth = baseHealth,
		HealthPerLevel = healthPerLevel,
		BaseDamage = baseDamage,
		DamagePerLevel = damagePerLevel,
		BaseGoldReward = baseGoldReward,
		GoldRewardPerLevel = goldRewardPerLevel,
	})
end

local function aggression(minimumEnemyLevelDelta: number): Aggression
	return table.freeze({ MinimumEnemyLevelDelta = minimumEnemyLevelDelta })
end

local function bossMetadata(): BossMetadata
	return table.freeze({ IsBoss = true :: true, RewardModel = "Participation" :: "Participation" })
end

local function definition(id: string, displayName: string, levels: LevelRange, values: Scaling, behavior: Aggression, boss: BossMetadata?): Definition
	return table.freeze({
		Id = id,
		DisplayName = displayName,
		LevelRange = levels,
		Scaling = values,
		Aggression = behavior,
		Boss = boss,
	})
end

-- All values are provisional. MinimumEnemyLevelDelta means enemy level minus player progression level.
-- Goblin Chieftain is a fixed-level shared boss: stronger derived health/damage/reward than any
-- normal Goblin roll, and it reuses the same Enemy runtime rather than a separate boss system.
local definitions: { [string]: Definition } = {
	[EnemyIds.Goblin] = definition(EnemyIds.Goblin, "Goblin", levelRange(3, 8), scaling(30, 6, 4, 1, 3, 1), aggression(-2)),
	-- Wolf: a lower-tier, fragile, fast pack predator occupying its own territory (a distinct
	-- population from the goblins). Provisional balance, like every other value here.
	[EnemyIds.Wolf] = definition(EnemyIds.Wolf, "Wolf", levelRange(2, 5), scaling(18, 4, 3, 1, 2, 1), aggression(-4)),
	-- Hobgoblin: a bigger, tougher goblinoid holding the rocky southern hills. Mid-tier: sturdier and
	-- hits harder than a Goblin, richer Gold.
	[EnemyIds.Hobgoblin] = definition(EnemyIds.Hobgoblin, "Hobgoblin", levelRange(6, 12), scaling(60, 8, 7, 2, 6, 2), aggression(-2)),
	-- Bandit: a human rogue haunting the western ruins. Glassier than a Hobgoblin but hits hard and is
	-- aggressive toward players who have not far outgrown it.
	[EnemyIds.Bandit] = definition(EnemyIds.Bandit, "Bandit", levelRange(5, 11), scaling(45, 6, 8, 2, 8, 2), aggression(-3)),
	-- Bandit Warlord: Region I's second shared boss (the ruined-watchtower captain). Fixed level,
	-- stronger than any normal roll, participation reward model like the Goblin Chieftain.
	[EnemyIds.BanditWarlord] = definition(
		EnemyIds.BanditWarlord,
		"Bandit Warlord",
		levelRange(12, 12),
		scaling(520, 0, 26, 0, 70, 0),
		aggression(-8),
		bossMetadata()
	),
	[EnemyIds.GoblinChieftain] = definition(
		EnemyIds.GoblinChieftain,
		"Goblin Chieftain",
		levelRange(10, 10),
		scaling(400, 0, 20, 0, 50, 0),
		aggression(-8),
		bossMetadata()
	),
}

function EnemyDefinitions.Validate(candidateDefinitions: any): (boolean, string?)
	if type(candidateDefinitions) ~= "table" then
		return false, "Enemy definitions must be a table"
	end
	for enemyId, enemy in candidateDefinitions do
		if type(enemyId) ~= "string" or enemyId == "" or EnemyIds.ById[enemyId] ~= true or type(enemy) ~= "table" or enemy.Id ~= enemyId then
			return false, "Enemy IDs must be stable"
		end
		if type(enemy.DisplayName) ~= "string" or enemy.DisplayName == "" then
			return false, "Enemies require a display name"
		end
		local levels = enemy.LevelRange
		if type(levels) ~= "table" or not positiveWhole(levels.Minimum) or not positiveWhole(levels.Maximum) or levels.Minimum > levels.Maximum then
			return false, "Enemy level ranges must be valid"
		end
		local values = enemy.Scaling
		if type(values) ~= "table" or not positiveWhole(values.BaseHealth) or not nonNegativeWhole(values.HealthPerLevel) or not positiveWhole(values.BaseDamage) or not nonNegativeWhole(values.DamagePerLevel) or not nonNegativeWhole(values.BaseGoldReward) or not nonNegativeWhole(values.GoldRewardPerLevel) then
			return false, "Enemy scaling values must be valid"
		end
		local behavior = enemy.Aggression
		if type(behavior) ~= "table" or not whole(behavior.MinimumEnemyLevelDelta) then
			return false, "Enemy aggression values must be valid"
		end
		if enemy.Boss ~= nil then
			local boss = enemy.Boss
			if type(boss) ~= "table" or boss.IsBoss ~= true or boss.RewardModel ~= "Participation" then
				return false, "Boss metadata must be valid"
			end
		end
	end
	return true, nil
end

return table.freeze({
	ById = table.freeze(definitions),
	Validate = EnemyDefinitions.Validate,
})
