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
local PlayerHealthService = require(script.Parent.Parent.PlayerHealth.Service)
local OnboardingService = require(script.Parent.Parent.Onboarding.Service)
local DiscoveryService = require(script.Parent.Parent.Discovery.Service)

local RequestIds = require(game:GetService("ReplicatedStorage").Shared.RequestIds)
local GatheringSessions = require(script.Parent.GatheringSessions)
local TrainingSessions = require(script.Parent.TrainingSessions)
local CombatRewards = require(script.Parent.CombatRewards)
local EnemyCombat = require(script.Parent.EnemyCombat)
local PlayerEvents = require(script.Parent.PlayerEvents)
local ReadModel = require(script.Parent.ReadModel)
local SkillIds = require(game:GetService("ReplicatedStorage").Shared.SkillIds)
local EventIds = require(game:GetService("ReplicatedStorage").Shared.EventIds)
local ItemDefinitions = require(game:GetService("ReplicatedStorage").Shared.ItemDefinitions)

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
	-- One-way server -> client presentation transport for pushed player-specific outcome events
	-- (Bootstrap fires a RemoteEvent to the owning player). Only PlayerEvents ever calls it, and only
	-- with an already-sanitized payload; it never carries authority.
	read SendPlayerEvent: (number, string, any) -> (),
}
export type WorldAdapters = {
	read CombatDistanceProvider: (number, any) -> (number?, string?),
	read GatheringNodeResolver: (number, string) -> (any?, string?),
	read StationDistanceProvider: (number, string) -> (number?, string?),
	read ForgeDistanceProvider: (number) -> (number?, string?),
	read ShopDistanceProvider: (number, string) -> (number?, string?),
	read PlayerZoneResolver: (number) -> (string?, string?),
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
-- Provisional server-authoritative interaction radius (studs) a player must be within to Train at,
-- upgrade, or craft at a physical station/Forge. Kept a little larger than the client's presentation
-- radius so anything the client offers the server accepts, without letting a distant player interact.
local INTERACTION_RANGE_STUDS = 18
-- Provisional runtime combat balance. Max player health, and the difficulty-scaled Defense combat XP
-- (docs/DESIGN_SOURCE_OF_TRUTH.md): per meaningful hit taken, Defense XP =
-- clamp(Base + PerLevel * (enemyLevel - playerLevel), Minimum, Maximum). It scales with enemy
-- difficulty relative to the player, never with damage taken -- trivial fights award ~0, appropriate
-- and dangerous fights award more up to the cap. Replaceable balance data.
local MAX_PLAYER_HEALTH = 100
local DEFENSE_XP_BASE = 2
local DEFENSE_XP_PER_LEVEL = 1
local DEFENSE_XP_MINIMUM = 0
local DEFENSE_XP_MAXIMUM = 6
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
			and type(runtime.Wait) == "function"
			and type(runtime.SendPlayerEvent) == "function",
		"Composition requires a runtime with separate monotonic Clock and wall-clock Now, plus Spawn/Wait and a player-event transport"
	)
	assert(
		type(worldAdapters) == "table"
			and type(worldAdapters.CombatDistanceProvider) == "function"
			and type(worldAdapters.GatheringNodeResolver) == "function"
			and type(worldAdapters.StationDistanceProvider) == "function"
			and type(worldAdapters.ForgeDistanceProvider) == "function"
			and type(worldAdapters.ShopDistanceProvider) == "function"
			and type(worldAdapters.PlayerZoneResolver) == "function",
		"Composition requires injected world adapters"
	)

	-- Server-authoritative physical proximity, derived from the injected world adapters and the
	-- provisional interaction radius. The client may use its own proximity purely for presentation;
	-- these are the only proximity checks that gate Training, station upgrades, and Forge crafting.
	local function nearStation(userId: number, stationId: string): (boolean, string?)
		local distance, reason = worldAdapters.StationDistanceProvider(userId, stationId)
		if type(distance) ~= "number" then
			return false, reason or "StationNotReachable"
		end
		if distance > INTERACTION_RANGE_STUDS then
			return false, "TooFarFromStation"
		end
		return true, nil
	end
	local function nearForge(userId: number): (boolean, string?)
		local distance, reason = worldAdapters.ForgeDistanceProvider(userId)
		if type(distance) ~= "number" then
			return false, reason or "ForgeNotReachable"
		end
		if distance > INTERACTION_RANGE_STUDS then
			return false, "TooFarFromForge"
		end
		return true, nil
	end
	-- Server-authoritative Shop proximity: every buy/sell through a catalog requires the player to be
	-- physically near the AR_Shop instance whose stable ShopId matches that catalog. The client's own
	-- proximity only opens the panel for convenience; this is the check the transaction actually trusts.
	local function nearShop(userId: number, shopId: string): (boolean, string?)
		local distance, reason = worldAdapters.ShopDistanceProvider(userId, shopId)
		if type(distance) ~= "number" then
			return false, reason or "ShopNotReachable"
		end
		if distance > INTERACTION_RANGE_STUDS then
			return false, "TooFarFromShop"
		end
		return true, nil
	end

	-- Dependency order: PlayerData (given) -> Skills -> Inventory -> Equipment -> Economy -> Mastery ->
	-- Plots -> Enemies -> Combat -> Gathering -> Crafting -> Ascension -> Bosses -> OfflineTraining ->
	-- runtime coordinators -> read model -> request routing. Mastery is built right after Economy (its
	-- only dependencies are PlayerData, Skills, Economy) so its modifier totals can be injected into the
	-- gameplay systems that consume them (Combat, PlayerHealth/EnemyCombat, Gathering, Crafting).
	-- Ascension is built before Bosses because Bosses.New requires a real Ascension
	-- (RecordBossMilestoneToData); Ascension itself has no dependency on Bosses, so this is a
	-- one-directional edge, not a cycle.
	local skills = SkillsService.New(playerData, { Curves = SkillCurves })
	local inventory = InventoryService.New(playerData, { NewInstanceId = runtime.NewInstanceId })
	local equipment = EquipmentService.New(playerData)
	local economy = EconomyService.New(playerData, { NewInstanceId = runtime.NewInstanceId })
	local mastery = MasteryService.New(playerData, skills, economy)
	-- Forward-declared here so the defense-modifier provider below can fold in the player's current
	-- Ascension rank perk; the real service is constructed in dependency order further down.
	local ascension: any = nil

	-- Mastery.GetModifiers stays the single source of truth for selected-node effects; these thin
	-- adapters hand each consuming system only the totals for the one skill it applies, defaulting to an
	-- empty table (no bonus) if a snapshot is momentarily unavailable. No node/branch logic is copied,
	-- and no value here is ever client-supplied.
	local function modifiersForSkill(userId: number, skillId: string): { [string]: number }
		local totals = mastery.GetModifiers(userId, skillId)
		return if type(totals) == "table" then totals else {}
	end
	local function meleeModifiers(userId: number): { [string]: number }
		return modifiersForSkill(userId, SkillIds.Melee)
	end
	-- Sum the incoming-damage mitigation of this player's currently-equipped armour pieces (Head/Body/
	-- Legs). Read from the same authoritative equipment snapshot the equip flow writes; unknown or
	-- non-armour items contribute nothing. This is server-derived, never client-supplied.
	local function equippedArmorReduction(userId: number): number
		local snapshot = equipment.GetSnapshot(userId)
		if type(snapshot) ~= "table" then
			return 0
		end
		local total = 0
		for _, equippedItem in snapshot do
			local itemDefinition = ItemDefinitions.ById[equippedItem.DefinitionId]
			if itemDefinition and itemDefinition.Armor then
				total += itemDefinition.Armor.DamageReduction
			end
		end
		return total
	end
	-- Defense Mastery totals PLUS equipped-armour mitigation, composed into the single
	-- IncomingDamageReduction channel EnemyCombat already reads and clamps. Folding armour here (rather
	-- than in EnemyCombat) keeps EnemyCombat/PlayerHealth unchanged: armour is just more of the same
	-- reduction the Defense tree already contributes. A cloned table is returned so we never mutate
	-- Mastery's cached totals; MaxHealthBonus (read by PlayerHealth) is passed through untouched.
	local function defenseModifiers(userId: number): { [string]: number }
		local totals = table.clone(modifiersForSkill(userId, SkillIds.Defense))
		local armorReduction = equippedArmorReduction(userId)
		if armorReduction ~= 0 then
			local existing = totals.IncomingDamageReduction
			totals.IncomingDamageReduction = (if type(existing) == "number" then existing else 0) + armorReduction
		end
		-- Current Ascension rank perk: fold its permanent MaxHealthBonus + IncomingDamageReduction into the
		-- same channels, so Ascending immediately toughens the player (more max health, less damage taken)
		-- with NO change to PlayerHealth/EnemyCombat -- the rank is just more of the same bonuses.
		local perk = if ascension then ascension.GetPerk(userId) else nil
		if type(perk) == "table" then
			if type(perk.MaxHealthBonus) == "number" and perk.MaxHealthBonus ~= 0 then
				local existing = totals.MaxHealthBonus
				totals.MaxHealthBonus = (if type(existing) == "number" then existing else 0) + perk.MaxHealthBonus
			end
			if type(perk.IncomingDamageReduction) == "number" and perk.IncomingDamageReduction ~= 0 then
				local existing = totals.IncomingDamageReduction
				totals.IncomingDamageReduction = (if type(existing) == "number" then existing else 0) + perk.IncomingDamageReduction
			end
		end
		return totals
	end
	-- Read-only, presentation-facing view of the SAME mitigation EnemyCombat applies (Defense Mastery +
	-- equipped armour), so the client can show the player how much damage their Defense/gear actually
	-- reduces. Total is clamped to the exact ceiling EnemyCombat uses; Armor is the equipped-gear-only
	-- portion so the Gear panel can attribute the reward to the armour they crafted. Derived server-side.
	local function defenseSummary(userId: number): { Total: number, Armor: number }
		local raw = defenseModifiers(userId).IncomingDamageReduction
		-- Clamp to EnemyCombat's own exported ceiling, so this display value is the SAME bound combat
		-- applies with no duplicated literal to drift out of sync.
		local total = math.clamp(if type(raw) == "number" then math.max(0, raw) else 0, 0, EnemyCombat.MaxIncomingDamageReduction)
		return { Total = total, Armor = equippedArmorReduction(userId) }
	end
	local function miningModifiers(userId: number): { [string]: number }
		return modifiersForSkill(userId, SkillIds.Mining)
	end
	-- Crafting reads Smithing modifiers from the same transactional `data` it is mutating (atomic with
	-- the craft), so this adapter takes the data snapshot rather than a userId.
	local function smithingModifiersFromData(data: any): { [string]: number }
		local totals = mastery.GetModifiersFromData(data, SkillIds.Smithing)
		return if type(totals) == "table" then totals else {}
	end

	local plots = PlotsService.New(playerData, skills)
	local enemies = EnemiesService.New({ NewRuntimeId = runtime.NewRuntimeId, RollInteger = runtime.RollInteger })
	local combatTargetResolver = enemies.CreateCombatTargetResolver(worldAdapters.CombatDistanceProvider)
	local combat = CombatService.New(equipment, skills, combatTargetResolver, { MeleeXPPerSuccessfulHit = MELEE_XP_PER_SUCCESSFUL_HIT }, runtime.Clock, meleeModifiers)
	local gathering = GatheringService.New(playerData, equipment, inventory, skills, worldAdapters.GatheringNodeResolver, miningModifiers)
	local crafting = CraftingService.New(playerData, inventory, skills, smithingModifiersFromData)
	ascension = AscensionService.New(playerData, skills)
	local bosses = BossesService.New(playerData, enemies, economy, inventory, ascension, { Roll01 = runtime.Roll01 })
	-- OfflineTraining compares its elapsed window against PlayerData's persisted LastSessionAt
	-- (stamped from wall/epoch time by Store), so it must be constructed with the wall clock
	-- (runtime.Now), never the monotonic runtime.Clock used elsewhere in this composition.
	local offlineTraining = OfflineTrainingService.New(playerData, skills, plots, runtime.Now)
	-- Runtime (never persisted) player health, and the enemy-attack resolver World's shared heartbeat
	-- drives. EnemyCombat owns aggression/damage/Defense XP; World owns the physical range/timing and
	-- the death respawn. Enemy stats and rewards remain owned by the Enemy service above.
	-- Defense Mastery raises this player's maximum health (MaxHealthBonus) and reduces incoming enemy
	-- damage (IncomingDamageReduction); both are read live from the injected provider so a selection or
	-- respec takes effect immediately.
	local playerHealth = PlayerHealthService.New({ MaxHealth = MAX_PLAYER_HEALTH }, defenseModifiers)
	local enemyCombat = EnemyCombat.New(playerHealth, skills, {
		DefenseXP = { Base = DEFENSE_XP_BASE, PerLevel = DEFENSE_XP_PER_LEVEL, Minimum = DEFENSE_XP_MINIMUM, Maximum = DEFENSE_XP_MAXIMUM },
		ProgressionSkillId = SkillIds.Melee,
	}, defenseModifiers)

	-- One reusable, typed server -> client presentation-event seam. Boss loot / Gold / progression are
	-- resolved and committed entirely by Bosses/CombatRewards above; this only surfaces the outcome.
	local playerEvents = PlayerEvents.New({ Send = runtime.SendPlayerEvent })
	-- Fans a resolved boss death out to one sanitized personal-reward event per PARTICIPANT (each to
	-- their own userId). Qualified and RewardGranted stay distinct: Qualified comes from the
	-- contribution-threshold Eligible flag, RewardGranted from whether the atomic reward transaction
	-- succeeded. Reward data is carried only when actually granted, so an ineligible player or an
	-- eligible player whose grant failed never receives a fabricated reward; non-participants (absent
	-- from the Result) receive nothing. PlayerEvents sanitizes/validates before anything is sent, so no
	-- internal field (including FailureReason) can leak to the client.
	local function announceBossReward(result: any)
		if type(result) ~= "table" or type(result.Participants) ~= "table" then
			return
		end
		local bossDefinitionId = result.DefinitionId
		for _, participant in result.Participants do
			local eligible = participant.Eligible == true
			local granted = participant.RewardGranted == true
			local rareGranted = granted and participant.RareGranted == true
			local ok, reason = playerEvents.Emit(participant.UserId, EventIds.BossPersonalReward, {
				BossDefinitionId = bossDefinitionId,
				Qualified = eligible,
				RewardGranted = granted,
				GoldAwarded = if granted then (participant.CommonGoldAmount or 0) else 0,
				CommonItemDefinitionId = if granted then participant.CommonItemDefinitionId else nil,
				CommonItemAmount = if granted then participant.CommonItemAmount else nil,
				RareItemDefinitionId = if rareGranted then participant.RareItemDefinitionId else nil,
				RareItemAmount = if rareGranted then participant.RareItemAmount else nil,
			})
			if not ok then
				-- Presentation-only: a rejected/failed emit is logged but never affects the already-
				-- committed authoritative reward transaction.
				runtime.Warn(("[Composition] Boss reward event emit failed for %d: %s"):format(participant.UserId, tostring(reason)))
			end
		end
	end

	-- Onboarding guidance: derives the fresh player's current step from durable state/flags and owns the
	-- trusted writes that latch historical onboarding milestones. It needs only Skills (level reads) and
	-- Economy (the atomic post-training Gold reward); everything else it reads from data.
	local onboarding = OnboardingService.New(playerData, { Skills = skills, Economy = economy })
	-- First-visit zone discovery: grants a one-time Gold reward when the player physically reaches a new
	-- wilderness zone. Server-authoritative -- the zone is resolved from the real world position via the
	-- injected adapter, never from client input -- and atomic (flag + Gold credit in one transaction).
	local discovery = DiscoveryService.New(playerData, economy, worldAdapters.PlayerZoneResolver)

	-- Onboarding first-ore milestone: recorded only from a real Mining settlement that actually awarded
	-- Iron Ore (onboarding filters by item), so buying ore never satisfies it. Best-effort and pcall-
	-- isolated so an onboarding write can never break the shared gathering-settlement heartbeat.
	local gatheringSessions = GatheringSessions.New(gathering, GatheringService.MaximumElapsedSeconds, runtime.Clock, function(userId: number, result: any)
		if type(result) == "table" and type(result.OreAmount) == "number" and result.OreAmount > 0 then
			pcall(onboarding.NoteOreGathered, userId, result.OreDefinitionId)
		end
	end)
	local trainingSessions = TrainingSessions.New(plots, PlotsService.MaximumElapsedSeconds, runtime.Clock, nearStation)
	-- CombatRewards reports the consumed normal-enemy defeat with its definition id; onboarding records
	-- the one-time "first Goblin defeated" milestone only for an actual Goblin.
	local combatRewards = CombatRewards.New(combat, enemies, economy, bosses, runtime.Warn, announceBossReward, function(userId: number, definitionId: string)
		onboarding.NoteGoblinDefeated(userId, definitionId)
	end)

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
		PlayerHealth = playerHealth,
		Onboarding = onboarding,
		DefenseSummary = defenseSummary,
		Discovery = discovery,
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
		PlayerHealth = playerHealth,
		Onboarding = onboarding,
		Discovery = discovery,
		-- World's heartbeat drives this to resolve enemy attacks; exposed here so Bootstrap can inject
		-- it into World.Start alongside the Enemies service.
		EnemyCombat = enemyCombat,
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
		playerHealth.Clear(userId)
		enemyCombat.ClearPlayer(userId)
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
		local near, nearReason = nearShop(userId, payload.CatalogId)
		if not near then
			return nil, nearReason
		end
		return economy.PurchaseStack(userId, payload.CatalogId, payload.DefinitionId, payload.Amount)
	end
	handlers[RequestIds.EconomySellStack] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.CatalogId) ~= "string" or type(payload.DefinitionId) ~= "string" or type(payload.Amount) ~= "number" then
			return nil, "MalformedPayload"
		end
		local near, nearReason = nearShop(userId, payload.CatalogId)
		if not near then
			return nil, nearReason
		end
		return economy.SellStack(userId, payload.CatalogId, payload.DefinitionId, payload.Amount)
	end
	handlers[RequestIds.EconomyPurchaseDiscrete] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.CatalogId) ~= "string" or type(payload.DefinitionId) ~= "string" then
			return nil, "MalformedPayload"
		end
		local near, nearReason = nearShop(userId, payload.CatalogId)
		if not near then
			return nil, nearReason
		end
		return economy.PurchaseDiscrete(userId, payload.CatalogId, payload.DefinitionId)
	end
	handlers[RequestIds.EconomySellDiscrete] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.CatalogId) ~= "string" or type(payload.InstanceId) ~= "string" then
			return nil, "MalformedPayload"
		end
		local near, nearReason = nearShop(userId, payload.CatalogId)
		if not near then
			return nil, nearReason
		end
		return economy.SellDiscrete(userId, payload.CatalogId, payload.InstanceId)
	end

	handlers[RequestIds.PlotUpgradeStation] = function(userId: number, payload: any): (any?, string?)
		if type(payload) ~= "table" or type(payload.StationId) ~= "string" then
			return nil, "MalformedPayload"
		end
		local near, nearReason = nearStation(userId, payload.StationId)
		if not near then
			return nil, nearReason
		end
		return plots.UpgradeStation(userId, payload.StationId)
	end

	handlers[RequestIds.OnboardingAcknowledgeStarterFocus] = function(userId: number, _payload: any): (any?, string?)
		-- The only onboarding write a client may trigger: record that the starter-focus framing was
		-- confirmed. It grants no gold/items and cannot mark any other step complete.
		return onboarding.AcknowledgeStarterFocus(userId)
	end

	handlers[RequestIds.RegionDiscoverCurrentZone] = function(userId: number, _payload: any): (any?, string?)
		-- The client asks "have I just entered somewhere new?"; the server resolves the player's REAL
		-- position and grants the first-visit reward only if they are genuinely in a new discoverable zone.
		-- No client-supplied zone id is trusted, so a discovery can never be spoofed.
		return discovery.DiscoverCurrentZone(userId)
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
		-- Crafting happens at the shared Forge; the player must physically be near it.
		local near, nearReason = nearForge(userId)
		if not near then
			return nil, nearReason
		end
		-- Forward the requested batch shape; Crafting authoritatively validates the quantity and, for
		-- Max, computes the affordable amount itself. Max takes precedence over an explicit Quantity.
		local craftRequest: any = nil
		if payload.Max == true then
			craftRequest = { Max = true }
		elseif payload.Quantity ~= nil then
			craftRequest = { Quantity = payload.Quantity }
		end
		local result, reason = crafting.Craft(userId, payload.RecipeId, craftRequest)
		if result then
			-- A successful craft actually used the Forge: record the Smelting milestone only for the Iron
			-- Bar recipe (onboarding filters by recipe id). Best-effort; never fails the craft.
			pcall(onboarding.NoteBarSmithed, userId, payload.RecipeId)
		end
		return result, reason
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
		local result, reason = combatRewards.ResolveMeleeAttack(userId, payload.TargetId)
		if result then
			-- A real, server-validated hit landed, so this enemy now retaliates against the attacker
			-- even if they have outgrown it. Provocation is derived only from this success -- the
			-- client's payload merely named a target, it cannot assert an enemy is provoked.
			enemyCombat.RecordProvocation(payload.TargetId, userId)
		end
		return result, reason
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

		-- Reconcile onboarding before serving the request so heartbeat-driven progress (training XP,
		-- gathered ore) and the once-only post-training Gold reward are latched, and the StateGet the
		-- client polls reflects the current authoritative step. Isolated so a reconcile hiccup can never
		-- fail a gameplay request; onboarding writes are idempotent and simply retry next request.
		local settled = pcall(onboarding.Settle, userId)
		if not settled then
			runtime.Warn(("[Composition] Onboarding settle failed for %d"):format(userId))
		end

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
