--!strict

-- Trusted server-owned resolution of an enemy's attack against a player, plus the small combat-
-- engagement (provocation) state the aggression rule needs. World supplies the physical facts (which
-- alive enemy is within attack range of which players, gated by a per-enemy cooldown); this module
-- owns the gameplay authority:
--   * Conditional aggression -- an enemy automatically engages a player who is appropriate or
--     underpowered for it (from the existing Enemy Aggression config vs the player's combat
--     progression), and ignores a player who has substantially outgrown it.
--   * Retaliation -- an enemy also engages any player who has landed a real, server-validated attack
--     on it, even an overpowered one. Provocation is recorded only from a genuine successful attack
--     (RecordProvocation is called by the trusted request path), never from a client assertion, and is
--     cleared when the enemy's RuntimeId is removed/replaced or the player leaves.
-- Applying the enemy's authoritative Damage to runtime health and awarding difficulty-scaled Defense
-- XP also live here. Enemy stats and rewards stay owned by the Enemy service.

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
-- Difficulty-scaled Defense combat XP (see docs/DESIGN_SOURCE_OF_TRUTH.md): XP scales in a simple
-- bounded way with enemy level relative to the player, NOT with damage taken. Trivial enemies award
-- little/none; appropriate/dangerous ones award more, within a cap. Provisional, centralized values.
export type DefenseXP = {
	Base: number,
	PerLevel: number,
	Minimum: number,
	Maximum: number,
}
export type Configuration = {
	DefenseXP: DefenseXP,
	-- Skill whose level represents combat progression for the aggression/difficulty comparison.
	ProgressionSkillId: string,
}
-- Server-owned Mastery modifier totals for the target's Defense tree (see Mastery.GetModifiers, the
-- single source of truth). EnemyCombat only READS IncomingDamageReduction; it never recomputes nodes.
export type ModifierTotals = { [string]: number }
export type DefenseModifierProvider = (number) -> ModifierTotals
export type AttackResult = {
	Damage: number,
	Health: number,
	MaxHealth: number,
	Died: boolean,
	Engagement: string,
	DefenseXP: number,
	DefenseXPAwarded: boolean,
}

-- Keeps a fully-stacked incoming-damage reduction below 1 so a landed enemy hit always applies strictly
-- positive damage (PlayerHealth.ApplyDamage requires it). Current slice data caps a completed Bulwark
-- branch at 0.10, well inside this bound.
local MAX_INCOMING_DAMAGE_REDUCTION = 0.9

local Service = {}

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

-- Reads one modifier total defensively; a missing/non-finite entry contributes nothing (never a
-- reduction that could be spoofed into free damage immunity).
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

