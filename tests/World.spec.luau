--!strict

-- Deterministic tests for World's multiplayer target selection. A live two-player Studio session
-- cannot be driven headlessly here, so the selection logic is extracted as the pure
-- World.SelectAttackTarget and verified directly against a fake resolver.

local World = require("WorldService")

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

-- Resolver double: `engaged` is the set of userIds the enemy will actually attack (aggressive or
-- provoked). Records call order so we can assert nearest-first evaluation and stop-at-first-hit.
local function resolver(engaged)
	local calls = {}
	local fn = function(userId)
		table.insert(calls, userId)
		if engaged[userId] then
			return { landed = true, target = userId }
		end
		return nil, "NotEngaged"
	end
	return fn, calls
end

test("a nearer passive player does not block an eligible farther player", function()
	local fn, calls = resolver({ [2] = true }) -- only player 2 is engaged
	local candidates = {
		{ UserId = 1, Distance = 3 }, -- closest, passive/overleveled
		{ UserId = 2, Distance = 9 }, -- farther, eligible
	}
	local chosen, result = World.SelectAttackTarget(candidates, fn)
	assert(chosen ~= nil and result ~= nil, "an eligible target must be chosen")
	equal(chosen.UserId, 2)
	equal(result.target, 2)
	-- Nearest was evaluated first and skipped, then the eligible farther one was hit; no further tries.
	equal(calls[1], 1)
	equal(calls[2], 2)
	equal(#calls, 2)
end)

test("the nearest engaged player is chosen and no farther player is attacked", function()
	local fn, calls = resolver({ [1] = true, [2] = true })
	local candidates = {
		{ UserId = 2, Distance = 9 },
		{ UserId = 1, Distance = 3 }, -- given out of order; must still be picked as nearest
	}
	local chosen = assert(World.SelectAttackTarget(candidates, fn))
	equal(chosen.UserId, 1)
	equal(#calls, 1) -- stops at the first (nearest) engaged target
	equal(calls[1], 1)
end)

test("no engaged candidate in range yields no attack", function()
	local fn, calls = resolver({}) -- nobody engaged
	local candidates = { { UserId = 1, Distance = 3 }, { UserId = 2, Distance = 9 } }
	local chosen, result = World.SelectAttackTarget(candidates, fn)
	equal(chosen, nil)
	equal(result, nil)
	equal(#calls, 2) -- both tried, both passive
end)

test("an empty candidate list yields no attack", function()
	local fn = resolver({ [1] = true })
	local chosen = World.SelectAttackTarget({}, fn)
	equal(chosen, nil)
end)

-- ----------------------------------------------------------------------------------------------------
-- Enemy lifecycle: Start's runtime-contract validation, and provocation cleared the instant an enemy
-- dies (not deferred to its later respawn).
--
-- World.New/Start read a live Studio DataModel, so this section installs a minimal stub of only the
-- Roblox surface the module touches (a `typeof` that reports "Instance" for our fakes, plus small
-- Instance/Vector3/Color3/Enum/UDim2 stand-ins). It is intentionally just enough to instantiate the
-- service, build one enemy at a tagged spawn marker, and run a single death-poll iteration -- not a
-- general Roblox mock. A live two-player session still cannot be driven headlessly, so only these
-- deterministic single-instance lifecycle facts are asserted here.
-- ----------------------------------------------------------------------------------------------------

typeof = function(value: any): string
	if type(value) == "table" and (value :: any).__isInstance then
		return "Instance"
	end
	return type(value)
end

local vectorMeta: any = {}
vectorMeta.__add = function(a, b)
	return setmetatable({ X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z }, vectorMeta)
end
vectorMeta.__sub = function(a, b)
	return setmetatable({ X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z }, vectorMeta)
end
Vector3 = {
	new = function(x, y, z)
		return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, vectorMeta)
	end,
	zero = setmetatable({ X = 0, Y = 0, Z = 0 }, vectorMeta),
}
Color3 = { fromRGB = function() return {} end }
UDim2 = { new = function() return {} end }
Enum = { Material = { SmoothPlastic = {} } }

local cframeMeta = { __add = function(a, _) return a end }
local function makeCFrame(): any
	return setmetatable({}, cframeMeta)
end

-- Permissive fake Instance: stores any property, tracks parented children, answers the handful of
-- methods buildEnemyModel / the death poll call. Values are stored on a side table so __newindex never
-- recurses.
local function newInstance(className: string): any
	local props: any = { ClassName = className, Name = className, __isInstance = true }
	local attrs: any = {}
	local children: any = {}
	local methods: any = {}
	methods.SetAttribute = function(_, key, value)
		attrs[key] = value
	end
	methods.GetAttribute = function(_, key)
		return attrs[key]
	end
	methods.IsA = function(_, class)
		return class == props.ClassName or (class == "BasePart" and props.ClassName == "Part")
	end
	methods.IsDescendantOf = function()
		return true
	end
	methods.FindFirstChild = function(_, name)
		return children[name]
	end
	methods.FindFirstChildOfClass = function(_, class)
		for _, child in children do
			if child.ClassName == class then
				return child
			end
		end
		return nil
	end
	methods.GetPivot = function()
		return { Position = Vector3.new(0, 0, 0) }
	end
	methods.__addChild = function(name, child)
		children[name] = child
	end
	local self
	self = setmetatable({}, {
		__index = function(_, key)
			if methods[key] ~= nil then
				return methods[key]
			end
			return props[key]
		end,
		__newindex = function(_, key, value)
			if key == "Parent" and type(value) == "table" and (value :: any).__addChild then
				(value :: any).__addChild(props.Name, self)
			end
			props[key] = value
		end,
	})
	return self
end

Instance = { new = newInstance }

local RUNTIME_ID = "rid-alpha"

-- Fresh Studio-environment stub plus call trackers for one lifecycle test.
local function makeEnv(): (any, any)
	local calls = { clearEnemy = {}, remove = {}, resolve = {} }
	local marker = newInstance("Part")
	marker:SetAttribute("EnemyDefinitionId", "enemy_goblin")
	marker.CFrame = makeCFrame()
	local folder = newInstance("Folder")
	local waitCount = 0
	local runtime = {
		Players = {
			__isInstance = true,
			GetPlayers = function()
				return {}
			end,
			GetPlayerByUserId = function()
				return nil
			end,
			PlayerAdded = {
				Connect = function()
					return { Disconnect = function() end }
				end,
			},
		},
		Workspace = {
			__isInstance = true,
			FindFirstChild = function()
				return folder
			end,
		},
		Collection = {
			__isInstance = true,
			GetTagged = function(_, tag)
				if tag == "AR_EnemySpawn" then
					return { marker }
				end
				return {}
			end,
			AddTag = function() end,
		},
		Clock = function()
			return 0
		end,
		Warn = function() end,
		-- Runs the shared poll body synchronously so the test can observe it.
		Spawn = function(fn, ...)
			fn(...)
		end,
		-- Let exactly one poll iteration run, then halt the otherwise-infinite loop with a sentinel.
		Wait = function()
			waitCount += 1
			if waitCount >= 2 then
				error("__stop__", 0)
			end
		end,
	}
	return runtime, calls
end

-- Enemies double: the single enemy is reported dead so the first poll transitions it to dead.
local function makeEnemies(calls: any): any
	return {
		Create = function()
			return { RuntimeId = RUNTIME_ID, Level = 3, DefinitionId = "enemy_goblin" }, nil
		end,
		GetSnapshot = function()
			return { Alive = false, RuntimeId = RUNTIME_ID }
		end,
		Remove = function()
			table.insert(calls.remove, true)
		end,
	}
end

-- EnemyCombat double. `omit` drops one required method to exercise Start's contract validation.
local function makeResolver(calls: any, omit: string?): any
	local resolverDouble = {
		ResolveAttack = function(userId)
			table.insert(calls.resolve, userId)
			return nil, "NotEngaged"
		end,
		OnSpawn = function() end,
		ClearEnemy = function(runtimeId)
			table.insert(calls.clearEnemy, runtimeId)
		end,
	}
	if omit then
		resolverDouble[omit] = nil
	end
	return resolverDouble
end

for _, method in { "ResolveAttack", "OnSpawn", "ClearEnemy" } do
	test("Start fails immediately when the enemy-combat resolver is missing " .. method, function()
		local runtime, calls = makeEnv()
		local service = World.New(runtime)
		local ok, err = pcall(function()
			service.Start(makeEnemies(calls), makeResolver(calls, method))
		end)
		assert(not ok, "Start must reject a resolver missing " .. method)
		assert(
			tostring(err):find("enemy%-combat resolver") ~= nil,
			"expected a contract-validation error, got: " .. tostring(err)
		)
		-- Rejected at startup, before any enemy was built or polled.
		equal(#calls.clearEnemy, 0)
		equal(#calls.remove, 0)
	end)
end

test("provocation state is cleared the instant an enemy dies, before its respawn", function()
	local runtime, calls = makeEnv()
	local service = World.New(runtime)
	local ok, err = pcall(function()
		-- A complete resolver is accepted; Start builds the enemy and runs one death-poll iteration
		-- before the stubbed Wait halts the shared loop with the sentinel.
		service.Start(makeEnemies(calls), makeResolver(calls))
	end)
	assert(not ok and tostring(err):find("__stop__") ~= nil, "expected the stubbed loop halt, got: " .. tostring(err))
	-- The enemy transitioned to dead and its RuntimeId's provocation was cleared exactly once...
	equal(#calls.clearEnemy, 1)
	equal(calls.clearEnemy[1], RUNTIME_ID)
	-- ...at death, not at respawn: enemies.Remove (the respawn's retire step) has not run yet.
	equal(#calls.remove, 0)
end)

-- ===== Enemy health presentation (sanitizer + mirror) =====
test("SanitizeEnemyHealth mirrors an alive enemy's authoritative current/max health", function()
	local h = World.SanitizeEnemyHealth({ Alive = true, Health = 20, MaxHealth = 48 })
	equal(h.Health, 20)
	equal(h.MaxHealth, 48)
end)

test("SanitizeEnemyHealth never presents positive health for a dead enemy", function()
	local h = World.SanitizeEnemyHealth({ Alive = false, Health = 48, MaxHealth = 48 })
	equal(h.Health, 0)
	equal(h.MaxHealth, 48)
end)

test("SanitizeEnemyHealth clamps overkill/invalid current health into [0, MaxHealth]", function()
	equal(World.SanitizeEnemyHealth({ Alive = true, Health = -5, MaxHealth = 30 }).Health, 0)
	equal(World.SanitizeEnemyHealth({ Alive = true, Health = 999, MaxHealth = 30 }).Health, 30)
	equal(World.SanitizeEnemyHealth({ Alive = true, MaxHealth = 30 }).Health, 0)
	local noMax = World.SanitizeEnemyHealth({ Alive = true, Health = 10 })
	equal(noMax.MaxHealth, 0)
	equal(noMax.Health, 0)
end)

test("SanitizeEnemyHealth is definition-agnostic and never mutates its input (one authority for normal and boss)", function()
	local goblin = { Alive = true, Health = 20, MaxHealth = 48 }
	local chieftain = { Alive = true, Health = 200, MaxHealth = 400 }
	equal(World.SanitizeEnemyHealth(goblin).Health, 20)
	equal(World.SanitizeEnemyHealth(chieftain).Health, 200)
	equal(goblin.Health, 20)
	equal(chieftain.Health, 200)
end)

local function makeHealthEnemies(createState, snapshotState, calls)
	return {
		Create = function()
			table.insert(calls.create, true)
			return createState, nil
		end,
		GetSnapshot = function()
			return snapshotState
		end,
		Remove = function()
			table.insert(calls.remove, true)
		end,
	}
end

test("World mirrors the authoritative current/max health onto the bound model, read-only", function()
	local runtime, calls = makeEnv()
	calls.create = {}
	local service = World.New(runtime)
	local ok, err = pcall(function()
		service.Start(
			makeHealthEnemies(
				{ RuntimeId = RUNTIME_ID, Level = 3, DefinitionId = "enemy_goblin", MaxHealth = 48, Health = 48, Alive = true },
				{ Alive = true, RuntimeId = RUNTIME_ID, Health = 20, MaxHealth = 48 },
				calls
			),
			makeResolver(calls)
		)
	end)
	assert(not ok and tostring(err):find("__stop__") ~= nil, "expected the stubbed loop halt, got: " .. tostring(err))
	local described = service.DescribeEnemies()
	equal(#described, 1)
	equal(described[1].MaxHealth, 48)
	-- Synced from the (damaged) authoritative snapshot -- the client never computes this.
	equal(described[1].Health, 20)
	equal(described[1].Alive, true)
	-- The presentation sync only READ the snapshot: the enemy was created once and never retired/mutated.
	equal(#calls.create, 1)
	equal(#calls.remove, 0)
end)

test("a dead authoritative snapshot forces the mirrored health to zero regardless of its reported value", function()
	local runtime, calls = makeEnv()
	calls.create = {}
	local service = World.New(runtime)
	local ok = pcall(function()
		service.Start(
			makeHealthEnemies(
				{ RuntimeId = RUNTIME_ID, Level = 3, DefinitionId = "enemy_goblin", MaxHealth = 48, Health = 48, Alive = true },
				{ Alive = false, RuntimeId = RUNTIME_ID, Health = 48, MaxHealth = 48 },
				calls
			),
			makeResolver(calls)
		)
	end)
	assert(not ok, "expected the stubbed loop halt")
	local described = service.DescribeEnemies()
	equal(described[1].Health, 0)
	equal(described[1].Alive, false)
end)

test("respawn refreshes the mirrored max/current health and the RuntimeId from the fresh authoritative state", function()
	local calls = { clearEnemy = {}, remove = {}, resolve = {}, create = {} }
	local marker = newInstance("Part")
	marker:SetAttribute("EnemyDefinitionId", "enemy_goblin")
	marker.CFrame = makeCFrame()
	local folder = newInstance("Folder")
	local clockVal = 0
	local waitCount = 0
	local runtime = {
		Players = {
			__isInstance = true,
			GetPlayers = function() return {} end,
			GetPlayerByUserId = function() return nil end,
			PlayerAdded = { Connect = function() return { Disconnect = function() end } end },
		},
		Workspace = { __isInstance = true, FindFirstChild = function() return folder end },
		Collection = {
			__isInstance = true,
			GetTagged = function(_, tag)
				if tag == "AR_EnemySpawn" then
					return { marker }
				end
				return {}
			end,
			AddTag = function() end,
		},
		Clock = function() return clockVal end,
		Warn = function() end,
		Spawn = function(fn, ...) fn(...) end,
		-- Advance the clock each tick so the 5s respawn timer is reached, then halt after a few polls.
		Wait = function()
			waitCount += 1
			clockVal += 3
			if waitCount >= 4 then
				error("__stop__", 0)
			end
		end,
	}
	local createCount = 0
	local enemies = {
		Create = function()
			createCount += 1
			table.insert(calls.create, true)
			if createCount == 1 then
				return { RuntimeId = "rid-1", Level = 3, DefinitionId = "enemy_goblin", MaxHealth = 48, Health = 48, Alive = true }, nil
			end
			return { RuntimeId = "rid-2", Level = 8, DefinitionId = "enemy_goblin", MaxHealth = 78, Health = 78, Alive = true }, nil
		end,
		GetSnapshot = function(rid)
			if rid == "rid-1" then
				return { Alive = false, RuntimeId = "rid-1" }
			end
			return { Alive = true, RuntimeId = rid, Health = 78, MaxHealth = 78 }
		end,
		Remove = function(rid) table.insert(calls.remove, rid) end,
	}
	local resolver = {
		ResolveAttack = function() return nil, "NotEngaged" end,
		OnSpawn = function() end,
		ClearEnemy = function(rid) table.insert(calls.clearEnemy, rid) end,
	}
	local service = World.New(runtime)
	local ok = pcall(function() service.Start(enemies, resolver) end)
	assert(not ok, "expected the stubbed loop halt")
	equal(createCount, 2)
	local described = service.DescribeEnemies()
	equal(#described, 1)
	equal(described[1].RuntimeId, "rid-2")
	equal(described[1].Health, 78)
	equal(described[1].MaxHealth, 78)
	equal(described[1].Alive, true)
	equal(#calls.remove, 1)
	equal(calls.remove[1], "rid-1")
end)

print(("%d World checks passed"):format(passed))
