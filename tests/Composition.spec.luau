--!strict

local SkillIds = require("SkillIds")
local EquipmentSlots = require("EquipmentSlots")
local EnemyIds = require("EnemyIds")
local GatheringNodeIds = require("GatheringNodeIds")
local AscensionIds = require("AscensionIds")
local ProgressionFlagIds = require("ProgressionFlagIds")
local MasteryIds = require("MasteryIds")
local SkillCurves = require("SkillCurves")
local EconomyService = require("EconomyService")
local PlayerDataSchema = require("PlayerDataSchema")
local PlayerDataStore = require("PlayerDataStore")
local PlayerDataService = require("PlayerDataService")
local RequestIds = require("RequestIds")
local CompositionWorldAdapters = require("CompositionWorldAdapters")
local Composition = require("CompositionService")

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

local function fakePlayer(id)
	local p = { UserId = id, Kicked = false }
	function p:Kick() self.Kicked = true end
	return p
end

-- Deliberately different domains/magnitudes so a clock-domain mixup (e.g. OfflineTraining fed the
-- monotonic clock, or Combat fed the wall clock) would visibly break tests rather than silently
-- happening to work because both clocks started at the same number.
local CLOCK_START = 100
local WALL_START = 1758000000

-- PlayerData only Releases a session when PlayerRemoving fires the SAME Player object instance
-- that PlayerAdded reported (real Roblox Player objects persist identity for the connection's
-- whole lifetime); this cache is what makes leavePlayer match join for the same user.
local playerObjects: { [any]: { [number]: any } } = setmetatable({}, { __mode = "k" })
local function playerObjectsFor(f: any, seed: { [number]: any }?)
	local objects = playerObjects[f]
	if not objects then
		objects = seed or {}
		playerObjects[f] = objects
	end
	return objects
end

