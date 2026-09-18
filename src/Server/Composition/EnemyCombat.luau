--!strict

-- Trusted server-owned resolution of an enemy's attack against a player. World supplies the physical
-- facts (which alive enemy is within attack range of which player, gated by a per-enemy cooldown); this
-- module owns the gameplay authority: conditional aggression (from the existing Enemy Aggression
-- config vs the player's combat progression), applying the enemy's authoritative Damage stat to
-- runtime health, awarding meaningful Defense XP for the hit taken, and reporting death. Enemy stats
-- and rewards stay owned by the Enemy service; nothing here fabricates damage or invents a target.

local EnemyDefinitions = require(script.Parent.Parent.Enemies.Definitions)
local SkillIds = require(game:GetService("ReplicatedStorage").Shared.SkillIds)

export type PlayerHealth = {
	read IsAlive: (number) -> boolean,
	read ApplyDamage: (number, number) -> (any?, string?),
	read Reset: (number) -> (any?, string?),
}
export type Skills = {
	read GetState: (number, string) -> (any?, string?),
	read AwardXP: (number, string, number) -> (any?, string?),
}
export type Configuration = {
	-- Defense XP granted per meaningful hit taken. Gated by aggression (a much stronger player is not
	-- attacked) and the caller's attack cooldown, so it is meaningful without being freely farmable.
	DefenseXPPerHit: number,
	-- Skill whose level represents combat progression for the aggression comparison.
	ProgressionSkillId: string,
}
export type AttackResult = {
	Damage: number,
	Health: number,
	MaxHealth: number,
	Died: boolean,
	DefenseXP: number,
	DefenseXPAwarded: boolean,
}

local Service = {}

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

local function wholeLevel(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and math.abs(value) < math.huge
end

function Service.New(playerHealth: PlayerHealth, skills: Skills, configuration: Configuration)
	assert(type(playerHealth) == "table" and type(playerHealth.IsAlive) == "function" and type(playerHealth.ApplyDamage) == "function" and type(playerHealth.Reset) == "function", "EnemyCombat requires PlayerHealth")
	assert(type(skills) == "table" and type(skills.GetState) == "function" and type(skills.AwardXP) == "function", "EnemyCombat requires Skills")
	assert(type(configuration) == "table" and finitePositive(configuration.DefenseXPPerHit) and type(configuration.ProgressionSkillId) == "string", "EnemyCombat requires a positive Defense XP amount and a progression skill")

	local service = {}

	-- Conditional aggression: an enemy engages a player only when its level, minus the player's combat
	-- progression level, meets the enemy definition's MinimumEnemyLevelDelta. A player far stronger
	-- than the enemy is ignored -- which is also what keeps Defense XP from being freely farmed.
	local function aggressiveTowards(definition: any, enemyLevel: number, userId: number): (boolean, string?)
		local progression, reason = skills.GetState(userId, configuration.ProgressionSkillId)
		if not progression then
			return false, reason or "ProgressionUnavailable"
		end
		local playerLevel = (progression :: any).Level
		if not wholeLevel(playerLevel) then
			return false, "InvalidProgressionLevel"
		end
		return (enemyLevel - playerLevel) >= definition.Aggression.MinimumEnemyLevelDelta, nil
	end

	-- Resolves one attack attempt from `enemyState` (an Enemy runtime snapshot) against `userId`.
	-- Returns a result only when the hit actually lands, so the caller sets its cooldown only then.
	function service.ResolveAttack(userId: number, enemyState: any): (AttackResult?, string?)
		if type(enemyState) ~= "table" or type(enemyState.DefinitionId) ~= "string" or not wholeLevel(enemyState.Level) or not finitePositive(enemyState.Damage) then
			return nil, "InvalidEnemyState"
		end
		local definition = EnemyDefinitions.ById[enemyState.DefinitionId]
		if not definition then
			return nil, "UnknownEnemy"
		end
		if not playerHealth.IsAlive(userId) then
			return nil, "TargetNotAlive"
		end
		local aggressive, aggressionReason = aggressiveTowards(definition, enemyState.Level, userId)
		if not aggressive then
			return nil, aggressionReason or "NotAggressive"
		end

		local damageResult, damageReason = playerHealth.ApplyDamage(userId, enemyState.Damage)
		if not damageResult then
			return nil, damageReason
		end

		-- Defense XP is a legitimate reward for surviving incoming combat; a failure to persist it
		-- never undoes the damage that already landed, so it is reported, not fatal.
		local _, xpReason = skills.AwardXP(userId, SkillIds.Defense, configuration.DefenseXPPerHit)

		return {
			Damage = enemyState.Damage,
			Health = (damageResult :: any).Health,
			MaxHealth = (damageResult :: any).MaxHealth,
			Died = (damageResult :: any).Died,
			DefenseXP = configuration.DefenseXPPerHit,
			DefenseXPAwarded = xpReason == nil,
		}, nil
	end

	-- Called by World when a player's character (re)spawns: runtime health returns to full. Death
	-- itself is a physical respawn owned by World; this only restores the authoritative health value.
	function service.OnSpawn(userId: number)
		playerHealth.Reset(userId)
	end

	return table.freeze(service)
end

return table.freeze(Service)
