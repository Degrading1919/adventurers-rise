--!strict

-- Server-owned runtime player health for the vertical slice. This is ephemeral combat state, never
-- persisted: it resets to full on (re)spawn and is cleared on disconnect, so death never touches
-- PlayerData (Gold, items, XP, progression are untouched). It is the single authority for how much
-- health a player has; the client only displays it and enemy attacks only apply through ApplyDamage.

export type State = {
	Health: number,
	MaxHealth: number,
}
export type DamageResult = {
	Health: number,
	MaxHealth: number,
	AppliedDamage: number,
	Died: boolean,
}
export type Configuration = {
	MaxHealth: number,
}
-- Server-owned Mastery modifier totals for a player's Defense tree (see Mastery.GetModifiers, the
-- single source of truth). PlayerHealth only READS MaxHealthBonus; it never recomputes node logic.
export type ModifierTotals = { [string]: number }
export type DefenseModifierProvider = (number) -> ModifierTotals

local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

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

function Service.New(configuration: Configuration, defenseModifiers: DefenseModifierProvider?, clock: (() -> number)?)
	assert(type(configuration) == "table" and finitePositive(configuration.MaxHealth), "PlayerHealth requires a positive MaxHealth")
	assert(defenseModifiers == nil or type(defenseModifiers) == "function", "PlayerHealth defenseModifiers must be a function when provided")
	assert(clock == nil or type(clock) == "function", "PlayerHealth clock must be a function when provided")
	local baseMaxHealth = configuration.MaxHealth
	-- Monotonic clock for the out-of-combat regen gate (Resilience). Defaults to os.clock so callers/tests
	-- that don't wire a clock still work; Composition injects the shared runtime clock.
	local resolveClock: () -> number = clock or os.clock
	-- Defaults to "no selected Mastery" so callers/tests that do not wire Mastery keep the fixed base
	-- max health exactly. Composition injects the real server-authoritative Defense provider.
	local resolveDefenseModifiers: DefenseModifierProvider = defenseModifiers or function()
		return {}
	end

	-- Per-player maximum health, derived live from the player's current Defense Mastery so a selection
	-- or respec takes effect immediately. MaxHealthBonus is additive (+fraction) and never reduces the
	-- base below 1. Rounded to a whole number for clean presentation and deterministic clamping.
	local function resolveMaxHealth(userId: number): number
		local bonus = math.max(0, modifierTotal(resolveDefenseModifiers(userId), "MaxHealthBonus"))
		local resolved = math.floor(baseMaxHealth * (1 + bonus) + 0.5)
		if resolved < 1 then
			resolved = 1
		end
		return resolved
	end

	-- userId -> current health. A missing entry means "not yet damaged this life" and reads as full,
	-- so a freshly spawned player is always at maximum without needing an explicit initialisation call.
	local health: { [number]: number } = {}
	-- userId -> clock time of the most recent damage, for the Resilience out-of-combat regen gate. A
	-- missing entry means "not damaged recently", which regen treats as out of combat.
	local lastDamageAt: { [number]: number } = {}
	-- Regen only resumes this many seconds after the last hit, so Resilience is genuine out-of-combat
	-- recovery (docs/MASTERY_TREES.md), never in-combat sustain.
	local OUT_OF_COMBAT_SECONDS = 5
	local service = {}

	-- Reads current health, clamped down to the player's current maximum so a Mastery respec that lowers
	-- MaxHealthBonus can never leave a player reading above their (now smaller) maximum. The clamp is
	-- persisted to the authoritative runtime value (not just this returned snapshot), so health hidden
	-- above a reduced maximum is truly discarded and cannot reappear if Fortitude is re-selected later.
	local function currentHealth(userId: number): number
		local max = resolveMaxHealth(userId)
		local value = health[userId]
		if value == nil then
			return max
		end
		if value > max then
			health[userId] = max
			return max
		end
		return value
	end

	function service.Reset(userId: number): (State?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local max = resolveMaxHealth(userId)
		health[userId] = max
		return { Health = max, MaxHealth = max }, nil
	end

	function service.Clear(userId: number)
		health[userId] = nil
		lastDamageAt[userId] = nil
	end

	function service.GetState(userId: number): (State?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		return { Health = currentHealth(userId), MaxHealth = resolveMaxHealth(userId) }, nil
	end

	function service.IsAlive(userId: number): boolean
		if not validUserId(userId) then
			return false
		end
		return currentHealth(userId) > 0
	end

	-- Applies incoming damage to runtime health. Fails closed on a dead or invalid target rather than
	-- fabricating a hit. Reports whether this hit was lethal so the caller can trigger the death flow.
	function service.ApplyDamage(userId: number, amount: number): (DamageResult?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not finitePositive(amount) then
			return nil, "InvalidDamage"
		end
		local current = currentHealth(userId)
		if current <= 0 then
			return nil, "AlreadyDead"
		end
		local applied = math.min(amount, current)
		current -= applied
		if current < 0 then
			current = 0
		end
		health[userId] = current
		-- Stamp the hit so Resilience regen stays suppressed until the player has been out of combat.
		lastDamageAt[userId] = resolveClock()
		return { Health = current, MaxHealth = resolveMaxHealth(userId), AppliedDamage = applied, Died = current <= 0 }, nil
	end

	-- Defense "Resilience" mastery (RecoveryBonus) regenerates a below-max, living player's health OUT OF
	-- COMBAT; World ticks this on its shared heartbeat. It is genuine out-of-combat recovery (docs
	-- MASTERY_TREES) -- suppressed for OUT_OF_COMBAT_SECONDS after any hit, never in-combat sustain. No
	-- RecoveryBonus == no regen, so baseline players (and all existing tests) are unchanged. The heal rate
	-- scales with the player's own maximum health, so it stays proportional as they toughen.
	local REGEN_MAXHEALTH_FRACTION_PER_SECOND = 0.5
	function service.Regenerate(userId: number, deltaSeconds: number): ()
		if not validUserId(userId) or not finitePositive(deltaSeconds) then
			return
		end
		local recovery = math.max(0, modifierTotal(resolveDefenseModifiers(userId), "RecoveryBonus"))
		if recovery <= 0 then
			return
		end
		-- Out-of-combat gate: no regen until enough time has passed since the last damage taken.
		local since = lastDamageAt[userId]
		if since ~= nil and (resolveClock() - since) < OUT_OF_COMBAT_SECONDS then
			return
		end
		local max = resolveMaxHealth(userId)
		local current = currentHealth(userId)
		-- Dead players don't self-heal; full players need nothing.
		if current <= 0 or current >= max then
			return
		end
		local healed = current + max * recovery * REGEN_MAXHEALTH_FRACTION_PER_SECOND * deltaSeconds
		if healed > max then
			healed = max
		end
		health[userId] = healed
	end

	return table.freeze(service)
end

return table.freeze(Service)