-- Builds the raw PlayerData/Composition stack (fake DataStore, a real cooperative scheduler, and
-- configurable fake world adapters) WITHOUT starting either service, so tests can control the
-- Start() call order themselves (see the lifecycle-ordering test). `fixture()` below is the normal
-- entry point that starts them in the correct order.
local function buildStack(options: any?)
	options = options or {}
	local elapsed = 0
	local f = { Serial = 0, Records = {}, Failures = 0 }
	function f:UpdateAsync(key, transform)
		if self.Failures > 0 then
			self.Failures -= 1
			error("unavailable")
		end
		local info = { GetUserIds = function() return {} end, GetMetadata = function() return {} end }
		local value = transform(PlayerDataSchema.Copy(self.Records[key]), info)
		if value == nil then
			return nil
		end
		self.Records[key] = PlayerDataSchema.Copy(value)
		return PlayerDataSchema.Copy(value)
	end

	local function wallNow() return math.floor(WALL_START + elapsed) end
	local function monotonicClock() return CLOCK_START + elapsed end

	local backend = PlayerDataStore.New(f, {
		Now = wallNow,
		Sleep = function(seconds) elapsed += seconds end,
		NewToken = function() f.Serial += 1; return "token_" .. f.Serial end,
	})

	-- A real cooperative scheduler (mirrors PlayerData.spec.luau's `lifecycle()`): Wait(seconds)
	-- yields the current coroutine, parking it until `advance` resumes it at its wake time. This
	-- is what lets the composition heartbeat (and PlayerData's own autosave loop) actually fire
	-- during a test instead of running forever synchronously on the first Wait.
	local queue: { { Thread: thread, At: number } } = {}
	local function spawn(fn, ...)
		local thread = coroutine.create(fn)
		local ok, delay = coroutine.resume(thread, ...)
		assert(ok, delay)
		if coroutine.status(thread) ~= "dead" then
			table.insert(queue, { Thread = thread, At = elapsed + (delay or 0) })
		end
	end
	local function advance(seconds: number)
		local target = elapsed + seconds
		while true do
			table.sort(queue, function(a, b) return a.At < b.At end)
			if #queue == 0 or queue[1].At > target then
				break
			end
			local entry = table.remove(queue, 1)
			elapsed = entry.At
			local ok, delay = coroutine.resume(entry.Thread)
			assert(ok, delay)
			if coroutine.status(entry.Thread) ~= "dead" then
				table.insert(queue, { Thread = entry.Thread, At = elapsed + (delay or 0) })
			end
		end
		elapsed = target
	end

	local function signal()
		local handlers = {}
		return {
			Connect = function(_, handler) table.insert(handlers, handler) end,
			Fire = function(_, ...) for _, handler in handlers do spawn(handler, ...) end end,
		}
	end
	local players = { List = {}, PlayerAdded = signal(), PlayerRemoving = signal() }
	function players:GetPlayers() return self.List end
	local warnings = {}
	local playerData = PlayerDataService.New(backend, {
		Players = players,
		Spawn = spawn,
		Wait = coroutine.yield,
		Clock = monotonicClock,
		Now = wallNow,
		BindToClose = function() end,
		Warn = function(message) table.insert(warnings, message) end,
	})

	-- Fake world adapters: tests configure these per runtimeId/nodeId; unconfigured entries fail
	-- closed exactly like the real placeholder adapters, without fabricating a target/node.
	local combatDistances: { [string]: number } = {}
	local gatheringNodes: { [string]: { Eligible: boolean, Distance: number } } = {}
	-- Station/Forge proximity doubles: default to "at the station/Forge" (distance 0) so existing
	-- tests exercise the normal near case; a test sets a large distance to model walking away.
	local stationDistances: { [string]: number } = {}
	local forgeDistance = { Value = 0 }
	local worldAdapters = {
		CombatDistanceProvider = function(_attackerUserId: number, enemyState: any): (number?, string?)
			local distance = combatDistances[enemyState.RuntimeId]
			if distance == nil then
				return nil, "NoWorldMapping"
			end
			return distance, nil
		end,
		GatheringNodeResolver = function(_userId: number, nodeId: string): (any?, string?)
			local config = gatheringNodes[nodeId]
			if not config then
				return nil, "NoWorldMapping"
			end
			return { Id = nodeId, Eligible = config.Eligible, Distance = config.Distance }, nil
		end,
		StationDistanceProvider = function(_userId: number, stationId: string): (number?, string?)
			local distance = stationDistances[stationId]
			if distance == nil then
				return 0, nil
			end
			return distance, nil
		end,
		ForgeDistanceProvider = function(_userId: number): (number?, string?)
			return forgeDistance.Value, nil
		end,
	}

	local roll01Value = 0
	local instanceSerial = 0
	local runtimeSerial = 0
	local composition = Composition.New(playerData, {
		Clock = monotonicClock,
		Now = wallNow,
		NewInstanceId = function() instanceSerial += 1; return "instance_" .. instanceSerial end,
		NewRuntimeId = function() runtimeSerial += 1; return "runtime_" .. runtimeSerial end,
		RollInteger = function(minimum: number, _maximum: number) return minimum end,
		Roll01 = function() return roll01Value end,
		Warn = function(message) table.insert(warnings, message) end,
		Spawn = spawn,
		Wait = coroutine.yield,
	}, worldAdapters)

	f.PlayerData = playerData
	f.Players = players
	f.Composition = composition
	f.CombatDistances = combatDistances
	f.GatheringNodes = gatheringNodes
	f.StationDistances = stationDistances
	f.ForgeDistance = forgeDistance
	f.Warnings = warnings
	f.Advance = advance
	f.Clock = monotonicClock
	f.Now = wallNow

	-- PlayerData only Releases a session when PlayerRemoving fires the SAME Player object instance
	-- that PlayerAdded reported; pre-joining here (before Start()) models "already connected when
	-- the server starts" and registers those objects so leavePlayer can find them later.
	local prejoined = options.PrejoinedUserIds or {}
	if #prejoined > 0 then
		local objects = {}
		playerObjectsFor(f, objects)
		for _, userId in prejoined do
			local player = fakePlayer(userId)
			objects[userId] = player
			table.insert(players.List, player)
		end
	end

	return f, playerData, composition
end

-- The normal entry point: builds the stack and starts Composition's PlayerData-ready lifecycle
-- subscriptions (and its periodic-settlement heartbeat) before PlayerData.Start() begins loading
-- any already-connected players, matching Bootstrap's required ordering.
local function fixture(options: any?)
	local f, playerData, composition = buildStack(options)
	composition.Start()
	playerData.Start()
	return f
end

local function joinPlayer(f, userId: number): boolean
	local objects = playerObjectsFor(f)
	local player = fakePlayer(userId)
	objects[userId] = player
	f.Players.PlayerAdded:Fire(player)
	return f.Composition.IsGameplayReady(userId)
end

local function leavePlayer(f, userId: number)
	local objects = playerObjectsFor(f)
	local player = objects[userId]
	assert(player, "leavePlayer called before joinPlayer for this user")
	f.Players.PlayerRemoving:Fire(player)
end

local function request(f, userId: number, requestId: any, payload: any)
	return f.Composition.HandleRequest(userId, requestId, payload)
end

local function grantWeapon(f, userId: number): string
	local item = assert(f.Composition.Services.Inventory.AddDiscreteItem(userId, "weapon_sword_starter"))
	assert(f.Composition.Services.Equipment.Equip(userId, EquipmentSlots.Weapon, item.InstanceId))
	return item.InstanceId
end

local function grantPickaxe(f, userId: number): string
	local item = assert(f.Composition.Services.Inventory.AddDiscreteItem(userId, "tool_pickaxe_basic"))
	assert(f.Composition.Services.Equipment.Equip(userId, EquipmentSlots.Tool, item.InstanceId))
	return item.InstanceId
end

local function setSkillLevel(f, userId: number, skillId: string, level: number)
	local xp = SkillCurves.curve_standard.Thresholds[level]
	assert(f.PlayerData.Update(userId, function(data) data.SkillXP[skillId] = xp end))
end

-- ===== Composition =====

test("composition constructs every vertical-slice service with valid fake dependencies", function()
	local f = fixture()
	local services = f.Composition.Services
	for _, name in {
		"Skills", "Inventory", "Equipment", "Economy", "Plots", "Enemies", "Combat",
		"Gathering", "Crafting", "Bosses", "Ascension", "Mastery", "OfflineTraining",
	} do
		assert(services[name] ~= nil, "missing composed service: " .. name)
	end
end)

test("unconfigured world adapters fail closed for Combat and Gathering instead of fabricating a target/node", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	grantPickaxe(f, 7)
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	local attack = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
	equal(attack.Ok, false)
	local begin = request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre })
	equal(begin.Ok, false)
end)

