--!strict

-- Pure, deterministic enemy movement/behaviour state machine for the living-world layer. It owns NO
-- Roblox instances and NO gameplay authority: given an enemy's home territory, its current position,
-- the nearest player, and elapsed time, it returns the next movement intent (a target point + speed +
-- facing) plus the enemy's behavioural state. World.Service executes the intent by moving the physical
-- model; combat, health, damage, and reward stay entirely in the repository services (Enemies /
-- EnemyCombat). Extracted like SelectAttackTarget / SanitizeEnemyHealth so the whole notice → approach
-- → chase → disengage → return behaviour is unit-testable without a live Studio session.
--
-- All distances are FLAT (X/Z only); enemies live on a flat world plane and never decide their own Y,
-- so the executor keeps them grounded. Randomness (roam-point choice) is injected, never global, so the
-- machine stays deterministic under test.

export type Config = {
	-- A player at least this close (studs, flat) makes an idle/roaming enemy give chase.
	read AggroRadius: number,
	-- While chasing, a player farther than this (flat) is lost and the enemy gives up.
	read DeaggroRadius: number,
	-- The farthest (flat) an enemy will stray from its territory home before abandoning the chase and
	-- returning. This is what stops enemies from being kited across the whole world.
	read LeashRadius: number,
	-- The radius (flat) around home the enemy wanders within while roaming (<= territory radius).
	read RoamRadius: number,
	-- Movement speeds (studs/sec) while roaming/returning vs chasing (chasing is faster).
	read RoamSpeed: number,
	read ChaseSpeed: number,
	-- Within this flat distance of a move target counts as "arrived".
	read ArriveRadius: number,
	-- Idle pause range (seconds) between roam points, so enemies don't march nonstop.
	read RoamPauseMin: number,
	read RoamPauseMax: number,
	-- Stop closing on a chased player once within this flat distance (matches enemy melee reach), so the
	-- enemy holds at striking range and lets the authoritative attack pass do the damage.
	read AttackRange: number,
}

export type State = "Idle" | "Roam" | "Chase" | "Return"

export type Memory = {
	State: State,
	-- Chosen roam point {x, y, z} (nil until one is picked); y is the enemy's grounded home height.
	RoamTarget: { number }?,
	-- Clock time to remain idle until (only meaningful in the Idle state).
	PauseUntil: number,
}

export type Context = {
	-- Territory home (the leash anchor and roam centre); its Y is the enemy's grounded height.
	read Home: Vector3,
	read Current: Vector3,
	read Now: number,
	-- Nearest live player and its flat distance to this enemy, or nil when no player is around.
	read NearestPlayer: Vector3?,
	read NearestPlayerDistance: number?,
	read Config: Config,
	-- Injected RNG in [0, 1); deterministic in tests. Used only to pick roam points and pause lengths.
	read Random: () -> number,
}

export type Intent = {
	State: State,
	-- World position to move toward this tick, or nil to hold position (idle / already in strike range).
	MoveTo: Vector3?,
	Speed: number,
	-- World position to face, or nil to keep the current facing.
	Face: Vector3?,
}

local EnemyAI = {}

-- Provisional, replaceable balance defaults for a lightweight RPG. A territory may override any of
-- these; the executor supplies the resolved Config. Kept here (not in the scene) so the movement feel
-- is repository-owned balance data, versioned with the code that reads it.
EnemyAI.Defaults = table.freeze({
	AggroRadius = 26,
	DeaggroRadius = 44,
	LeashRadius = 70,
	RoamRadius = 26,
	RoamSpeed = 7,
	ChaseSpeed = 12,
	ArriveRadius = 3,
	RoamPauseMin = 2,
	RoamPauseMax = 5,
	AttackRange = 7,
}) :: Config

local function flatDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- A uniform random point inside a disc of the given radius around a centre, on the centre's Y plane.
local function randomPointInDisc(centre: Vector3, radius: number, random: () -> number): Vector3
	local angle = random() * 2 * math.pi
	-- sqrt keeps the distribution uniform over area rather than clustering at the centre.
	local r = math.sqrt(random()) * radius
	return Vector3.new(centre.X + math.cos(angle) * r, centre.Y, centre.Z + math.sin(angle) * r)
end

local function clonePoint(v: Vector3): { number }
	return { v.X, v.Y, v.Z }
end

