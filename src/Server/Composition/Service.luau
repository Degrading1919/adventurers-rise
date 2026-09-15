--!strict

-- The one repository-owned composition root for the vertical slice: constructs every backend
-- service in dependency order, wires the PlayerData-ready lifecycle (including the automatic
-- offline-return claim), and exposes one small trusted request boundary plus a read model.
-- Plain explicit construction -- no service locator, no dependency-injection framework.

local SkillCurves = require(script.Parent.Parent.Skills.Curves)
local SkillsService = require(script.Parent.Parent.Skills.Service)
local InventoryService = require(script.Parent.Parent.Inventory.Service)
local EquipmentService = require(script.Parent.Parent.Equipment.Service)
local EconomyService = require(script.Parent.Parent.Economy.Service)
local PlotsService = require(script.Parent.Parent.Plots.Service)
local EnemiesService = require(script.Parent.Parent.Enemies.Service)
local CombatService = require(script.Parent.Parent.Combat.Service)
local GatheringService = require(script.Parent.Parent.Gathering.Service)
local CraftingService = require(script.Parent.Parent.Crafting.Service)
local BossesService = require(script.Parent.Parent.Bosses.Service)
local AscensionService = require(script.Parent.Parent.Ascension.Service)
local MasteryService = require(script.Parent.Parent.Mastery.Service)
local OfflineTrainingService = require(script.Parent.Parent.OfflineTraining.Service)

local RequestIds = require(script.Parent.RequestIds)
local GatheringSessions = require(script.Parent.GatheringSessions)
local TrainingSessions = require(script.Parent.TrainingSessions)
local CombatRewards = require(script.Parent.CombatRewards)
local ReadModel = require(script.Parent.ReadModel)

export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
	read Persist: (number) -> (boolean, string?),
	read OnReady: ((number) -> ()) -> (() -> ()),
	read OnUnavailable: ((number) -> ()) -> (() -> ()),
}
export type Runtime = {
	-- Monotonic process time, for short-lived runtime intervals only: Combat cooldowns, request
	-- throttling, and active Gathering/Training session timing. Never compared against a persisted
	-- epoch timestamp.
	read Clock: () -> number,
	-- Wall/epoch time, compatible with PlayerData's persisted LastSessionAt. The only clock
	-- OfflineTraining may be constructed with.
	read Now: () -> number,
	read NewInstanceId: () -> string,
	read NewRuntimeId: () -> string,
	read RollInteger: (number, number) -> number,
	read Roll01: () -> number,
	read Warn: (string) -> (),
	-- Trusted scheduling primitives for the shared periodic-settlement heartbeat (see Start()
	-- below). Same shape as PlayerData.Runtime's Spawn/Wait.
	read Spawn: ((...any) -> (), ...any) -> (),
	read Wait: (number) -> (),
}
export type WorldAdapters = {
	read CombatDistanceProvider: (number, any) -> (number?, string?),
	read GatheringNodeResolver: (number, string) -> (any?, string?),
}
export type RequestResult = {
	Ok: boolean,
	Result: any?,
	Reason: string?,
}

-- Provisional balance constants this composition needs to actually run. Not persisted state, not
-- schema -- the same category of "small replaceable data" every *Definitions module already owns.
local MELEE_XP_PER_SUCCESSFUL_HIT = 1
local MINIMUM_REQUEST_INTERVAL_SECONDS = 0.05
-- Provisional cadence for the shared periodic-settlement heartbeat (section 3): frequent enough
-- that a session's rejected/re-validated interval stays small, not so frequent it becomes a
-- per-player-per-frame loop -- one shared task settles every active session on each tick.
local HEARTBEAT_INTERVAL_SECONDS = 1

-- ClaimOfflineReward's Rewarded = false reasons that indicate the claim mechanism itself could not
-- be trusted this time (a session/persistence problem), as opposed to a legitimate "nothing to
-- award" outcome (no focus, no prior session, elapsed below threshold, a future timestamp, or the
-- skill already at its XP cap). Only the former blocks gameplay -- see onSessionReady below.
local OFFLINE_CLAIM_PERSISTENCE_FAILURE_REASONS: { [string]: boolean } = {
	NotReady = true,
	SessionBusy = true,
	SessionLost = true,
	DataStoreUnavailable = true,
	PersistenceFailed = true,
}

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local Composition = {}