test("the fail-closed placeholder world adapters report the missing Studio boundary", function()
	local distance, reason = CompositionWorldAdapters.FailClosedCombatDistanceProvider()(7, { RuntimeId = "x" })
	equal(distance, nil)
	equal(reason, "WorldAdapterNotConfigured")
	local node, nodeReason = CompositionWorldAdapters.FailClosedGatheringNodeResolver()(7, "node_iron_ore")
	equal(node, nil)
	equal(nodeReason, "WorldAdapterNotConfigured")
end)

-- ===== Clock-domain separation =====

test("offline claims use wall time even though monotonic time has barely advanced, and Combat's cooldown uses monotonic time even though wall time is astronomically larger", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	assert(request(f, 7, RequestIds.OfflineTrainingSetFocus, { SkillId = SkillIds.Melee }).Ok)
	assert(f.Clock() < 1000, "monotonic domain should stay small")
	assert(f.Now() > 1000000000, "wall domain should be epoch-scale")
	leavePlayer(f, 7)
	f.Advance(3600) -- one wall-clock hour; monotonic also only advances by 3600 seconds
	joinPlayer(f, 7)
	local state = assert(request(f, 7, RequestIds.StateGet, {}).Result)
	assert(state.OfflineReturn.Rewarded, "offline progress must be measured in the wall-clock domain")
	-- Combat's cooldown/target resolution must not be thrown off by the enormous wall-clock gap
	-- that just passed -- it is keyed off the monotonic clock, which only moved by 3600 seconds.
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	f.CombatDistances[enemy.RuntimeId] = 1
	local attack = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
	assert(attack.Ok, attack.Reason)
end)

test("no code compares OfflineTraining's persisted-epoch window against the monotonic clock: a fresh player's ClaimedThroughAt/LastSessionAt land in the wall-clock domain, not the monotonic one", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.OfflineTrainingSetFocus, { SkillId = SkillIds.Melee }).Ok)
	local data = assert(f.PlayerData.GetSnapshot(7))
	assert(data.OfflineTraining.ClaimedThroughAt > 1000000000, "SetFocus's claim baseline must be stamped in the wall-clock domain")
end)

-- ===== PlayerData-ready lifecycle startup ordering =====

