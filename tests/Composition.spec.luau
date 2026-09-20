--!strict

local SkillIds = require("SkillIds")
local EquipmentSlots = require("EquipmentSlots")
local EnemyIds = require("EnemyIds")
local GatheringNodeIds = require("GatheringNodeIds")
local AscensionIds = require("AscensionIds")
local ProgressionFlagIds = require("ProgressionFlagIds")
local MasteryIds = require("MasteryIds")
local EventIds = require("EventIds")
local OnboardingDefinitions = require("OnboardingDefinitions")
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

	local roll01 = { Value = 0 }
	local instanceSerial = 0
	local runtimeSerial = 0
	-- Records every pushed server -> client presentation event by userId, so tests can assert exactly
	-- what each player receives. Setting playerEventTransportFails models a transport that throws.
	local playerEventLog: { [number]: { { EventId: string, Payload: any } } } = {}
	local playerEventTransportFails = { Value = false }
	local composition = Composition.New(playerData, {
		Clock = monotonicClock,
		Now = wallNow,
		NewInstanceId = function() instanceSerial += 1; return "instance_" .. instanceSerial end,
		NewRuntimeId = function() runtimeSerial += 1; return "runtime_" .. runtimeSerial end,
		RollInteger = function(minimum: number, _maximum: number) return minimum end,
		Roll01 = function() return roll01.Value end,
		Warn = function(message) table.insert(warnings, message) end,
		Spawn = spawn,
		Wait = coroutine.yield,
		SendPlayerEvent = function(userId: number, eventId: string, payload: any)
			if playerEventTransportFails.Value then
				error("PlayerEvent transport unavailable", 0)
			end
			local list = playerEventLog[userId]
			if not list then
				list = {}
				playerEventLog[userId] = list
			end
			table.insert(list, { EventId = eventId, Payload = payload })
		end,
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
	f.Roll01 = roll01
	f.PlayerEvents = playerEventLog
	f.PlayerEventTransportFails = playerEventTransportFails

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

test("offline focus selection is player-driven and reflected in the read model (Melee/Defense, switchable, unsupported rejected)", function()
	-- The client's focus display and switch read/write exactly this contract: OfflineFocusSkillId in
	-- the read model, set via the OfflineTrainingSetFocus request. No focus is ever inferred.
	local f = fixture()
	joinPlayer(f, 7)
	-- Fresh player: nothing is chosen for them, so the read model reports no focus.
	equal(assert(request(f, 7, RequestIds.StateGet, nil).Result).OfflineFocusSkillId, nil)
	-- Explicitly selecting Melee is honored.
	assert(request(f, 7, RequestIds.OfflineTrainingSetFocus, { SkillId = SkillIds.Melee }).Ok)
	f.Advance(1) -- space out the repeated StateGet past the per-request throttle
	equal(assert(request(f, 7, RequestIds.StateGet, nil).Result).OfflineFocusSkillId, SkillIds.Melee)
	-- Switching to Defense updates it.
	assert(request(f, 7, RequestIds.OfflineTrainingSetFocus, { SkillId = SkillIds.Defense }).Ok)
	f.Advance(1)
	equal(assert(request(f, 7, RequestIds.StateGet, nil).Result).OfflineFocusSkillId, SkillIds.Defense)
	-- An unsupported skill is rejected and never becomes the focus.
	local rejected = request(f, 7, RequestIds.OfflineTrainingSetFocus, { SkillId = SkillIds.Mining })
	equal(rejected.Ok, false)
	f.Advance(1)
	equal(assert(request(f, 7, RequestIds.StateGet, nil).Result).OfflineFocusSkillId, SkillIds.Defense)
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

-- ===== Mastery effect integration (end-to-end through the composed stack) =====
-- Prove the real composition actually wires Mastery.GetModifiers into the consuming systems, not just
-- that each service applies an injected double.

test("selecting a Melee Might node raises real attack damage through the composed stack", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	setSkillLevel(f, 7, SkillIds.Melee, 5) -- earns 1 Mastery point; Might I requires level 5
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	f.CombatDistances[enemy.RuntimeId] = 1
	local base = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
	assert(base.Ok, base.Reason)
	equal(base.Result.AppliedDamage, 10) -- starter sword base before any Mastery
	f.Advance(2) -- clear the attack cooldown
	local select = request(f, 7, RequestIds.MasterySelectNode, { SkillId = SkillIds.Melee, NodeId = MasteryIds.Nodes.MeleeMight[1] })
	assert(select.Ok, select.Reason)
	local boosted = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
	assert(boosted.Ok, boosted.Reason)
	-- +2% MeleeDamageBonus from the one selected node (10 -> 10.2), applied by the real provider.
	assert(boosted.Result.AppliedDamage > 10 and boosted.Result.AppliedDamage < 10.5, "expected a small damage increase, got " .. tostring(boosted.Result.AppliedDamage))
end)

test("selecting a Defense Fortitude node raises the composed player's maximum health", function()
	local f = fixture()
	joinPlayer(f, 7)
	setSkillLevel(f, 7, SkillIds.Defense, 5)
	local before = request(f, 7, RequestIds.StateGet, nil)
	assert(before.Ok, before.Reason)
	equal(before.Result.Health.MaxHealth, 100)
	local select = request(f, 7, RequestIds.MasterySelectNode, { SkillId = SkillIds.Defense, NodeId = MasteryIds.Nodes.DefenseFortitude[1] })
	assert(select.Ok, select.Reason)
	f.Advance(1) -- clear the per-request throttle before the second StateGet
	local after = request(f, 7, RequestIds.StateGet, nil)
	assert(after.Ok, after.Reason)
	equal(after.Result.Health.MaxHealth, 102) -- floor(100 * 1.02 + 0.5)
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

-- ===== Boss personal-reward events (server -> client presentation channel) =====

local function hitBoss(f, userId: number, runtimeId: string, times: number)
	for _ = 1, times do
		local r = request(f, userId, RequestIds.CombatMeleeAttack, { TargetId = runtimeId })
		assert(r.Ok, r.Reason)
		f.Advance(2) -- clear the weapon cooldown and the per-request throttle before the next hit
	end
end
local function onlyBossEvent(f, userId: number)
	local list = f.PlayerEvents[userId]
	assert(list ~= nil, "expected a personal-reward event for user " .. tostring(userId))
	equal(#list, 1)
	equal(list[1].EventId, EventIds.BossPersonalReward)
	return list[1].Payload
end
local ALLOWED_REWARD_KEYS = { "BossDefinitionId", "Qualified", "RewardGranted", "GoldAwarded", "CommonItemDefinitionId", "CommonItemAmount", "RareItemDefinitionId", "RareItemAmount" }
local function assertOnlyRewardKeys(payload)
	local allow = {}
	for _, key in ALLOWED_REWARD_KEYS do
		allow[key] = true
	end
	for key in payload do
		assert(allow[key], "leaked non-presentation field in reward event: " .. tostring(key))
	end
end

test("each eligible Chieftain participant gets their own sanitized reward; independents, ineligible, and nonparticipants are handled correctly", function()
	local f = fixture()
	f.Roll01.Value = 0 -- 0 < 0.15 rare chance: eligible participants each roll the rare successfully
	for _, uid in { 7, 8, 9, 10 } do
		joinPlayer(f, uid)
		grantWeapon(f, uid)
	end
	local boss = assert(f.Composition.Services.Enemies.Create(EnemyIds.GoblinChieftain))
	f.CombatDistances[boss.RuntimeId] = 1
	-- Chieftain MaxHealth 400, weapon 10 dmg; eligibility threshold = 5% * 400 = 20 (two hits).
	hitBoss(f, 9, boss.RuntimeId, 1) -- 10 dmg: participates but below threshold -> ineligible
	hitBoss(f, 7, boss.RuntimeId, 20) -- 200 dmg: eligible
	hitBoss(f, 8, boss.RuntimeId, 19) -- 190 dmg: eligible; 10+200+190 = 400 -> boss dies on this hit

	-- Eligible + granted participant 7: their own event, sanitized, with boss identity, Gold, common + rare.
	local e7 = onlyBossEvent(f, 7)
	equal(e7.BossDefinitionId, EnemyIds.GoblinChieftain)
	equal(e7.Qualified, true)
	equal(e7.RewardGranted, true)
	equal(e7.GoldAwarded, boss.GoldReward)
	equal(e7.CommonItemDefinitionId, "item_iron_bar")
	equal(e7.CommonItemAmount, 1)
	equal(e7.RareItemDefinitionId, "item_chieftain_fang")
	equal(e7.RareItemAmount, 1)
	assertOnlyRewardKeys(e7) -- no contribution map / RNG / PlayerData / FailureReason / internal fields leaked

	-- Independent participant 8 receives only their own result.
	local e8 = onlyBossEvent(f, 8)
	equal(e8.Qualified, true)
	equal(e8.RewardGranted, true)
	equal(e8.RareItemDefinitionId, "item_chieftain_fang")

	-- Ineligible participant 9: Qualified = false AND RewardGranted = false, never a fabricated reward.
	local e9 = onlyBossEvent(f, 9)
	equal(e9.Qualified, false)
	equal(e9.RewardGranted, false)
	equal(e9.GoldAwarded, 0)
	equal(e9.CommonItemDefinitionId, nil)
	equal(e9.RareItemDefinitionId, nil)

	-- Nonparticipant 10 never dealt damage -> no event at all.
	equal(f.PlayerEvents[10], nil)
end)

test("rare-drop absence is represented correctly in the personal-reward event", function()
	local f = fixture()
	f.Roll01.Value = 0.99 -- above the 0.15 rare chance -> no rare
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local boss = assert(f.Composition.Services.Enemies.Create(EnemyIds.GoblinChieftain))
	f.CombatDistances[boss.RuntimeId] = 1
	hitBoss(f, 7, boss.RuntimeId, 40) -- solo kill, eligible
	local e = onlyBossEvent(f, 7)
	equal(e.Qualified, true)
	equal(e.RewardGranted, true)
	equal(e.CommonItemDefinitionId, "item_iron_bar")
	equal(e.CommonItemAmount, 1)
	equal(e.RareItemDefinitionId, nil)
	equal(e.RareItemAmount, nil)
end)

test("an eligible participant whose atomic reward grant fails emits Qualified = true, RewardGranted = false, with no reward data", function()
	local f = fixture()
	f.Roll01.Value = 0 -- a rare would roll, but the grant fails before anything is credited
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local boss = assert(f.Composition.Services.Enemies.Create(EnemyIds.GoblinChieftain))
	f.CombatDistances[boss.RuntimeId] = 1
	local goldBefore = assert(f.Composition.Services.Economy.GetGold(7))
	hitBoss(f, 7, boss.RuntimeId, 39) -- 390 dmg: past the eligibility threshold, boss still alive (10 HP)
	-- Max out Gold so the boss reward's atomic PlayerData mutation (Gold credit) fails on the kill.
	assert(f.PlayerData.Update(7, function(data) data.Gold = EconomyService.MaximumGold end))
	hitBoss(f, 7, boss.RuntimeId, 1) -- the killing hit; the reward transaction aborts
	local e = onlyBossEvent(f, 7)
	equal(e.Qualified, true) -- they met the contribution threshold
	equal(e.RewardGranted, false) -- but the atomic grant failed
	equal(e.GoldAwarded, 0)
	equal(e.CommonItemDefinitionId, nil)
	equal(e.RareItemDefinitionId, nil)
	assertOnlyRewardKeys(e) -- and the internal FailureReason is never exposed
	-- The failed grant left authoritative state untouched: no common item, and Gold only what was set.
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_bar, nil)
	equal(assert(f.Composition.Services.Economy.GetGold(7)), EconomyService.MaximumGold)
end)

test("a normal Goblin kill emits no boss personal-reward event", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	f.CombatDistances[enemy.RuntimeId] = 1
	hitBoss(f, 7, enemy.RuntimeId, 3) -- Goblin MaxHealth 30 -> three hits kill it
	equal(f.PlayerEvents[7], nil)
end)

test("no client request can manufacture or claim a boss personal-reward event", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	f.CombatDistances[enemy.RuntimeId] = 1
	-- A spoofed payload pretending to carry a boss reward is ignored; only a real boss death emits.
	local spoofed = request(f, 7, RequestIds.CombatMeleeAttack, {
		TargetId = enemy.RuntimeId, BossDefinitionId = EnemyIds.GoblinChieftain,
		GoldAwarded = 999999, Qualified = true, RareItemDefinitionId = "item_chieftain_fang",
	})
	assert(spoofed.Ok, spoofed.Reason)
	equal(f.PlayerEvents[7], nil)
	-- No request id's handler emits on this channel: firing every one with junk never produces an event.
	for _, id in RequestIds do
		if type(id) == "string" then
			request(f, 7, id, {
				TargetId = "nope", SkillId = "nope", NodeId = "nope", StationId = "nope", RecipeId = "nope",
				RankId = "nope", CatalogId = "nope", DefinitionId = "nope", Amount = 1, InstanceId = "nope",
				BossDefinitionId = EnemyIds.GoblinChieftain, Qualified = true, GoldAwarded = 1,
			})
			f.Advance(1)
		end
	end
	equal(f.PlayerEvents[7], nil)
end)

test("a personal-reward event delivery failure never changes or duplicates the authoritative boss reward", function()
	local f = fixture()
	f.Roll01.Value = 0 -- rare granted
	f.PlayerEventTransportFails.Value = true -- the transport throws on every send
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	local boss = assert(f.Composition.Services.Enemies.Create(EnemyIds.GoblinChieftain))
	f.CombatDistances[boss.RuntimeId] = 1
	local goldBefore = assert(f.Composition.Services.Economy.GetGold(7))
	hitBoss(f, 7, boss.RuntimeId, 40) -- solo kill; the killing hit's announce fails delivery
	-- The reward transaction still committed exactly once despite the failed delivery.
	equal(assert(f.Composition.Services.Economy.GetGold(7)), goldBefore + boss.GoldReward)
	local inv = assert(f.Composition.Services.Inventory.GetSnapshot(7))
	equal(inv.Stacks.item_iron_bar, 1)
	equal(inv.Stacks.item_chieftain_fang, 1)
	equal(f.PlayerEvents[7], nil) -- nothing delivered, and nothing duplicated
	-- The dead boss is ineligible for re-resolution, so there is no second reward.
	f.Advance(2)
	local retry = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = boss.RuntimeId })
	equal(retry.Ok, false)
	equal(assert(f.Composition.Services.Economy.GetGold(7)), goldBefore + boss.GoldReward)
end)

test("PlayerEvents keeps Qualified/RewardGranted distinct, enforces the reward invariants, and isolates delivery failures", function()
	local PlayerEvents = require("CompositionPlayerEvents")
	local sent = {}
	local pe = PlayerEvents.New({ Send = function(userId, eventId, payload) table.insert(sent, { UserId = userId, EventId = eventId, Payload = payload }) end })
	-- A well-formed granted reward is sanitized: internal/extra fields dropped, only presentation kept.
	local ok = pe.Emit(7, EventIds.BossPersonalReward, {
		BossDefinitionId = EnemyIds.GoblinChieftain, Qualified = true, RewardGranted = true, GoldAwarded = 50,
		CommonItemDefinitionId = "item_iron_bar", CommonItemAmount = 1,
		RareItemDefinitionId = "item_chieftain_fang", RareItemAmount = 1,
		Contribution = 400, FailureReason = "secret", MilestoneRecorded = true, Extra = {},
	})
	equal(ok, true)
	equal(#sent, 1)
	local p = sent[1].Payload
	equal(p.Qualified, true)
	equal(p.RewardGranted, true)
	equal(p.Contribution, nil)
	equal(p.FailureReason, nil) -- internal failure reason never crosses the boundary
	equal(p.MilestoneRecorded, nil)
	equal(p.Extra, nil)
	equal(p.RareItemAmount, 1)
	-- The two legitimate non-reward states pass and carry no reward data.
	equal(select(1, pe.Emit(7, EventIds.BossPersonalReward, { BossDefinitionId = "b", Qualified = false, RewardGranted = false, GoldAwarded = 0 })), true)
	equal(select(1, pe.Emit(7, EventIds.BossPersonalReward, { BossDefinitionId = "b", Qualified = true, RewardGranted = false, GoldAwarded = 0 })), true)
	local nonRewardCount = #sent
	-- Missing RewardGranted is malformed.
	equal(select(2, pe.Emit(7, EventIds.BossPersonalReward, { BossDefinitionId = "b", Qualified = true, GoldAwarded = 0 })), "InvalidRewardGranted")
	-- A reward granted to a non-qualifier is impossible.
	equal(select(2, pe.Emit(7, EventIds.BossPersonalReward, { BossDefinitionId = "b", Qualified = false, RewardGranted = true, GoldAwarded = 0 })), "GrantedRequiresQualified")
	-- Reward data with RewardGranted = false is rejected (covers both non-qualifiers and failed grants).
	equal(select(2, pe.Emit(7, EventIds.BossPersonalReward, { BossDefinitionId = "b", Qualified = true, RewardGranted = false, GoldAwarded = 100 })), "UngrantedCannotCarryReward")
	equal(select(2, pe.Emit(7, EventIds.BossPersonalReward, { BossDefinitionId = "b", Qualified = true, RewardGranted = false, GoldAwarded = 0, CommonItemDefinitionId = "item_iron_bar", CommonItemAmount = 1 })), "UngrantedCannotCarryReward")
	-- None of those malformed attempts were delivered.
	equal(#sent, nonRewardCount)
	-- Unknown event id and invalid userId are rejected.
	equal(select(1, pe.Emit(7, "not_a_real_event", { X = 1 })), false)
	equal(select(1, pe.Emit(0, EventIds.BossPersonalReward, { BossDefinitionId = "b", Qualified = true, RewardGranted = true, GoldAwarded = 0 })), false)
	-- A throwing transport is contained: Emit reports DeliveryFailed and never propagates.
	local throwing = PlayerEvents.New({ Send = function() error("down", 0) end })
	local okThrow, reason = throwing.Emit(7, EventIds.BossPersonalReward, { BossDefinitionId = "b", Qualified = true, RewardGranted = true, GoldAwarded = 0 })
	equal(okThrow, false)
	equal(reason, "DeliveryFailed")
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

test("a real validation failure clears the Gathering session AND discards its fractional ore carry", function()
	-- Unit-drives the coordinator directly so the carry lifecycle is observable: GatheringIntervalTooShort
	-- retains the session and its carry (unspent time preserved), while a real validation failure tears
	-- the session down through the same Clear path that resets the carry.
	local GatheringSessions = require("CompositionGatheringSessions")
	local now = 0
	local resetCalls = {}
	local nextReason: string? = nil
	local fakeGathering = {
		ValidateForBegin = function()
			return { NodeId = GatheringNodeIds.IronOre }, nil
		end,
		GatherForElapsed = function()
			if nextReason then
				return nil, nextReason
			end
			return { OreAmount = 1 }, nil
		end,
		ResetCarry = function(userId: number)
			table.insert(resetCalls, userId)
		end,
	}
	local coord = GatheringSessions.New(fakeGathering, 60, function()
		return now
	end)
	assert(coord.Begin(7, GatheringNodeIds.IronOre)) -- fresh session resets carry once
	local afterBegin = #resetCalls

	-- Sub-unit interval: session and carry are retained (unspent time kept for the next tick).
	now += 0.1
	nextReason = "GatheringIntervalTooShort"
	equal(select(2, coord.Settle(7)), "GatheringIntervalTooShort")
	equal(#resetCalls, afterBegin) -- carry NOT reset

	-- A real validation failure ends the session and discards the carry via Clear.
	now += 1
	nextReason = "NodeOutOfRange"
	equal(select(2, coord.Settle(7)), "NodeOutOfRange")
	equal(#resetCalls, afterBegin + 1) -- carry reset on failure teardown
	equal(select(2, coord.Settle(7)), "NoActiveGatheringSession") -- session is gone
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

test("batch crafting is reachable through the CraftingCraft request: Craft N and Craft Max are server-authoritative", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(f.Composition.Services.Inventory.AddStack(7, "item_iron_ore", 12))
	-- Craft 5 bars in one authoritative batch: 10 ore -> 5 bars, 2 ore left.
	local craft5 = request(f, 7, RequestIds.CraftingCraft, { RecipeId = "recipe_iron_bar", Quantity = 5 })
	assert(craft5.Ok, craft5.Reason)
	equal(craft5.Result.Quantity, 5)
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_bar, 5)
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, 2)
	-- Craft Max computes the affordable quantity server-side (2 ore -> exactly 1 more bar).
	f.Advance(1)
	local craftMax = request(f, 7, RequestIds.CraftingCraft, { RecipeId = "recipe_iron_bar", Max = true })
	assert(craftMax.Ok, craftMax.Reason)
	equal(craftMax.Result.Quantity, 1)
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_bar, 6)
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, nil)
	-- A client cannot request an invalid quantity; the server rejects it and nothing is crafted.
	f.Advance(1)
	local invalid = request(f, 7, RequestIds.CraftingCraft, { RecipeId = "recipe_iron_bar", Quantity = -3 })
	equal(invalid.Ok, false)
	equal(invalid.Reason, "InvalidQuantity")
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

test("the Mastery UI paths use only the authoritative select/respec requests; the read model carries the outcome the client presents", function()
	-- The client's Skills panel selects and respecs through exactly these requests and then re-reads
	-- state; it never computes points, node states, or respec cost itself.
	local f = fixture()
	joinPlayer(f, 7)
	setSkillLevel(f, 7, SkillIds.Melee, 5) -- earns 1 Mastery point
	local firstNode = MasteryIds.Nodes.MeleeMight[1]
	assert(request(f, 7, RequestIds.MasterySelectNode, { SkillId = SkillIds.Melee, NodeId = firstNode }).Ok)
	f.Advance(1)
	local selected = assert(request(f, 7, RequestIds.StateGet, nil).Result).Mastery[SkillIds.Melee]
	equal(selected.SpentPoints, 1)
	equal(selected.AvailablePoints, 0)
	equal(selected.Branches[1].Nodes[1].Selected, true) -- authoritative node state the client renders
	-- Respec through the authoritative request; the first respec is free.
	f.Advance(1)
	assert(request(f, 7, RequestIds.MasteryRespec, { SkillId = SkillIds.Melee }).Ok)
	f.Advance(1)
	local respecced = assert(request(f, 7, RequestIds.StateGet, nil).Result).Mastery[SkillIds.Melee]
	equal(respecced.SpentPoints, 0)
	equal(respecced.AvailablePoints, 1)
	equal(respecced.Branches[1].Nodes[1].Selected, false)
	equal(respecced.FreeRespecAvailable, false) -- the free respec was consumed; the client presents this
end)

test("shop buy/sell use the server-authoritative catalog price; a client-supplied price/gold field is ignored, and validation cannot be bypassed", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(f.Composition.Services.Economy.CreditGold(7, 100))
	local shop = assert(assert(request(f, 7, RequestIds.StateGet, nil).Result).Shop)
	local oreBuy, oreSell = nil, nil
	for _, entry in shop.Entries do
		if entry.ItemDefinitionId == "item_iron_ore" then
			oreBuy = entry.BuyPrice
			oreSell = entry.SellPrice
		end
	end
	assert(oreBuy ~= nil and oreSell ~= nil)
	-- Buy 2 ore, spoofing a cheap price and huge gold in the payload: the server ignores both and
	-- charges the authoritative catalog price.
	f.Advance(1)
	local goldBefore = assert(f.Composition.Services.Economy.GetGold(7))
	local buy = request(f, 7, RequestIds.EconomyPurchaseStack, { CatalogId = shop.Id, DefinitionId = "item_iron_ore", Amount = 2, Price = 1, Gold = 999999 })
	assert(buy.Ok, buy.Reason)
	equal(assert(f.Composition.Services.Economy.GetGold(7)), goldBefore - oreBuy * 2)
	equal(assert(f.Composition.Services.Inventory.GetSnapshot(7)).Stacks.item_iron_ore, 2)
	-- Sell 1 ore back at the authoritative sell price.
	f.Advance(1)
	local goldBeforeSell = assert(f.Composition.Services.Economy.GetGold(7))
	assert(request(f, 7, RequestIds.EconomySellStack, { CatalogId = shop.Id, DefinitionId = "item_iron_ore", Amount = 1 }).Ok)
	equal(assert(f.Composition.Services.Economy.GetGold(7)), goldBeforeSell + oreSell)
	-- An unaffordable purchase is rejected by server validation; nothing is granted.
	f.Advance(1)
	local tooMuch = request(f, 7, RequestIds.EconomyPurchaseStack, { CatalogId = shop.Id, DefinitionId = "item_iron_ore", Amount = 999999 })
	equal(tooMuch.Ok, false)
end)

test("the Shop UI's discrete sell path uses EconomySellDiscrete: an owned unequipped sword sells at the authoritative price; an equipped item is rejected", function()
	local f = fixture()
	joinPlayer(f, 7)
	local shop = assert(assert(request(f, 7, RequestIds.StateGet, nil).Result).Shop)
	local swordSell = nil
	for _, entry in shop.Entries do
		if entry.ItemDefinitionId == "weapon_sword_upgraded" then
			swordSell = entry.SellPrice
		end
	end
	assert(swordSell ~= nil, "the catalog must list an upgraded-sword sell price")
	-- Give the player an unequipped upgraded sword (a real owned instance; the UI never fabricates one).
	local sword = assert(f.Composition.Services.Inventory.AddDiscreteItem(7, "weapon_sword_upgraded"))
	local goldBefore = assert(f.Composition.Services.Economy.GetGold(7))
	-- Sell it, spoofing a huge price in the payload: the server ignores it and credits the catalog price.
	local sold = request(f, 7, RequestIds.EconomySellDiscrete, { CatalogId = shop.Id, InstanceId = sword.InstanceId, Price = 999999 })
	assert(sold.Ok, sold.Reason)
	equal(assert(f.Composition.Services.Economy.GetGold(7)), goldBefore + swordSell)
	-- The instance is gone; it cannot be sold twice (no fabricated ownership).
	f.Advance(1)
	equal(request(f, 7, RequestIds.EconomySellDiscrete, { CatalogId = shop.Id, InstanceId = sword.InstanceId }).Ok, false)
	-- An equipped item is rejected by the existing server validation.
	local equippedSword = assert(f.Composition.Services.Inventory.AddDiscreteItem(7, "weapon_sword_upgraded"))
	assert(f.Composition.Services.Equipment.Equip(7, EquipmentSlots.Weapon, equippedSword.InstanceId))
	f.Advance(1)
	local equippedSell = request(f, 7, RequestIds.EconomySellDiscrete, { CatalogId = shop.Id, InstanceId = equippedSword.InstanceId })
	equal(equippedSell.Ok, false)
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
	assert(state.Shop ~= nil and state.Shop.Id == "shop_hub" and type(state.Shop.Entries) == "table")
	assert(type(state.Recipes) == "table" and #state.Recipes > 0)
	equal(state.OfflineFocusSkillId, nil)
	equal((state :: any).SchemaVersion, nil)
	equal((state :: any).LastSessionAt, nil)
end)

test("the read model surfaces sanitized Smithing recipe requirements for the Forge panel", function()
	local CraftingDefinitions = require("CraftingDefinitions")
	local f = fixture()
	joinPlayer(f, 7)
	local recipes = assert(assert(request(f, 7, RequestIds.StateGet, {}).Result).Recipes)
	local ironBar = nil
	for _, recipe in recipes do
		if recipe.RecipeId == "recipe_iron_bar" then
			ironBar = recipe
		end
	end
	assert(ironBar ~= nil, "the iron bar recipe must be surfaced")
	local source = CraftingDefinitions.ById.recipe_iron_bar
	equal(ironBar.OutputItemId, source.OutputItemId)
	equal(ironBar.OutputAmount, source.OutputAmount)
	equal(ironBar.RequiredSmithingLevel, source.RequiredSmithingLevel)
	equal(ironBar.SmithingXP, source.SmithingXP)
	equal(ironBar.Inputs[1].ItemDefinitionId, source.Inputs[1].ItemDefinitionId)
	equal(ironBar.Inputs[1].Amount, source.Inputs[1].Amount)
	-- Only presentation keys are surfaced (no internal recipe fields like DurationSeconds).
	for key in ironBar do
		assert(
			key == "RecipeId" or key == "OutputItemId" or key == "OutputAmount" or key == "RequiredSmithingLevel" or key == "SmithingXP" or key == "Inputs",
			"leaked recipe field: " .. tostring(key)
		)
	end
end)

test("the read model surfaces the hub shop's authoritative prices (sanitized) without duplicating catalog internals", function()
	local ShopCatalog = require("ShopCatalog")
	local f = fixture()
	joinPlayer(f, 7)
	local shop = assert(assert(request(f, 7, RequestIds.StateGet, {}).Result).Shop)
	equal(shop.Id, "shop_hub")
	-- Every surfaced entry mirrors the server catalog's own prices exactly, and only id + buy/sell.
	local catalog = ShopCatalog.ById.shop_hub
	local seen = 0
	for _, entry in shop.Entries do
		seen += 1
		local source = catalog.Entries[entry.ItemDefinitionId]
		assert(source ~= nil, "surfaced a non-catalog item: " .. tostring(entry.ItemDefinitionId))
		equal(entry.BuyPrice, source.BuyPrice)
		equal(entry.SellPrice, source.SellPrice)
		for key in entry do
			assert(key == "ItemDefinitionId" or key == "BuyPrice" or key == "SellPrice", "leaked catalog field: " .. tostring(key))
		end
	end
	-- Iron Ore is buyable and sellable; the client presents these but never prices anything itself.
	local ore = nil
	for _, entry in shop.Entries do
		if entry.ItemDefinitionId == "item_iron_ore" then
			ore = entry
		end
	end
	assert(ore ~= nil and ore.BuyPrice ~= nil and ore.SellPrice ~= nil)
	assert(seen > 0)
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

-- ===== Onboarding guidance (end-to-end through the real request boundary + read model) =====
local Steps = OnboardingDefinitions.StepIds
local function onboarding(f, userId)
	-- Nudge the monotonic clock past the per-request throttle so repeated reads in one test are served.
	f.Advance(0.1)
	local res = request(f, userId, RequestIds.StateGet, {})
	assert(res.Ok, "StateGet failed: " .. tostring(res.Reason))
	return res.Result.Onboarding
end

test("onboarding: a fresh player's read model begins at the starter-focus step", function()
	local f = fixture()
	joinPlayer(f, 7)
	local ob = onboarding(f, 7)
	equal(ob.Complete, false)
	equal(ob.StepId, Steps.StarterFocus)
	equal(ob.Index, 1)
end)

test("onboarding: acknowledging the starter focus advances to Train Melee via the intended request", function()
	local f = fixture()
	joinPlayer(f, 7)
	local ack = request(f, 7, RequestIds.OnboardingAcknowledgeStarterFocus, nil)
	assert(ack.Ok, ack.Reason)
	equal(onboarding(f, 7).StepId, Steps.TrainMelee)
end)

test("onboarding: the post-training Gold reward is granted exactly once through the request path", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.OnboardingAcknowledgeStarterFocus, nil).Ok)
	setSkillLevel(f, 7, SkillIds.Melee, 2)
	setSkillLevel(f, 7, SkillIds.Defense, 2)
	local before = assert(f.Composition.Services.Economy.GetGold(7))
	-- The reconcile runs on the next request (StateGet), granting the one-time reward and advancing.
	local ob = onboarding(f, 7)
	equal(assert(f.Composition.Services.Economy.GetGold(7)), before + OnboardingDefinitions.TrainingRewardGold)
	equal(ob.StepId, Steps.FightGoblins)
	-- Further requests never re-grant it.
	onboarding(f, 7)
	onboarding(f, 7)
	equal(assert(f.Composition.Services.Economy.GetGold(7)), before + OnboardingDefinitions.TrainingRewardGold)
end)

test("onboarding: an actual Goblin defeat advances the fight step; a mere hit does not", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantWeapon(f, 7)
	assert(request(f, 7, RequestIds.OnboardingAcknowledgeStarterFocus, nil).Ok)
	setSkillLevel(f, 7, SkillIds.Melee, 2)
	setSkillLevel(f, 7, SkillIds.Defense, 2)
	equal(onboarding(f, 7).StepId, Steps.FightGoblins)
	local enemy = assert(f.Composition.Services.Enemies.Create(EnemyIds.Goblin))
	f.CombatDistances[enemy.RuntimeId] = 1
	-- One non-lethal hit (MaxHealth 30, weapon damage 10): the milestone must NOT latch.
	assert(request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId }).Ok)
	f.Advance(2)
	equal(onboarding(f, 7).StepId, Steps.FightGoblins)
	-- Finish it (two more hits): the consumed death records the milestone and advances to Earn Gold.
	for _ = 1, 2 do
		assert(request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId }).Ok)
		f.Advance(2)
	end
	equal(onboarding(f, 7).StepId, Steps.EarnGold)
end)

test("onboarding: progress survives disconnect/reconnect and resumes at the correct step", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.OnboardingAcknowledgeStarterFocus, nil).Ok)
	setSkillLevel(f, 7, SkillIds.Melee, 2)
	setSkillLevel(f, 7, SkillIds.Defense, 2)
	equal(onboarding(f, 7).StepId, Steps.FightGoblins)
	leavePlayer(f, 7)
	assert(joinPlayer(f, 7))
	equal(onboarding(f, 7).StepId, Steps.FightGoblins)
end)

test("onboarding: a client cannot skip steps or fabricate Gold via an unknown or spoofed request", function()
	local f = fixture()
	joinPlayer(f, 7)
	-- No request exists to mark a step complete or set a flag; an unknown id is rejected.
	local spoof = request(f, 7, "onboarding_force_complete", { StepId = Steps.AscendAdept })
	equal(spoof.Ok, false)
	equal(spoof.Reason, "UnknownRequest")
	-- The acknowledge request ignores any payload and only sets the one flag -- one step, no Gold.
	assert(request(f, 7, RequestIds.OnboardingAcknowledgeStarterFocus, { StepId = Steps.AscendAdept, Gold = 9999 }).Ok)
	equal(onboarding(f, 7).StepId, Steps.TrainMelee)
	equal(assert(f.Composition.Services.Economy.GetGold(7)), 0)
end)

print(("%d Composition checks passed"):format(passed))
