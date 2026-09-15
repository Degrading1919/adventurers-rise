--!strict

local SkillIds = require("SkillIds")
local EquipmentSlots = require("EquipmentSlots")
local EnemyIds = require("EnemyIds")
local GatheringNodeIds = require("GatheringNodeIds")
local AscensionIds = require("AscensionIds")
local ProgressionFlagIds = require("ProgressionFlagIds")
local MasteryIds = require("MasteryIds")
local SkillCurves = require("SkillCurves")
local PlayerDataSchema = require("PlayerDataSchema")
local PlayerDataStore = require("PlayerDataStore")
local PlayerDataService = require("PlayerDataService")
local RequestIds = require("CompositionRequestIds")
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

-- Builds one complete composed vertical-slice stack against a real (faked-DataStore) PlayerData
-- Store/Service, with configurable fake world adapters standing in for the Studio scene.
local function fixture()
	local f = { Time = 1000, Serial = 0, Records = {}, Failures = 0 }
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
	local backend = PlayerDataStore.New(f, {
		Now = function() return math.floor(f.Time) end,
		Sleep = function(seconds) f.Time += seconds end,
		NewToken = function() f.Serial += 1; return "token_" .. f.Serial end,
	})

	local function spawn(fn, ...)
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread, ...)
		assert(ok, err)
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
		-- Must actually yield: PlayerData.Service.Start's autosave loop calls this in a `while not
		-- stopping do` loop, and every spawned coroutine here runs to completion synchronously
		-- (see `spawn` above). A no-op Wait would spin that loop forever instead of parking it.
		Wait = coroutine.yield,
		Clock = function() return f.Time end,
		Now = function() return math.floor(f.Time) end,
		BindToClose = function() end,
		Warn = function(message) table.insert(warnings, message) end,
	})

	-- Fake world adapters: tests configure these per runtimeId/nodeId; unconfigured entries fail
	-- closed exactly like the real placeholder adapters, without fabricating a target/node.
	local combatDistances: { [string]: number } = {}
	local gatheringNodes: { [string]: { Eligible: boolean, Distance: number } } = {}
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
	}

	local roll01Value = 0
	local instanceSerial = 0
	local runtimeSerial = 0
	local composition = Composition.New(playerData, {
		Clock = function() return f.Time end,
		NewInstanceId = function() instanceSerial += 1; return "instance_" .. instanceSerial end,
		NewRuntimeId = function() runtimeSerial += 1; return "runtime_" .. runtimeSerial end,
		RollInteger = function(minimum: number, _maximum: number) return minimum end,
		Roll01 = function() return roll01Value end,
		Warn = function(message) table.insert(warnings, message) end,
	}, worldAdapters)

	playerData.Start()
	composition.Start()

	-- Augment the same fake-DataStore table (it already carries the mutable .Time clock every
	-- closure above captured by reference) rather than wrapping it, so `f.Time += N` in tests
	-- actually advances the one clock everything reads.
	f.PlayerData = playerData
	f.Players = players
	f.Composition = composition
	f.CombatDistances = combatDistances
	f.GatheringNodes = gatheringNodes
	f.Warnings = warnings
	return f
end

-- PlayerData only Releases a session when PlayerRemoving fires the SAME Player object instance
-- that PlayerAdded reported (real Roblox Player objects persist identity for the connection's
-- whole lifetime); this cache is what makes leavePlayer below match join for the same user.
local playerObjects: { [any]: { [number]: any } } = setmetatable({}, { __mode = "k" })

local function joinPlayer(f, userId: number): boolean
	local objects = playerObjects[f]
	if not objects then
		objects = {}
		playerObjects[f] = objects
	end
	local player = fakePlayer(userId)
	objects[userId] = player
	f.Players.PlayerAdded:Fire(player)
	return f.Composition.IsGameplayReady(userId)
end

local function leavePlayer(f, userId: number)
	local objects = playerObjects[f]
	local player = objects and objects[userId]
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
	f.Time += 3600
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
	f.Time += 3600
	joinPlayer(f, 7)
	local first = assert(request(f, 7, RequestIds.StateGet, {}).Result)
	f.Time += 1
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
		f.Time += 1
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
		f.Time += 2
	end
	local afterKill = assert(f.Composition.Services.Economy.GetGold(7))
	equal(afterKill, before + enemy.GoldReward)
	-- A dead target becomes ineligible; there is no retry path that could pay a second time.
	local retry = request(f, 7, RequestIds.CombatMeleeAttack, { TargetId = enemy.RuntimeId })
	equal(retry.Ok, false)
	local afterRetry = assert(f.Composition.Services.Economy.GetGold(7))
	equal(afterRetry, afterKill)
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
		f.Time += 2
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

test("gathering begins through the trusted world-adapter resolver and derives elapsed from the server clock, never a client value", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantPickaxe(f, 7)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 }
	local began = request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre, ElapsedSeconds = 999999 })
	assert(began.Ok, began.Reason)
	equal(began.Result.OreAmount, 1)
	f.Time += 5
	local ended = request(f, 7, RequestIds.GatheringEnd, { ElapsedSeconds = 999999 })
	assert(ended.Ok, ended.Reason)
	equal(ended.Result.OreAmount, 5)
	local inventory = assert(f.Composition.Services.Inventory.GetSnapshot(7))
	equal(inventory.Stacks.item_iron_ore, 6)
end)

test("gathering re-validates the node on settlement; moving out of range fails closed and clears the session", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantPickaxe(f, 7)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 }
	assert(request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre }).Ok)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 999 }
	f.Time += 5
	local ended = request(f, 7, RequestIds.GatheringEnd, {})
	equal(ended.Ok, false)
	f.Time += 1
	local secondEnd = request(f, 7, RequestIds.GatheringEnd, {})
	equal(secondEnd.Ok, false)
	equal(secondEnd.Reason, "NoActiveGatheringSession")
end)

test("starting a new gathering session safely settles and replaces the previous one", function()
	local f = fixture()
	joinPlayer(f, 7)
	grantPickaxe(f, 7)
	f.GatheringNodes[GatheringNodeIds.IronOre] = { Eligible = true, Distance = 1 }
	assert(request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre }).Ok)
	f.Time += 4
	assert(request(f, 7, RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre }).Ok)
	local inventory = assert(f.Composition.Services.Inventory.GetSnapshot(7))
	equal(inventory.Stacks.item_iron_ore, 6)
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

test("training begins with a stable station ID and derives elapsed from the server clock, never a client value", function()
	local f = fixture()
	joinPlayer(f, 7)
	local began = request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee", ElapsedSeconds = 999999 })
	assert(began.Ok, began.Reason)
	f.Time += 5
	local ended = request(f, 7, RequestIds.TrainingEnd, { ElapsedSeconds = 999999 })
	assert(ended.Ok, ended.Reason)
	local state = assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee))
	equal(state.XP, 6)
end)

test("upgrading a station changes the rate a later training session actually uses", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(f.Composition.Services.Economy.CreditGold(7, 100))
	assert(request(f, 7, RequestIds.PlotUpgradeStation, { StationId = "station_training_melee" }).Ok)
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" }).Ok)
	f.Time += 4
	assert(request(f, 7, RequestIds.TrainingEnd, {}).Ok)
	local state = assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee))
	equal(state.XP, 10)
end)

test("simultaneous incompatible training sessions are not allowed", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_melee" }).Ok)
	f.Time += 3
	assert(request(f, 7, RequestIds.TrainingBegin, { StationId = "station_training_defense" }).Ok)
	f.Time += 2
	assert(request(f, 7, RequestIds.TrainingEnd, {}).Ok)
	local melee = assert(f.Composition.Services.Skills.GetState(7, SkillIds.Melee))
	local defense = assert(f.Composition.Services.Skills.GetState(7, SkillIds.Defense))
	equal(melee.XP, 4)
	equal(defense.XP, 3)
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

-- ===== Economy / Equipment / Crafting / Mastery / Ascension routing =====

test("Equipment: a valid Equip succeeds; an invalid slot fails", function()
	local f = fixture()
	joinPlayer(f, 7)
	local instanceId = assert(f.Composition.Services.Inventory.AddDiscreteItem(7, "weapon_sword_starter")).InstanceId
	local ok = request(f, 7, RequestIds.EquipmentEquip, { SlotId = EquipmentSlots.Weapon, InstanceId = instanceId })
	assert(ok.Ok, ok.Reason)
	f.Time += 1
	local bad = request(f, 7, RequestIds.EquipmentEquip, { SlotId = "not_a_slot", InstanceId = instanceId })
	equal(bad.Ok, false)
end)

test("Economy: a valid purchase succeeds; an unaffordable one fails", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(f.Composition.Services.Economy.CreditGold(7, 10))
	local ok = request(f, 7, RequestIds.EconomyPurchaseStack, { CatalogId = "shop_hub", DefinitionId = "item_iron_ore", Amount = 1 })
	assert(ok.Ok, ok.Reason)
	f.Time += 1
	local fail = request(f, 7, RequestIds.EconomyPurchaseStack, { CatalogId = "shop_hub", DefinitionId = "item_iron_ore", Amount = 999999 })
	equal(fail.Ok, false)
end)

test("Crafting: a valid recipe craft succeeds; an unknown recipe fails", function()
	local f = fixture()
	joinPlayer(f, 7)
	assert(f.Composition.Services.Inventory.AddStack(7, "item_iron_ore", 2))
	local ok = request(f, 7, RequestIds.CraftingCraft, { RecipeId = "recipe_iron_bar" })
	assert(ok.Ok, ok.Reason)
	f.Time += 1
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
	f.Time += 1
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
	f.Time += 1
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
	f.Time += 1
	local second = assert(request(f, 7, RequestIds.StateGet, {}).Result)
	assert(second.Gold ~= 999999)
	assert(second.Skills[SkillIds.Melee].XP ~= 999999)
end)

print(("%d Composition checks passed"):format(passed))