test("Composition subscribes before PlayerData.Start begins loading, so an already-connected player's ready event and automatic offline processing are observed; the reverse order misses it", function()
	local correct, correctPlayerData, correctComposition = buildStack({ PrejoinedUserIds = { 7 } })
	correctComposition.Start()
	correctPlayerData.Start()
	equal(correctComposition.IsGameplayReady(7), true)
	local state = assert(request(correct, 7, RequestIds.StateGet, {}).Result)
	assert(state.OfflineReturn ~= nil, "the automatic offline-return claim must have run for the already-connected player")

	-- Demonstrates why the order matters: starting PlayerData first means it has already iterated
	-- and loaded the pre-connected player (firing OnReady to no one) before Composition ever
	-- subscribes, so that player's ready event -- and gameplay readiness -- is missed entirely.
	local reversed, reversedPlayerData, reversedComposition = buildStack({ PrejoinedUserIds = { 7 } })
	reversedPlayerData.Start()
	reversedComposition.Start()
	equal(reversedComposition.IsGameplayReady(7), false)
end)

-- ===== Player-ready lifecycle and automatic offline return =====

test("gameplay is locked until the session becomes ready, and the offline claim runs exactly once as part of that", function()
	local f = fixture()
	equal(f.Composition.IsGameplayReady(7), false)
	local before = request(f, 7, RequestIds.StateGet, {})
	equal(before.Ok, false)
	equal(before.Reason, "SessionNotReady")

	joinPlayer(f, 7)
	equal(f.Composition.IsGameplayReady(7), true)
	local state = assert(request(f, 7, RequestIds.StateGet, {}).Result)
	assert(state.OfflineReturn ~= nil)
	equal(state.OfflineReturn.Rewarded, false)
	equal(state.OfflineReturn.Reason, "NoFocusSelected")
end)

test("an offline focus selected before leaving is honored by the automatic claim on the next join", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.OfflineTrainingSetFocus, { SkillId = SkillIds.Melee }).Ok)
	leavePlayer(f, 7)
	f.Advance(3600)
	joinPlayer(f, 7)
	local state = assert(request(f, 7, RequestIds.StateGet, {}).Result)
	assert(state.OfflineReturn.Rewarded)
	assert(state.OfflineReturn.XPAwarded > 0)
end)

test("reading state does not mutate progression or re-run the offline claim", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.OfflineTrainingSetFocus, { SkillId = SkillIds.Melee }).Ok)
	leavePlayer(f, 7)
	f.Advance(3600)
	joinPlayer(f, 7)
	local first = assert(request(f, 7, RequestIds.StateGet, {}).Result)
	f.Advance(1)
	local second = assert(request(f, 7, RequestIds.StateGet, {}).Result)
	equal(first.Skills[SkillIds.Melee].XP, second.Skills[SkillIds.Melee].XP)
	equal(second.OfflineReturn.XPAwarded, first.OfflineReturn.XPAwarded)
end)

test("leaving clears gameplay readiness, the cached offline-return summary, and runtime activity", function()
	local f = fixture()
	joinPlayer(f, 7)
	leavePlayer(f, 7)
	equal(f.Composition.IsGameplayReady(7), false)
	equal(f.Composition.GetOfflineReturnSummary(7), nil)
end)

-- ===== Network authority =====

test("caller identity always comes from the trusted server context; a spoofed payload UserId is ignored", function()
	local f = fixture()
	joinPlayer(f, 7)
	joinPlayer(f, 8)
	assert(f.Composition.Services.Economy.CreditGold(7, 50))
	local result = request(f, 7, RequestIds.StateGet, { UserId = 8 })
	assert(result.Ok, result.Reason)
	equal(result.Result.Gold, 50)
end)

test("malformed payloads fail closed", function()
	local f = fixture()
	joinPlayer(f, 7)
	for _, case in {
		{ RequestIds.EquipmentEquip, "not_a_table" },
		{ RequestIds.EquipmentEquip, { SlotId = 5, InstanceId = "x" } },
		{ RequestIds.EconomyPurchaseStack, { CatalogId = "shop_hub" } },
		{ RequestIds.CombatMeleeAttack, {} },
		{ RequestIds.GatheringBegin, { NodeId = 5 } },
	} do
		f.Advance(1)
		local result = request(f, 7, case[1], case[2])
		equal(result.Ok, false)
		equal(result.Reason, "MalformedPayload")
	end
end)

test("unknown request IDs fail closed", function()
	local f = fixture()
	joinPlayer(f, 7)
	local result = request(f, 7, "not_a_real_request", {})
	equal(result.Ok, false)
	equal(result.Reason, "UnknownRequest")
end)