function Composition.New(playerData: PlayerData, runtime: Runtime, worldAdapters: WorldAdapters)
	assert(type(playerData) == "table" and type(playerData.OnReady) == "function" and type(playerData.OnUnavailable) == "function", "Composition requires PlayerData with a ready lifecycle")
	assert(
		type(runtime) == "table"
			and type(runtime.Clock) == "function"
			and type(runtime.Now) == "function"
			and type(runtime.Spawn) == "function"
			and type(runtime.Wait) == "function",
		"Composition requires a runtime with separate monotonic Clock and wall-clock Now, plus Spawn/Wait"
	)
	assert(type(worldAdapters) == "table" and type(worldAdapters.CombatDistanceProvider) == "function" and type(worldAdapters.GatheringNodeResolver) == "function", "Composition requires injected world adapters")

	-- Dependency order: PlayerData (given) -> Skills -> Inventory -> Equipment -> Economy ->
	-- Plots -> Enemies -> Combat -> Gathering -> Crafting -> Ascension -> Bosses -> Mastery ->
	-- OfflineTraining -> runtime coordinators -> read model -> request routing. Ascension is built
	-- before Bosses because Bosses.New requires a real Ascension (RecordBossMilestoneToData);
	-- Ascension itself has no dependency on Bosses, so this is a one-directional edge, not a cycle.
	local skills = SkillsService.New(playerData, { Curves = SkillCurves })
	local inventory = InventoryService.New(playerData, { NewInstanceId = runtime.NewInstanceId })
	local equipment = EquipmentService.New(playerData)
	local economy = EconomyService.New(playerData, { NewInstanceId = runtime.NewInstanceId })
	local plots = PlotsService.New(playerData, skills)
	local enemies = EnemiesService.New({ NewRuntimeId = runtime.NewRuntimeId, RollInteger = runtime.RollInteger })
	local combatTargetResolver = enemies.CreateCombatTargetResolver(worldAdapters.CombatDistanceProvider)
	local combat = CombatService.New(equipment, skills, combatTargetResolver, { MeleeXPPerSuccessfulHit = MELEE_XP_PER_SUCCESSFUL_HIT }, runtime.Clock)
	local gathering = GatheringService.New(playerData, equipment, inventory, skills, worldAdapters.GatheringNodeResolver)
	local crafting = CraftingService.New(playerData, inventory, skills)
	local ascension = AscensionService.New(playerData, skills)
	local bosses = BossesService.New(playerData, enemies, economy, inventory, ascension, { Roll01 = runtime.Roll01 })
	local mastery = MasteryService.New(playerData, skills, economy)
	-- OfflineTraining compares its elapsed window against PlayerData's persisted LastSessionAt
	-- (stamped from wall/epoch time by Store), so it must be constructed with the wall clock
	-- (runtime.Now), never the monotonic runtime.Clock used elsewhere in this composition.
	local offlineTraining = OfflineTrainingService.New(playerData, skills, plots, runtime.Now)

	local gatheringSessions = GatheringSessions.New(gathering, GatheringService.MaximumElapsedSeconds, runtime.Clock)
	local trainingSessions = TrainingSessions.New(plots, PlotsService.MaximumElapsedSeconds, runtime.Clock)
	local combatRewards = CombatRewards.New(combat, enemies, economy, bosses, runtime.Warn)

	local gameplayReady: { [number]: boolean } = {}
	local offlineReturnSummaries: { [number]: any } = {}
	local lastRequestAt: { [number]: { [string]: number } } = {}

	local readModel = ReadModel.New({
		Economy = economy,
		Skills = skills,
		Inventory = inventory,
		Equipment = equipment,
		Plots = plots,
		Mastery = mastery,
		Ascension = ascension,
		OfflineTraining = offlineTraining,
	}, offlineReturnSummaries)

	local composition = {}

	-- Exposed only for tests/diagnostics; request handling below never bypasses HandleRequest.
	composition.Services = table.freeze({
		Skills = skills,
		Inventory = inventory,
		Equipment = equipment,
		Economy = economy,
		Plots = plots,
		Enemies = enemies,
		Combat = combat,
		Gathering = gathering,
		Crafting = crafting,
		Bosses = bosses,
		Ascension = ascension,
		Mastery = mastery,
		OfflineTraining = offlineTraining,
	})

	local function onSessionReady(userId: number)
		local claim, reason = offlineTraining.ClaimOfflineReward(userId)
		if not claim then
			-- A hard failure (malformed offline-training/session state) is exactly the "serious
			-- session/persistence failure" this must fail closed on: never mark gameplay ready.
			runtime.Warn(("[Composition] Offline claim failed closed for %d: %s"):format(userId, tostring(reason)))
			return
		end
		offlineReturnSummaries[userId] = claim
		if claim.Rewarded == false and OFFLINE_CLAIM_PERSISTENCE_FAILURE_REASONS[claim.Reason or ""] then
			runtime.Warn(("[Composition] Offline claim persistence failed for %d: %s"):format(userId, tostring(claim.Reason)))
			return
		end
		-- Either a real reward, or a legitimate "nothing to award" outcome (no focus selected, no
		-- prior session, elapsed below threshold, a future timestamp, or an XP-cap rejection) --
		-- both continue normally.
		gameplayReady[userId] = true
	end

	local function onSessionUnavailable(userId: number)
		gameplayReady[userId] = nil
		offlineReturnSummaries[userId] = nil
		lastRequestAt[userId] = nil
		gatheringSessions.Clear(userId)
		trainingSessions.Clear(userId)
	end

	function composition.Start()
		playerData.OnReady(onSessionReady)
		playerData.OnUnavailable(onSessionUnavailable)

		-- One small shared heartbeat settles every active Gathering/Training session, rather than
		-- one infinite per-player task. Each settlement re-validates through the real
		-- resolver/station-read path and only ever credits real elapsed monotonic time.
		runtime.Spawn(function()
			while true do
				runtime.Wait(HEARTBEAT_INTERVAL_SECONDS)
				gatheringSessions.SettleAllActive()
				trainingSessions.SettleAllActive()
			end
		end)
	end

	type Handler = (number, any) -> (any?, string?)
	local handlers: { [string]: Handler } = {}

	handlers[RequestIds.StateGet] = function(userId: number, _payload: any): (any?, string?)
		return readModel.Build(userId)
	end

	handlers[RequestIds.EquipmentEquip] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.SlotId) ~= "string" or type(payload.InstanceId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return equipment.Equip(userId, payload.SlotId, payload.InstanceId)
	end
	handlers[RequestIds.EquipmentUnequip] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.SlotId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return equipment.Unequip(userId, payload.SlotId)
	end

	handlers[RequestIds.EconomyPurchaseStack] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.CatalogId) ~= "string" or type(payload.DefinitionId) ~= "string" or type(payload.Amount) ~= "number" then
			return nil, "MalformedPayload"
		end
		return economy.PurchaseStack(userId, payload.CatalogId, payload.DefinitionId, payload.Amount)
	end
	handlers[RequestIds.EconomySellStack] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.CatalogId) ~= "string" or type(payload.DefinitionId) ~= "string" or type(payload.Amount) ~= "number" then
			return nil, "MalformedPayload"
		end
		return economy.SellStack(userId, payload.CatalogId, payload.DefinitionId, payload.Amount)
	end
	handlers[RequestIds.EconomyPurchaseDiscrete] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.CatalogId) ~= "string" or type(payload.DefinitionId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return economy.PurchaseDiscrete(userId, payload.CatalogId, payload.DefinitionId)
	end
	handlers[RequestIds.EconomySellDiscrete] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.CatalogId) ~= "string" or type(payload.InstanceId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return economy.SellDiscrete(userId, payload.CatalogId, payload.InstanceId)
	end

	handlers[RequestIds.PlotUpgradeStation] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.StationId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return plots.UpgradeStation(userId, payload.StationId)
	end

	handlers[RequestIds.OfflineTrainingSetFocus] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.SkillId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return offlineTraining.SetFocus(userId, payload.SkillId)
	end

	handlers[RequestIds.MasterySelectNode] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.SkillId) ~= "string" or type(payload.NodeId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return mastery.Select(userId, payload.SkillId, payload.NodeId)
	end
	handlers[RequestIds.MasteryRespec] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.SkillId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return mastery.Respec(userId, payload.SkillId)
	end

	handlers[RequestIds.CraftingCraft] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.RecipeId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return crafting.Craft(userId, payload.RecipeId)
	end

	handlers[RequestIds.AscensionAscend] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.RankId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return ascension.Ascend(userId, payload.RankId)
	end

	handlers[RequestIds.CombatMeleeAttack] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.TargetId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return combatRewards.ResolveMeleeAttack(userId, payload.TargetId)
	end

	handlers[RequestIds.GatheringBegin] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.NodeId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return gatheringSessions.Begin(userId, payload.NodeId)
	end
	handlers[RequestIds.GatheringEnd] = function(userId: number, _payload: any): (any?, string?)
		return gatheringSessions.Stop(userId)
	end

	handlers[RequestIds.TrainingBegin] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.StationId) ~= "string" then
			return nil, "MalformedPayload"
		end
		return trainingSessions.Begin(userId, payload.StationId)
	end
	handlers[RequestIds.TrainingEnd] = function(userId: number, _payload: any): (any?, string?)
		return trainingSessions.Stop(userId)
	end

	-- The one trusted request boundary. userId must already be derived by the caller from the
	-- server-provided Player object/context -- this function has no way to accept a client-
	-- submitted UserId, since payload is never consulted for one. Pure Luau, no Roblox transport
	-- objects: Bootstrap's RemoteEvent/RemoteFunction callbacks are expected to do nothing but
	-- translate `player` into `player.UserId` and call this.
	function composition.HandleRequest(userId: number, requestId: any, payload: any): RequestResult
		if not validUserId(userId) then
			return { Ok = false, Result = nil, Reason = "InvalidUserId" }
		end
		if type(requestId) ~= "string" then
			return { Ok = false, Result = nil, Reason = "UnknownRequest" }
		end
		local handler = handlers[requestId]
		if not handler then
			return { Ok = false, Result = nil, Reason = "UnknownRequest" }
		end
		if not gameplayReady[userId] then
			return { Ok = false, Result = nil, Reason = "SessionNotReady" }
		end

		-- Throttled per (user, request kind) rather than globally per user, so spamming one action
		-- (e.g. re-clicking Attack faster than Combat's own cooldown, or hammering State reads)
		-- fails closed without penalizing a normal client that legitimately issues several
		-- different requests back to back.
		local now = runtime.Clock()
		local userThrottle = lastRequestAt[userId]
		if not userThrottle then
			userThrottle = {}
			lastRequestAt[userId] = userThrottle
		end
		local last = userThrottle[requestId]
		if last and (now - last) < MINIMUM_REQUEST_INTERVAL_SECONDS then
			return { Ok = false, Result = nil, Reason = "RequestThrottled" }
		end
		userThrottle[requestId] = now

		local ok, result, reason = pcall(handler, userId, payload)
		if not ok then
			runtime.Warn(("[Composition] Request handler error for %s: %s"):format(tostring(requestId), tostring(result)))
			return { Ok = false, Result = nil, Reason = "InternalError" }
		end
		if result == nil then
			return { Ok = false, Result = nil, Reason = reason or "RequestFailed" }
		end
		return { Ok = true, Result = result, Reason = nil }
	end

	-- Test/diagnostic seams; never wired to a network route.
	function composition.IsGameplayReady(userId: number): boolean
		return gameplayReady[userId] == true
	end
	function composition.GetOfflineReturnSummary(userId: number): any?
		return copy(offlineReturnSummaries[userId])
	end

	return table.freeze(composition)
end

return table.freeze(Composition)