local function finiteNumber(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function wholeLevel(value: any): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and math.abs(value) < math.huge
end

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function validRuntimeId(value: any): boolean
	return type(value) == "string" and value ~= ""
end

function Service.New(playerHealth: PlayerHealth, skills: Skills, configuration: Configuration, defenseModifiers: DefenseModifierProvider?)
	assert(type(playerHealth) == "table" and type(playerHealth.IsAlive) == "function" and type(playerHealth.ApplyDamage) == "function" and type(playerHealth.Reset) == "function", "EnemyCombat requires PlayerHealth")
	assert(type(skills) == "table" and type(skills.GetState) == "function" and type(skills.AwardXP) == "function", "EnemyCombat requires Skills")
	assert(type(configuration) == "table" and type(configuration.ProgressionSkillId) == "string", "EnemyCombat requires a progression skill")
	assert(defenseModifiers == nil or type(defenseModifiers) == "function", "EnemyCombat defenseModifiers must be a function when provided")
	-- Defaults to "no selected Mastery" so callers/tests that do not wire Mastery keep exact prior
	-- damage. Composition injects the real server-authoritative Defense provider.
	local resolveDefenseModifiers: DefenseModifierProvider = defenseModifiers or function()
		return {}
	end
	local defenseXP = configuration.DefenseXP
	assert(
		type(defenseXP) == "table"
			and finiteNumber(defenseXP.Base)
			and finiteNumber(defenseXP.PerLevel)
			and finiteNumber(defenseXP.Minimum)
			and finiteNumber(defenseXP.Maximum)
			and defenseXP.Minimum >= 0
			and defenseXP.Maximum >= defenseXP.Minimum,
		"EnemyCombat requires a valid bounded Defense XP scale"
	)

	-- runtimeId -> set of userIds who have provoked that specific enemy instance by attacking it.
	-- Keyed by RuntimeId so it is naturally scoped to one enemy life: a respawn (new RuntimeId) starts
	-- with no provocations, and ClearEnemy drops a removed/replaced instance's set entirely.
	local provocations: { [string]: { [number]: boolean } } = {}
	local service = {}

	-- Trusted: recorded only from a genuine, already server-validated successful player attack. The
	-- client never reaches this with an arbitrary "provoked" claim -- the request path calls it only
	-- after Combat has actually applied damage to this RuntimeId.
	function service.RecordProvocation(runtimeId: string, userId: number): boolean
		if not validRuntimeId(runtimeId) or not validUserId(userId) then
			return false
		end
		local set = provocations[runtimeId]
		if not set then
			set = {}
			provocations[runtimeId] = set
		end
		set[userId] = true
		return true
	end

	local function isProvoked(runtimeId: string, userId: number): boolean
		local set = provocations[runtimeId]
		return set ~= nil and set[userId] == true
	end

	-- Clears one enemy instance's provocations. Called when its RuntimeId is removed/replaced (death or
	-- respawn), so provocation never survives into a new enemy life.
	function service.ClearEnemy(runtimeId: string)
		provocations[runtimeId] = nil
	end

	-- Clears one player's provocations across all enemies. Called when the player's runtime state is no
	-- longer valid (disconnect), so a stale userId cannot linger in a living enemy's set.
	function service.ClearPlayer(userId: number)
		for _, set in provocations do
			set[userId] = nil
		end
	end

	local function defenseXPFor(delta: number): number
		local raw = defenseXP.Base + defenseXP.PerLevel * delta
		local rounded = math.floor(raw + 0.5)
		return math.clamp(rounded, defenseXP.Minimum, defenseXP.Maximum)
	end

	-- Read-only predicate: would this enemy engage this player right now? True when the player provoked
	-- it, or when conditional aggression auto-engages them (appropriate/underpowered for the enemy). Pure
	-- -- it applies no damage and awards no XP -- so the movement layer can use the SAME rule to decide
	-- whom to chase, keeping "who the enemy pursues" and "who the enemy hits" consistent. A player the
	-- enemy has substantially outgrown (and never provoked) is not engaged, so it is left alone.
	function service.Engages(userId: number, enemyState: any): boolean
		if type(enemyState) ~= "table" or not validRuntimeId(enemyState.RuntimeId) or type(enemyState.DefinitionId) ~= "string" or not wholeLevel(enemyState.Level) then
			return false
		end
		local definition = EnemyDefinitions.ById[enemyState.DefinitionId]
		if not definition then
			return false
		end
		if not validUserId(userId) then
			return false
		end
		if isProvoked(enemyState.RuntimeId, userId) then
			return true
		end
		if not playerHealth.IsAlive(userId) then
			return false
		end
		local progression = skills.GetState(userId, configuration.ProgressionSkillId)
		if not progression or not wholeLevel((progression :: any).Level) then
			return false
		end
		return (enemyState.Level - (progression :: any).Level) >= definition.Aggression.MinimumEnemyLevelDelta
	end

	-- Resolves one attack attempt from `enemyState` (an Enemy runtime snapshot) against `userId`.
	-- Returns a result only when the hit actually lands, so the caller sets its cooldown / picks its
	-- target only then. A player the enemy is neither aggressive toward nor provoked by is skipped
	-- with "NotEngaged" and takes no damage, letting the caller try the next in-range player.
	function service.ResolveAttack(userId: number, enemyState: any): (AttackResult?, string?)
		if type(enemyState) ~= "table" or not validRuntimeId(enemyState.RuntimeId) or type(enemyState.DefinitionId) ~= "string" or not wholeLevel(enemyState.Level) or not finitePositive(enemyState.Damage) then
			return nil, "InvalidEnemyState"
		end
		local definition = EnemyDefinitions.ById[enemyState.DefinitionId]
		if not definition then
			return nil, "UnknownEnemy"
		end
		if not playerHealth.IsAlive(userId) then
			return nil, "TargetNotAlive"
		end
		local progression, reason = skills.GetState(userId, configuration.ProgressionSkillId)
		if not progression then
			return nil, reason or "ProgressionUnavailable"
		end
		local playerLevel = (progression :: any).Level
		if not wholeLevel(playerLevel) then
			return nil, "InvalidProgressionLevel"
		end

		-- Conditional aggression: appropriate/underpowered players are auto-engaged; a player who has
		-- substantially outgrown the enemy is not -- unless they provoked it by attacking first.
		local delta = enemyState.Level - playerLevel
		local autoAggressive = delta >= definition.Aggression.MinimumEnemyLevelDelta
		local provoked = isProvoked(enemyState.RuntimeId, userId)
		if not (autoAggressive or provoked) then
			return nil, "NotEngaged"
		end

		-- Defense Mastery reduces the enemy's authoritative damage before it reaches runtime health. The
		-- reduction is clamped below 1, so a landed hit always applies strictly positive (never negative
		-- or zero) damage; a missing/spoofed modifier contributes no reduction.
		local reduction = math.clamp(math.max(0, modifierTotal(resolveDefenseModifiers(userId), "IncomingDamageReduction")), 0, MAX_INCOMING_DAMAGE_REDUCTION)
		local incomingDamage = enemyState.Damage * (1 - reduction)
		local damageResult, damageReason = playerHealth.ApplyDamage(userId, incomingDamage)
		if not damageResult then
			return nil, damageReason
		end

		-- Defense XP scales with difficulty (enemy level vs player), not damage taken. A trivial
		-- retaliation fight awards little or nothing; an appropriate/dangerous fight awards more.
		local xp = defenseXPFor(delta)
		local awarded = false
		if xp > 0 then
			local _, xpReason = skills.AwardXP(userId, SkillIds.Defense, xp)
			awarded = xpReason == nil
		end

		return {
			Damage = incomingDamage,
			Health = (damageResult :: any).Health,
			MaxHealth = (damageResult :: any).MaxHealth,
			Died = (damageResult :: any).Died,
			Engagement = if provoked then "Provoked" else "Aggressive",
			DefenseXP = xp,
			DefenseXPAwarded = awarded,
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