test("internal *ToData mutation helpers and claim-style requests are never reachable as network routes", function()
	local f = fixture()
	joinPlayer(f, 7)
	for _, id in { "AddStackToData", "CreditGoldToData", "AwardXPToData", "RemoveStackFromData", "boss_claim_reward", "offline_training_claim_reward" } do
		local result = request(f, 7, id, {})
		equal(result.Ok, false)
		equal(result.Reason, "UnknownRequest")
	end
	for _, id in RequestIds do
		if type(id) == "string" then
			assert(not id:find("claim"), "no claim-style request ID should exist: " .. id)
			assert(not id:find("ToData"), "no *ToData request ID should exist: " .. id)
		end
	end
end)

-- ===== Combat =====

test("a valid Melee request reaches Combat through the trusted target resolver", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	f.CombatDistances[enemy.RuntimeId] = 1
	local result = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
	assert(result.Ok, result.Reason)
	equal(result.Result.AppliedDamage, 10)
end)

test("the client cannot set damage, range, or cooldown -- only the equipped weapon's data is used", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	f.CombatDistances[enemy.RuntimeId] = 1
	local result = request(f, 7, RequestIds.CombatMeleeAttack, {
		TargetId = enemy.RuntimeId,
		Damage = 999999,
		AttackRange = 999999,
		AttackIntervalSeconds = 0,
	})
	assert(result.Ok, result.Reason)
	equal(result.Result.AppliedDamage, 10)
	equal(result.Result.AttackIntervalSeconds, 1)
	equal(result.Result.AttackRange, 8)
end)

test("an out-of-range target is rejected", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	f.CombatDistances[enemy.RuntimeId] = 999
	local result = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
	equal(result.Ok, false)
end)

test("a normal Goblin's death pays its authoritative Gold exactly once", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	f.CombatDistances[enemy.RuntimeId] = 1
	local before = assert(f.Composition.Services.Economy.GetGold(7))
	-- MaxHealth 30, weapon damage 10: exactly three hits kill it.
	for _ = 1, 3 do
		local result = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
		assert(result.Ok, result.Reason)
		f.Advance(2)
	end
	local afterKill = assert(f.Composition.Services.Economy.GetGold(7))
	equal(afterKill, before + enemy.GoldReward)
	-- A dead target becomes ineligible; there is no retry path that could pay a second time.
	local retry = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
	equal(retry.Ok, false)
	local afterRetry = assert(f.Composition.Services.Economy.GetGold(7))
	equal(afterRetry, afterKill)
end)

test("a Gold-credit failure on the lethal hit surfaces as a failed request, never pays twice, and never touches the Boss path", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	f.CombatDistances[enemy.RuntimeId] = 1
	-- Two non-lethal hits first (MaxHealth 30, weapon damage 10).
	for _ = 1, 2 do
		assert(request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId }).Ok)
		f.Advance(2)
	end
	-- Force the authoritative Gold credit itself to fail for the lethal third hit.
	assert(f.PlayerData.Update(7, function(data) data.Gold = EconomyService.MaximumGold end))
	local before = assert(f.Composition.Services.Economy.GetGold(7))
	local lethal = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
	equal(lethal.Ok, false)
	local afterFailedKill = assert(f.Composition.Services.Economy.GetGold(7))
	equal(afterFailedKill, before)
	-- The death is already consumed and the target already dead/ineligible, so even once Gold is
	-- no longer maxed, there is no path that pays it retroactively.
	assert(f.PlayerData.Update(7, function(data) data.Gold = 0 end))
	f.Advance(2)
	local retry = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
	equal(retry.Ok, false)
	local finalGold = assert(f.Composition.Services.Economy.GetGold(7))
	equal(finalGold, 0)
end)

-- ===== Boss integration =====

test("the Goblin Chieftain never pays through the normal Goblin reward path; participation rewards still apply", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local boss = assert(f.Composition.Services.Enemies.Create(EnemyIds.GoblinChieftain))
	f.CombatDistances[boss.RuntimeId] = 1
	local goldBefore = assert(f.Composition.Services.Economy.GetGold(7))
	-- MaxHealth 400, weapon damage 10: exactly forty hits kill it.
	for _ = 1, 40 do
		local result = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = boss.RuntimeId })
		assert(result.Ok, result.Reason)
		f.Advance(2)
	end
	local goldAfter = assert(f.Composition.Services.Economy.GetGold(7))
	equal(goldAfter, goldBefore + boss.GoldReward)
	-- The guaranteed common boss item is a signal the participation path ran; the normal-enemy
	-- reward path never grants it.
	local inventory = assert(f.Composition.Services.Inventory.GetSnapshot(7))
	equal(inventory.Stacks.item_iron_bar, 1)
	local progress = assert(f.Composition.Services.Ascension.EvaluateRequirements(7, AscensionIds.Adept))
	assert(progress.BossMilestone.Recorded)
