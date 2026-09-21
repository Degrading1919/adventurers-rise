--!strict

-- Deterministic tests for the pure enemy movement/behaviour state machine (World/EnemyAI). It owns no
-- Roblox instances, so the whole notice -> approach -> chase -> disengage -> return loop is verified
-- headlessly. A tiny Vector3 stub stands in for the engine type (only .new and .X/.Y/.Z are used).

Vector3 = {
	new = function(x, y, z)
		return { X = x or 0, Y = y or 0, Z = z or 0 }
	end,
}

local EnemyAI = require("EnemyAI")

local passed = 0
local function test(name, run)
	local ok, message = pcall(run)
	assert(ok, name .. ": " .. tostring(message))
	passed += 1
	print("PASS " .. name)
end
local function equal(actual, expected)
	assert(actual == expected, ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
end
local function near(actual, expected, tol)
	assert(math.abs(actual - expected) <= (tol or 1e-6), ("expected ~%s, got %s"):format(tostring(expected), tostring(actual)))
end
local function flat(a, b)
	return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
end

local CONFIG = EnemyAI.ResolveConfig({
	AggroRadius = 20,
	DeaggroRadius = 30,
	LeashRadius = 50,
	RoamRadius = 15,
	RoamSpeed = 6,
	ChaseSpeed = 10,
	ArriveRadius = 2,
	RoamPauseMin = 2,
	RoamPauseMax = 4,
	AttackRange = 5,
})

local HOME = Vector3.new(0, 0, 0)

-- Builds a context with sensible defaults; overrides let each test set only what it cares about.
local function ctx(over)
	over = over or {}
	return {
		Home = over.Home or HOME,
		Current = over.Current or Vector3.new(0, 0, 0),
		Now = over.Now or 0,
		NearestPlayer = over.NearestPlayer,
		NearestPlayerDistance = over.NearestPlayerDistance,
		Config = CONFIG,
		Random = over.Random or function() return 0.25 end,
	}
end

test("an idle enemy waits out its pause, then picks a roam point inside the territory", function()
	local memory = { State = "Idle", RoamTarget = nil, PauseUntil = 100 }
	-- Still paused: holds position.
	local m1, i1 = EnemyAI.Step(memory, ctx({ Now = 50 }))
	equal(m1.State, "Idle")
	equal(i1.MoveTo, nil)
	-- Pause elapsed: rolls a roam point within RoamRadius of home and heads to it.
	local m2, i2 = EnemyAI.Step(memory, ctx({ Now = 100 }))
	equal(m2.State, "Roam")
	assert(m2.RoamTarget ~= nil, "a roam target must be chosen")
	assert(i2.MoveTo ~= nil, "roaming must produce a move target")
	assert(flat(i2.MoveTo, HOME) <= CONFIG.RoamRadius + 1e-6, "roam point must be inside the territory")
	near(i2.Speed, CONFIG.RoamSpeed)
end)

test("a roaming enemy heads to its target, then arriving switches to idle with a pause", function()
	local target = { X = 7.5, Y = 0, Z = 0 }
	local roaming = { State = "Roam", RoamTarget = { 7.5, 0, 0 }, PauseUntil = 0 }
	-- Far from the target: keeps moving toward it.
	local _, i1 = EnemyAI.Step(roaming, ctx({ Current = Vector3.new(0, 0, 0) }))
	equal(i1.State, "Roam")
	near(i1.MoveTo.X, target.X)
	-- Arrived (within ArriveRadius): idles and schedules a pause in [min, max].
	local m2, i2 = EnemyAI.Step(roaming, ctx({ Current = Vector3.new(7.5, 0, 0), Now = 10 }))
	equal(m2.State, "Idle")
	equal(i2.MoveTo, nil)
	assert(m2.PauseUntil >= 10 + CONFIG.RoamPauseMin and m2.PauseUntil <= 10 + CONFIG.RoamPauseMax, "pause must be within the configured range")
end)

test("a player within aggro range (and within leash) triggers a chase toward the player", function()
	local memory = { State = "Roam", RoamTarget = { 7.5, 0, 0 }, PauseUntil = 0 }
	local player = Vector3.new(15, 0, 0)
	local m, i = EnemyAI.Step(memory, ctx({ Current = Vector3.new(0, 0, 0), NearestPlayer = player, NearestPlayerDistance = 15 }))
	equal(m.State, "Chase")
	assert(i.MoveTo ~= nil, "must close on the player")
	near(i.MoveTo.X, 15)
	near(i.Speed, CONFIG.ChaseSpeed)
	assert(i.Face ~= nil, "must face the player")
end)

test("a chasing enemy holds at attack range instead of driving into the player", function()
	local memory = { State = "Chase", RoamTarget = nil, PauseUntil = 0 }
	local player = Vector3.new(4, 0, 0)
	local m, i = EnemyAI.Step(memory, ctx({ Current = Vector3.new(0, 0, 0), NearestPlayer = player, NearestPlayerDistance = 4 }))
	equal(m.State, "Chase")
	equal(i.MoveTo, nil) -- already within AttackRange (5); stop and let combat resolve
	assert(i.Face ~= nil, "still faces the player while striking")
end)

test("a chase ends and returns home when the player escapes beyond deaggro range", function()
	local memory = { State = "Chase", RoamTarget = nil, PauseUntil = 0 }
	local player = Vector3.new(40, 0, 0)
	local m, i = EnemyAI.Step(memory, ctx({ Current = Vector3.new(10, 0, 0), NearestPlayer = player, NearestPlayerDistance = 40 }))
	equal(m.State, "Return")
	assert(i.MoveTo == ctx().Home or (i.MoveTo.X == HOME.X and i.MoveTo.Z == HOME.Z), "returns toward home")
end)

test("a chase leashes home once the enemy strays beyond its leash radius, even with the player close", function()
	local memory = { State = "Chase", RoamTarget = nil, PauseUntil = 0 }
	local player = Vector3.new(58, 0, 0)
	-- Enemy is 60 from home (> LeashRadius 50) though the player is only 2 away: leash wins.
	local m, i = EnemyAI.Step(memory, ctx({ Current = Vector3.new(60, 0, 0), NearestPlayer = player, NearestPlayerDistance = 2 }))
	equal(m.State, "Return")
	near(i.MoveTo.X, HOME.X)
	near(i.MoveTo.Z, HOME.Z)
end)

test("a returning enemy ignores nearby players until it is back inside the territory", function()
	local memory = { State = "Return", RoamTarget = nil, PauseUntil = 0 }
	local player = Vector3.new(41, 0, 0)
	-- Still far from home (40 > RoamRadius 15): keeps returning, ignores the adjacent player.
	local m1, i1 = EnemyAI.Step(memory, ctx({ Current = Vector3.new(40, 0, 0), NearestPlayer = player, NearestPlayerDistance = 1 }))
	equal(m1.State, "Return")
	near(i1.MoveTo.X, HOME.X)
	-- Back inside the territory: resumes normal idle life.
	local m2, i2 = EnemyAI.Step(memory, ctx({ Current = Vector3.new(10, 0, 0), NearestPlayer = player, NearestPlayerDistance = 31 }))
	equal(m2.State, "Idle")
	equal(i2.MoveTo, nil)
end)

test("an idle enemy already beyond its leash does not aggro a nearby player", function()
	local memory = { State = "Idle", RoamTarget = nil, PauseUntil = 1000 }
	local player = Vector3.new(62, 0, 0)
	-- Enemy 60 from home (> leash), player only 2 away: proximity is ignored because it is out of leash.
	local m, i = EnemyAI.Step(memory, ctx({ Current = Vector3.new(60, 0, 0), Now = 0, NearestPlayer = player, NearestPlayerDistance = 2 }))
	equal(m.State, "Idle")
	equal(i.MoveTo, nil)
end)

test("ResolveConfig applies valid overrides and falls back to defaults for missing/invalid ones", function()
	local resolved = EnemyAI.ResolveConfig({ AggroRadius = 99, RoamSpeed = -5, Bogus = 3 })
	equal(resolved.AggroRadius, 99) -- valid override kept
	equal(resolved.RoamSpeed, EnemyAI.Defaults.RoamSpeed) -- negative rejected -> default
	equal(resolved.ChaseSpeed, EnemyAI.Defaults.ChaseSpeed) -- unspecified -> default
	local defaults = EnemyAI.ResolveConfig(nil)
	equal(defaults.AggroRadius, EnemyAI.Defaults.AggroRadius)
end)

print(("%d EnemyAI checks passed"):format(passed))
