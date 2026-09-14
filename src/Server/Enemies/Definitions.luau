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
export type Definition = {
	read Id: string,
	read DisplayName: string,
	read LevelRange: LevelRange,
	read Scaling: Scaling,
	read Aggression: Aggression,
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

local function definition(id: string, displayName: string, levels: LevelRange, values: Scaling, behavior: Aggression): Definition
	return table.freeze({
		Id = id,
		DisplayName = displayName,
		LevelRange = levels,
		Scaling = values,
		Aggression = behavior,
	})
end

-- All values are provisional. MinimumEnemyLevelDelta means enemy level minus player progression level.
local definitions: { [string]: Definition } = {
	[EnemyIds.Goblin] = definition(EnemyIds.Goblin, "Goblin", levelRange(3, 8), scaling(30, 6, 4, 1, 3, 1), aggression(-2)),
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
	end
	return true, nil
end

return table.freeze({
	ById = table.freeze(definitions),
	Validate = EnemyDefinitions.Validate,
})