end)

-- ===== Gathering timing =====

test("Gathering Begin validates without awarding any ore or XP; zero elapsed after Begin awards nothing", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantPickaxe(f, 7)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 }
	local began = request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre })
	assert(began.Ok, began.Reason)
	equal(began.Result.NodeId, GatheringNodeIds.IronOre)
	equal(began.Result.ToolDefinitionId, "tool_pickaxe_basic")
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, nil)
	local stopped = request(f, 7, RequestIds.GatheringEnd, {})
	equal(stopped.Ok, false)
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, nil)
end)

test("Gathering Begin plus 5 real elapsed seconds credits exactly 5 seconds of progress", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantPickaxe(f, 7)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 }
	assert(request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre }).Ok)
	f.Advance(5)
	request(f, 7, RequestIds.GatheringEnd, {}) -- likely already settled by the periodic heartbeat
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, 5)
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Mining)).XP, 10)
end)

test("repeatedly calling Gathering Begin without advancing the clock never creates ore or XP", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantPickaxe(f, 7)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 }
	for _ = 1, 5 do
		request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre })
	end
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, nil)
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Mining)).XP, 0)
end)

test("repeatedly replacing a Gathering session cannot manufacture bonus seconds beyond real elapsed time", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantPickaxe(f, 7)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 }
	assert(request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre }).Ok)
	for _ = 1, 5 do
		f.Advance(1)
		assert(request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre }).Ok)
	end
	-- Exactly 5 real seconds passed in total, whether settled by the heartbeat or by each
	-- replacing Begin -- replacing the session 5 times never creates more than that.
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, 5)
end)

test("gathering re-validates the node on every periodic settlement; moving out of range fails closed and clears the session", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantPickaxe(f, 7)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 }
	assert(request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre }).Ok)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 999 }
	f.Advance(5) -- the next heartbeat tick re-validates, fails, and clears the session
	local ended = request(f, 7, RequestIds.GatheringEnd, {})
	equal(ended.Ok, false)
	equal(ended.Reason, "NoActiveGatheringSession")
end)

test("long active sessions settle incrementally; a mid-session range loss is never retroactively recovered and total credited time never exceeds real elapsed time", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantPickaxe(f, 7)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 }
	assert(request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre }).Ok)
	f.Advance(5) -- five separate 1-second heartbeat ticks, settled incrementally
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, 5)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 999 } -- moves out of range
	f.Advance(5) -- the session is rejected and cleared on the very next tick; nothing more accrues
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, 5)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 } -- back in range
	f.Advance(5) -- but the session is gone; nothing is retroactively recovered
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, 5)
end)

test("leaving clears the active gathering session", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantPickaxe(f, 7)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 }
	assert(request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre }).Ok)
	leavePlayer(f, 7)
	joinPlayer(f, 7)
	local ended = request(f, 7, RequestIds.GatheringEnd, {})
	equal(ended.Ok, false)
end)

-- ===== Plot training timing =====

test("Training Begin validates the station without awarding any XP; zero elapsed after Begin awards nothing", function()
	local f = fixture()
	joinPlayer(f, 7)
	local began = request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" })
	assert(began.Ok, began.Reason)
	equal(began.Result.StationId, "station_training_melee")
	equal(began.Result.Tier, 1)
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 0)
	local stopped = request(f, 7, RequestIds.TrainingEnd, {})
	equal(stopped.Ok, false)
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 0)
end)

test("Training Begin plus 5 real elapsed seconds credits exactly 5 seconds of XP at the current tier rate", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" }).Ok)
	f.Advance(5)
	request(f, 7, RequestIds.TrainingEnd, {})
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 5)
end)

test("Training sessions settle incrementally via the periodic heartbeat, not only at Stop", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" }).Ok)
	f.Advance(3)
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 3)
	f.Advance(2)
	request(f, 7, RequestIds.TrainingEnd, {})
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 5)
end)