-- Advances one enemy one tick. Returns the NEW memory (never mutates the input) and the movement intent
-- the executor should apply. Deterministic given the same memory, context, and Random sequence.
function EnemyAI.Step(memory: Memory, ctx: Context): (Memory, Intent)
	local config = ctx.Config
	local home = ctx.Home
	local current = ctx.Current
	local distFromHome = flatDistance(current, home)

	local player = ctx.NearestPlayer
	local playerDist = ctx.NearestPlayerDistance

	local state = memory.State
	local roamTarget = memory.RoamTarget
	local pauseUntil = memory.PauseUntil

	-- ---- Chase: pursue until the player escapes or the leash is exceeded, then return home. ----
	if state == "Chase" then
		local lostPlayer = player == nil or (playerDist ~= nil and playerDist > config.DeaggroRadius)
		local overLeashed = distFromHome > config.LeashRadius
		if lostPlayer or overLeashed then
			return { State = "Return", RoamTarget = nil, PauseUntil = 0 }, { State = "Return", MoveTo = home, Speed = config.RoamSpeed, Face = home }
		end
		-- Hold at strike range and let the authoritative attack pass do the damage; keep facing the player.
		local target = Vector3.new((player :: Vector3).X, home.Y, (player :: Vector3).Z)
		if (playerDist :: number) <= config.AttackRange then
			return { State = "Chase", RoamTarget = nil, PauseUntil = 0 }, { State = "Chase", MoveTo = nil, Speed = config.ChaseSpeed, Face = target }
		end
		return { State = "Chase", RoamTarget = nil, PauseUntil = 0 }, { State = "Chase", MoveTo = target, Speed = config.ChaseSpeed, Face = target }
	end

	-- ---- Return: ignore players until back inside the territory, then resume normal life. ----
	if state == "Return" then
		if distFromHome <= config.RoamRadius then
			return { State = "Idle", RoamTarget = nil, PauseUntil = ctx.Now }, { State = "Idle", MoveTo = nil, Speed = config.RoamSpeed, Face = nil }
		end
		return { State = "Return", RoamTarget = nil, PauseUntil = 0 }, { State = "Return", MoveTo = home, Speed = config.RoamSpeed, Face = home }
	end

	-- ---- Idle / Roam: a nearby player triggers a chase, but only while still within leash of home. ----
	local canAggro = player ~= nil and playerDist ~= nil and playerDist <= config.AggroRadius and distFromHome <= config.LeashRadius
	if canAggro then
		local target = Vector3.new((player :: Vector3).X, home.Y, (player :: Vector3).Z)
		local move = if (playerDist :: number) <= config.AttackRange then nil else target
		return { State = "Chase", RoamTarget = nil, PauseUntil = 0 }, { State = "Chase", MoveTo = move, Speed = config.ChaseSpeed, Face = target }
	end

	if state == "Roam" and roamTarget ~= nil then
		local target = Vector3.new(roamTarget[1], roamTarget[2], roamTarget[3])
		if flatDistance(current, target) <= config.ArriveRadius then
			local pause = config.RoamPauseMin + ctx.Random() * (config.RoamPauseMax - config.RoamPauseMin)
			return { State = "Idle", RoamTarget = nil, PauseUntil = ctx.Now + pause }, { State = "Idle", MoveTo = nil, Speed = config.RoamSpeed, Face = nil }
		end
		return { State = "Roam", RoamTarget = roamTarget, PauseUntil = 0 }, { State = "Roam", MoveTo = target, Speed = config.RoamSpeed, Face = target }
	end

	-- Idle: wait out the pause, then pick a new roam point inside the territory.
	if ctx.Now >= pauseUntil then
		local point = randomPointInDisc(home, config.RoamRadius, ctx.Random)
		return { State = "Roam", RoamTarget = clonePoint(point), PauseUntil = 0 }, { State = "Roam", MoveTo = point, Speed = config.RoamSpeed, Face = point }
	end
	return { State = "Idle", RoamTarget = nil, PauseUntil = pauseUntil }, { State = "Idle", MoveTo = nil, Speed = config.RoamSpeed, Face = nil }
end

-- Builds a resolved Config from the defaults plus optional per-territory overrides. Any nil/invalid
-- override falls back to the default, so a territory only states what it changes.
function EnemyAI.ResolveConfig(overrides: { [string]: any }?): Config
	local resolved: { [string]: number } = {}
	for key, value in EnemyAI.Defaults :: any do
		local override = if type(overrides) == "table" then overrides[key] else nil
		resolved[key] = if type(override) == "number" and override == override and override >= 0 and override < math.huge then override else value
	end
	return table.freeze(resolved) :: any
end

return table.freeze(EnemyAI)