test("upgrading a station changes the rate a later training session actually uses", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(f.Composition.Services.Economy.CreditGold(7, 100))
	assert(request(f, 7, RequestIds.PlotUpgradeStation, { StationId = "station_training_melee" }).Ok)
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" }).Ok)
	f.Advance(4)
	request(f, 7, RequestIds.TrainingEnd, {})
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 8)
end)

test("repeatedly calling Training Begin without advancing the clock never creates XP", function()
	local f = fixture()
	joinPlayer(f, 7)
	for _ = 1, 5 do
		request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" })
	end
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 0)
end)

test("repeatedly replacing a Training session cannot manufacture bonus seconds beyond real elapsed time", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" }).Ok)
	for _ = 1, 5 do
		f.Advance(1)
		assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" }).Ok)
	end
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 5)
end)

test("simultaneous incompatible training sessions are not allowed", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" }).Ok)
	f.Advance(3)
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_defense" }).Ok)
	f.Advance(2)
	request(f, 7, RequestIds.TrainingEnd, {})
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 3)
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Defense)).XP, 2)
end)

test("leaving clears the active training session", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" }).Ok)
	leavePlayer(f, 7)
	joinPlayer(f, 7)
	local ended = request(f, 7, RequestIds.TrainingEnd, {})
	equal(ended.Ok, false)
end)

-- ===== Physical proximity authority (Training / station upgrade / Forge) =====

test("Training Begin is server-gated on physical station proximity: too far is rejected, then near succeeds", function()
	local f = fixture()
	joinPlayer(f, 7)
	f.StationDistances["station_training_melee"] = 999
	local far = request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" })
	equal(far.Ok, false)
	equal(far.Reason, "TooFarFromStation")
	f.Advance(1)
	f.StationDistances["station_training_melee"] = 0
	local near = request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" })
	assert(near.Ok, near.Reason)
end)

test("an active training session stops on the next settlement when the player leaves the station, and the absent interval is never credited", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" }).Ok)
	f.Advance(3) -- three at-station seconds credited
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 3)
	f.StationDistances["station_training_melee"] = 999 -- walk away
	f.Advance(5) -- the next heartbeat tick revalidates proximity, fails closed, and clears the session
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 3) -- absent time not credited
	f.StationDistances["station_training_melee"] = 0 -- return to the station
	f.Advance(5) -- but the session is gone; nothing is retroactively recovered
	equal(assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee)).XP, 3)
	local ended = request(f, 7, RequestIds.TrainingEnd, {})
	equal(ended.Ok, false)
end)

test("station upgrade is server-gated on physical station proximity", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(f.Composition.Services.Economy.CreditGold(7, 100))
	f.StationDistances["station_training_melee"] = 999
	local far = request(f, 7, RequestIds.PlotUpgradeStation, { StationId = "station_training_melee" })
	equal(far.Ok, false)
	equal(far.Reason, "TooFarFromStation")
	f.Advance(1)
	f.StationDistances["station_training_melee"] = 0
	local near = request(f, 7, RequestIds.PlotUpgradeStation, { StationId = "station_training_melee" })
	assert(near.Ok, near.Reason)
	equal(near.Result.Tier, 2)
end)

test("Forge crafting is server-gated on physical Forge proximity", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(f.Composition.Services.Inventory.AddStack(7, "item_iron_ore", 4))
	f.ForgeDistance.Value = 999
	local far = request(f, 7, RequestIds.CraftingCraft, { RecipeId = "recipe_iron_bar" })
	equal(far.Ok, false)
	equal(far.Reason, "TooFarFromForge")
	f.Advance(1)
	f.ForgeDistance.Value = 0
	local near = request(f, 7, RequestIds.CraftingCraft, { RecipeId = "recipe_iron_bar" })
	assert(near.Ok, near.Reason)
end)

-- ===== Economy / Equipment / Crafting / Mastery / Ascension routing =====

test("Equipment: a valid Equip succeeds; an invalid slot fails", function()
	local f = fixture()
	joinPlayer(f, 7)
	local instanceId = assert(f.Composition.Services.Inventory.AddDiscreteItem(7, "weapon_sword_starter")).InstanceId
	local ok = request(f, 7, RequestIds.EquipmentEquip, { SlotId = EquipmentSlots.Weapon, InstanceId = instanceId })
	assert(ok.Ok, ok.Reason)
	f.Advance(1)
	local bad = request(f, 7, RequestIds.EquipmentEquip, { SlotId = "not_a_slot", InstanceId = instanceId })
	equal(bad.Ok, false)
end)

test("Economy: a valid purchase succeeds; an unaffordable one fails", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(f.Composition.Services.Economy.CreditGold(7, 10))
	local ok = request(f, 7, RequestIds.EconomyPurchaseStack, { CatalogId = "shop_hub", DefinitionId = "item_iron_ore", Amount = 1 })
	assert(ok.Ok, ok.Reason)
	f.Advance(1)
	local fail = request(f, 7, RequestIds.EconomyPurchaseStack, { CatalogId = "shop_hub", DefinitionId = "item_iron_ore", Amount = 999999 })
	equal(fail.Ok, false)
end)

test("Crafting: a valid recipe craft succeeds; an unknown recipe fails", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(f.Composition.Services.Inventory.AddStack(7, "item_iron_ore", 2))
	local ok = request(f, 7, RequestIds.CraftingCraft, { RecipeId = "recipe_iron_bar" })
	assert(ok.Ok, ok.Reason)
	f.Advance(1)
	local fail = request(f, 7, RequestIds.CraftingCraft, { RecipeId = "recipe_unknown" })
	equal(fail.Ok, false)
end)

test("Mastery: a valid node selection succeeds; an unmet node fails", function()
	local f = fixture()
	joinPlayer(f, 7)
	setSkillLevel(f, 7, SkillIds.Melee, 5)
	local firstNode = MasteryIds.Nodes.MeleeMight[1]
	local ok = request(f, 7, RequestIds.MasterySelectNode, { SkillId = SkillIds.Melee, NodeId = firstNode })
	assert(ok.Ok, ok.Reason)
	f.Advance(1)
	local secondNode = MasteryIds.Nodes.MeleeMight[2]
	local fail = request(f, 7, RequestIds.MasterySelectNode, { SkillId = SkillIds.Melee, NodeId = secondNode })
	equal(fail.Ok, false)
end)

test("Ascension: Ascend fails until requirements are met, then succeeds", function()
	local f = fixture()
	joinPlayer(f, 7)
	local fail = request(f, 7, RequestIds.AscensionAscend, { RankId = AscensionIds.Adept })
	equal(fail.Ok, false)
	setSkillLevel(f, 7, SkillIds.Melee, 8)
	setSkillLevel(f, 7, SkillIds.Defense, 5)
	setSkillLevel(f, 7, SkillIds.Mining, 2)
	setSkillLevel(f, 7, SkillIds.Smithing, 2)
	assert(f.PlayerData.Update(7, function(data)
		data.ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated] = true
	end))
	f.Advance(1)
	local ok = request(f, 7, RequestIds.AscensionAscend, { RankId = AscensionIds.Adept })
	assert(ok.Ok, ok.Reason)
end)

-- ===== State read model =====

test("the state read model contains the intended player-facing data and omits internal session/save metadata", function()
	local f = fixture()
	joinPlayer(f, 7)
	local state = assert(request(f, 7, RequestIds.StateGet, {}).Result)
	assert(state.Gold ~= nil)
	assert(state.Skills[SkillIds.Melee] ~= nil)
	assert(state.Inventory ~= nil)
	assert(state.Equipment ~= nil)
	assert(state.PlotStations["station_training_melee"] ~= nil)
	assert(state.Mastery[SkillIds.Melee] ~= nil)
	assert(state.Ascension.RankId ~= nil)
	assert(state.Ascension.AdeptProgress ~= nil)
	assert(state.Health ~= nil and state.Health.Health ~= nil and state.Health.MaxHealth ~= nil)
	equal(state.OfflineFocusSkillId, nil)
	equal((state :: any).SchemaVersion, nil)
	equal((state :: any).LastSessionAt, nil)
end)

test("returned read-model tables are copy-isolated", function()
	local f = fixture()
	joinPlayer(f, 7)
	local first = assert(request(f, 7, RequestIds.StateGet, {}).Result)
	first.Gold = 999999
	first.Skills[SkillIds.Melee].XP = 999999
	f.Advance(1)
	local second = assert(request(f, 7, RequestIds.StateGet, {}).Result)
	assert(second.Gold ~= 999999)
	assert(second.Skills[SkillIds.Melee].XP ~= 999999)
end)

print(("%d Composition checks passed"):format(passed))
