--!strict

-- Physical Studio-side implementation of the repository's world-adapter boundary
-- (Composition/WorldAdapters). It supplies the two real, server-authoritative functions Combat and
-- Gathering need -- attacker/target physical distance and gathering-node resolution -- by reading the
-- live Studio scene, and it binds physical enemy instances to repository Enemy runtime IDs, including
-- the minimal spawn/death/respawn behavior needed to validate the vertical-slice loop.
--
-- This module owns NO gameplay outcome. Health, damage, Gold, XP, and every progression decision stay
-- entirely in the repository services; the adapters here only answer "where is this actor in the
-- world" and "which repository runtime instance is this physical model". Enemy models created here
-- carry a repository RuntimeId as authority and deliberately have no Humanoid, so there is no second
-- health/combat system.

local EnemyAI = require(script.Parent.EnemyAI)

local ENEMY_SPAWN_TAG = "AR_EnemySpawn"
-- A territory volume: a tagged BasePart whose position is the population's home/leash anchor and whose
-- attributes declare which archetype lives there, how many, and how far they roam. Territories are the
-- data-driven evolution of the single-enemy spawn marker -- they localize populations to a region.
local ENEMY_TERRITORY_TAG = "AR_EnemyTerritory"
local ENEMY_TAG = "AR_Enemy"
local GATHERING_NODE_TAG = "AR_GatheringNode"
local TRAINING_STATION_TAG = "AR_TrainingStation"
local FORGE_TAG = "AR_Forge"
local SHOP_TAG = "AR_Shop"

-- Territory marker attribute keys (stable identifiers, authored in the Studio scene).
local ATTR_TERRITORY_ID = "TerritoryId"
local ATTR_TERRITORY_RADIUS = "Radius"
local ATTR_TERRITORY_POPULATION = "Population"
-- Optional per-territory movement-tuning overrides (any of EnemyAI.Config's keys); absent => defaults.
local TERRITORY_TUNING_KEYS = { "AggroRadius", "DeaggroRadius", "LeashRadius", "RoamRadius", "RoamSpeed", "ChaseSpeed", "ArriveRadius", "RoamPauseMin", "RoamPauseMax", "AttackRange" }

-- Presentation-only display names for the billboard label (stable IDs stay authoritative). A missing
-- id falls back to a neutral word rather than mislabeling a new archetype as a Goblin.
local ENEMY_DISPLAY_NAMES: { [string]: string } = {
	enemy_goblin = "Goblin",
	enemy_goblin_chieftain = "Goblin Chieftain",
	enemy_wolf = "Wolf",
}

-- Territory defaults when a marker omits an attribute, and how far past a territory's edge an enemy may
-- chase before leashing home (added to the territory radius unless the marker overrides LeashRadius).
local DEFAULT_TERRITORY_RADIUS = 30
local DEFAULT_TERRITORY_POPULATION = 3
local TERRITORY_LEASH_BUFFER = 40

-- An enemy whose territory has no player within this range (studs) sleeps: its movement brain is
-- skipped entirely until a player approaches. Keeps far, unwatched populations free on the server.
local ACTIVATION_RADIUS = 220
-- Gentle vertical bob applied while an enemy is moving, to read as locomotion without an animated rig.
local WALK_BOB_AMPLITUDE = 0.35
-- Degrees to rotate a facing enemy so the model's visible front points where it heads. The provisional
-- meshes' authored front is not -Z, so this corrects it; verified against the live models in Studio.
local FACING_YAW_OFFSET = 0

-- Attribute keys (stable identifiers, never display names).
local ATTR_ENEMY_DEFINITION_ID = "EnemyDefinitionId"
local ATTR_ENEMY_RUNTIME_ID = "EnemyRuntimeId"
local ATTR_ENEMY_LEVEL = "EnemyLevel"
local ATTR_ENEMY_ALIVE = "EnemyAlive"
-- Sanitized current/max health mirrored onto the bound enemy model purely for client presentation
-- (target and boss health bars). These are a READ-ONLY reflection of the authoritative Enemies runtime
-- state; the client never writes them back and no gameplay logic reads them. World owns the mirror.
local ATTR_ENEMY_HEALTH = "EnemyHealth"
local ATTR_ENEMY_MAX_HEALTH = "EnemyMaxHealth"
local ATTR_GATHERING_NODE_ID = "GatheringNodeId"
local ATTR_STATION_ID = "StationId"
local ATTR_SHOP_ID = "ShopId"

-- Provisional respawn cadence and a low-frequency death poll. Event-driven death is not exposed by
-- the repository Enemies service, so a single shared poll re-reads authoritative Alive state; this is
-- intentionally minimal, not a general AI/spawning framework.
local RESPAWN_SECONDS = 5
local DEATH_POLL_SECONDS = 0.5

-- Provisional enemy melee reach (studs) and per-enemy attack cooldown (seconds). Enemies are
-- stationary at their markers, so a player is in danger only while standing within reach; the
-- cooldown is the trusted rate limit on incoming damage and on Defense XP.
local ENEMY_ATTACK_RANGE = 10
local ENEMY_ATTACK_COOLDOWN = 2

export type Enemies = {
	read Create: (string) -> (any?, string?),
	read GetSnapshot: (string) -> (any?, string?),
	read Remove: (string) -> (any?, string?),
}

-- Trusted enemy-attack resolver (see Composition/EnemyCombat): given a target userId and an Enemy
-- runtime snapshot it decides aggression, applies the enemy's authoritative Damage to runtime health,
-- awards Defense XP, and reports death. World supplies only the physical facts (range, cooldown).
-- Every method World actually invokes is declared here so Start can reject an incomplete object up
-- front: ClearEnemy is called on an enemy's death/respawn to drop that RuntimeId's provocation state.
export type EnemyCombat = {
	read ResolveAttack: (number, any) -> (any?, string?),
	read OnSpawn: (number) -> (),
	read ClearEnemy: (string) -> (),
}

export type Runtime = {
	read Players: Players,
	read Workspace: Workspace,
	read Collection: CollectionService,
	read Clock: () -> number,
	read Warn: (string) -> (),
	read Spawn: ((...any) -> (), ...any) -> (),
	read Wait: (number) -> (),
	-- Optional per-frame signal (RunService.Heartbeat) that drives smooth, server-authoritative enemy
	-- movement. When absent (as in headless tests) enemies simply do not roam -- every other behaviour,
	-- including combat, death, and respawn, is unaffected, so the movement layer is purely additive.
	read Heartbeat: RBXScriptSignal?,
	-- Optional presentation seam: a container of production enemy models keyed by EnemyDefinitionId
	-- (e.g. ServerStorage.AR_Assets.Enemies.enemy_goblin). When a matching template exists it is cloned
	-- as the enemy's physical body; otherwise a provisional coloured box is built. The template is pure
	-- presentation -- it carries no Humanoid and no gameplay authority; the repository Enemy runtime
	-- remains the single source of health/damage/reward. Absent (as in headless tests), the box is used.
	read EnemyTemplates: Instance?,
}

type EnemyRecord = {
	Model: Model,
	Marker: BasePart,
	DefinitionId: string,
	RuntimeId: string,
	RespawnAt: number?,
	-- The BaseParts faded on death and restored on respawn. Captured once at build time as a plain
	-- array so the death/respawn path never needs to re-walk the instance tree.
	FadeParts: { BasePart },
	-- ----- Living-world movement state -----
	-- Territory home (leash anchor + roam centre) and its radius; the grounded pivot height to keep the
	-- body on the floor as it moves; the base (un-bobbed) world position the AI reasons about; the
	-- resolved per-territory movement tuning; the behavioural memory the pure state machine advances;
	-- and a bob phase for the walk illusion. Home/Radius/Config are fixed for the territory; the rest
	-- evolve every movement tick.
	Home: Vector3,
	Radius: number,
	GroundY: number,
	BasePosition: Vector3,
	AIConfig: EnemyAI.Config,
	AIMemory: EnemyAI.Memory,
	BobPhase: number,
}

local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

export type AttackCandidate = {
	UserId: number,
	Root: BasePart,
	Distance: number,
}

-- Pure, deterministic multiplayer target selection (extracted so it is testable without a live
-- two-player Studio session). Given every physically in-range candidate and a resolver that attempts
-- an attack on one userId -- returning a result when the hit lands (the enemy is aggressive toward or
-- provoked by that player) and nil otherwise -- pick the NEAREST candidate the enemy is actually
-- engaged with. A closer candidate the resolver rejects (a passive, overleveled player) is skipped, so
-- it can never shield an eligible player standing behind it. Returns the chosen candidate and result.
-- Pure, deterministic sanitization of an authoritative Enemy runtime state into the two values the
-- client may present. Never trusts the state blindly: a dead enemy (or a missing/negative health)
-- always yields 0 current health, and current health is clamped into [0, MaxHealth]. It returns a
-- fresh table and never mutates its input, so it can be reused for any archetype (normal or boss) and
-- can never become a second health authority.
function Service.SanitizeEnemyHealth(state: any): { Health: number, MaxHealth: number }
	local maxHealth = if type(state) == "table" and type(state.MaxHealth) == "number" and state.MaxHealth > 0 and state.MaxHealth < math.huge then math.floor(state.MaxHealth) else 0
	local alive = type(state) == "table" and state.Alive == true
	local rawHealth = if alive and type(state.Health) == "number" and state.Health == state.Health then state.Health else 0
	local health = math.clamp(math.floor(rawHealth), 0, maxHealth)
	return { Health = health, MaxHealth = maxHealth }
end

function Service.SelectAttackTarget(candidates: { AttackCandidate }, resolveAttack: (number) -> (any?, string?)): (AttackCandidate?, any?)
	local ordered = table.clone(candidates)
	table.sort(ordered, function(a, b)
		return a.Distance < b.Distance
	end)
	for _, candidate in ordered do
		local result = resolveAttack(candidate.UserId)
		if result then
			return candidate, result
		end
	end
	return nil, nil
end

function Service.New(runtime: Runtime)
	assert(
		type(runtime) == "table"
			and typeof(runtime.Players) == "Instance"
			and typeof(runtime.Workspace) == "Instance"
			and typeof(runtime.Collection) == "Instance"
			and type(runtime.Clock) == "function"
			and type(runtime.Warn) == "function"
			and type(runtime.Spawn) == "function"
			and type(runtime.Wait) == "function",
		"World requires Players, Workspace, CollectionService, Clock, Warn, Spawn, and Wait"
	)

	-- runtimeId -> physical enemy model. Rebound on every respawn (old id removed, new id added), so a
	-- lookup miss is an authoritative "this runtime instance no longer has a body in the world".
	local enemyModels: { [string]: Model } = {}
	local records: { EnemyRecord } = {}
	-- runtimeId -> monotonic time of this enemy's last landed attack, for the trusted attack cooldown.
	local lastAttackAt: { [string]: number } = {}

	local service = {}

	-- The one place a live character's world position is read. Returns a clear fail-closed reason
	-- rather than a fabricated position when the actor is not physically present.
	local function characterPosition(userId: number): (Vector3?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local player = runtime.Players:GetPlayerByUserId(userId)
		if not player then
			return nil, "ActorNotInWorld"
		end
		local character = player.Character
		if not character then
			return nil, "ActorHasNoCharacter"
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			return nil, "ActorHasNoRoot"
		end
		return root.Position, nil
	end

	-- Only tagged instances that live under Workspace count as physical world content. A tagged
	-- template or definition parked elsewhere in the DataModel (ServerStorage, ReplicatedStorage, a
	-- disconnected instance, ...) must never resolve as a real gathering node or enemy spawn marker.
	local function isWorldContent(instance: Instance): boolean
		return instance:IsDescendantOf(runtime.Workspace)
	end

	local function enemyLabelText(definitionId: string, level: any): string
		local displayName = ENEMY_DISPLAY_NAMES[definitionId] or "Enemy"
		return displayName .. " Lv" .. tostring(level)
	end

	-- Mirrors the sanitized authoritative health onto the bound model for client presentation only. It
	-- reads the runtime state and writes two attributes; it never mutates the runtime.
	local function writeEnemyHealth(model: Model, state: any)
		local health = Service.SanitizeEnemyHealth(state)
		model:SetAttribute(ATTR_ENEMY_MAX_HEALTH, health.MaxHealth)
		model:SetAttribute(ATTR_ENEMY_HEALTH, health.Health)
	end

	-- CombatDistanceProvider: (attackerUserId, enemyState) -> (distance, reason). Eligibility (Alive)
	-- is intentionally NOT decided here -- the repository Enemies combat resolver derives Eligible from
	-- authoritative Alive state. This function only reports the true physical distance between the
	-- attacker and the physical instance bound to the target's RuntimeId.
	function service.CombatDistanceProvider(attackerUserId: number, enemyState: any): (number?, string?)
		if type(enemyState) ~= "table" or type(enemyState.RuntimeId) ~= "string" or enemyState.RuntimeId == "" then
			return nil, "InvalidEnemyState"
		end
		local position, reason = characterPosition(attackerUserId)
		if not position then
			return nil, reason
		end
		local model = enemyModels[enemyState.RuntimeId]
		if not model or not model.Parent then
			return nil, "EnemyInstanceNotFound"
		end
		local pivot = model:GetPivot().Position
		return (position - pivot).Magnitude, nil
	end

	-- GatheringNodeResolver: (userId, nodeId) -> (Node, reason). Iron Ore is non-depleting, so a
	-- physically present node is always Eligible. Several physical rocks may share one stable node ID;
	-- the nearest one to the gatherer decides the reported Distance.
	function service.GatheringNodeResolver(userId: number, nodeId: string): (any?, string?)
		if type(nodeId) ~= "string" or nodeId == "" then
			return nil, "InvalidNodeId"
		end
		local position, reason = characterPosition(userId)
		if not position then
			return nil, reason
		end
		local nearest: number? = nil
		for _, instance in runtime.Collection:GetTagged(GATHERING_NODE_TAG) do
			if instance:IsA("BasePart") and isWorldContent(instance) and instance:GetAttribute(ATTR_GATHERING_NODE_ID) == nodeId then
				local distance = (position - instance.Position).Magnitude
				if nearest == nil or distance < nearest then
					nearest = distance
				end
			end
		end
		if nearest == nil then
			return nil, "NodeInstanceNotFound"
		end
		return { Id = nodeId, Eligible = true, Distance = nearest }, nil
	end

	-- Shared nearest-instance scan over a tag, honouring the Workspace-descendant rule. `matches`
	-- lets a caller further restrict by attribute (e.g. a station's StableId); pass nil to accept any.
	local function nearestTaggedDistance(position: Vector3, tag: string, matches: ((Instance) -> boolean)?): number?
		local nearest: number? = nil
		for _, instance in runtime.Collection:GetTagged(tag) do
			if isWorldContent(instance) and (matches == nil or matches(instance)) then
				local pivot: Vector3? = nil
				if instance:IsA("BasePart") then
					pivot = instance.Position
				elseif instance:IsA("Model") then
					pivot = instance:GetPivot().Position
				end
				if pivot then
					local distance = (position - pivot).Magnitude
					if nearest == nil or distance < nearest then
						nearest = distance
					end
				end
			end
		end
		return nearest
	end

	-- StationDistanceProvider: (userId, stationId) -> (distance, reason). Real physical distance from
	-- the player to the AR_TrainingStation instance carrying that stable StationId. Fail closed (no
	-- fabricated distance) when the player is absent or no such station exists in the world.
	function service.StationDistanceProvider(userId: number, stationId: string): (number?, string?)
		if type(stationId) ~= "string" or stationId == "" then
			return nil, "InvalidStationId"
		end
		local position, reason = characterPosition(userId)
		if not position then
			return nil, reason
		end
		local nearest = nearestTaggedDistance(position, TRAINING_STATION_TAG, function(instance)
			return instance:GetAttribute(ATTR_STATION_ID) == stationId
		end)
		if nearest == nil then
			return nil, "StationInstanceNotFound"
		end
		return nearest, nil
	end

	-- ForgeDistanceProvider: (userId) -> (distance, reason). Real physical distance from the player to
	-- the nearest AR_Forge instance. Fail closed when the player is absent or no Forge exists.
	function service.ForgeDistanceProvider(userId: number): (number?, string?)
		local position, reason = characterPosition(userId)
		if not position then
			return nil, reason
		end
		local nearest = nearestTaggedDistance(position, FORGE_TAG, nil)
		if nearest == nil then
			return nil, "ForgeInstanceNotFound"
		end
		return nearest, nil
	end

	-- ShopDistanceProvider: (userId, shopId) -> (distance, reason). Real physical distance from the player
	-- to the AR_Shop instance carrying that stable ShopId (the same stable id as the Economy catalog it
	-- fronts). Fail closed when the player is absent or no such Shop exists in the world.
	function service.ShopDistanceProvider(userId: number, shopId: string): (number?, string?)
		if type(shopId) ~= "string" or shopId == "" then
			return nil, "InvalidShopId"
		end
		local position, reason = characterPosition(userId)
		if not position then
			return nil, reason
		end
		local nearest = nearestTaggedDistance(position, SHOP_TAG, function(instance)
			return instance:GetAttribute(ATTR_SHOP_ID) == shopId
		end)
		if nearest == nil then
			return nil, "ShopInstanceNotFound"
		end
		return nearest, nil
	end

		-- Resolve the optional production template for a definition. Nil (no library, or no matching
		-- child) means "use the provisional box", which is also the path the headless World tests take.
		local function resolveTemplate(definitionId: string): Instance?
			local library = runtime.EnemyTemplates
			if library == nil then
				return nil
			end
			local template = library:FindFirstChild(definitionId)
			if template and template:IsA("Model") and template.PrimaryPart ~= nil then
				return template
			end
			return nil
		end

	-- Seat a cloned production model on the marker: its horizontal centre over the marker and its base
	-- resting on the marker's top surface, from the model's real world AABB (so an arbitrary imported
	-- pivot or orientation still lands on the floor). Returns the model's world height for label offset.
	local function seatModelOnMarker(model: Model, marker: BasePart): number
		local mp = marker.Position
		model:PivotTo(CFrame.new(mp.X, mp.Y, mp.Z))
		local minY, maxY = math.huge, -math.huge
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				local cf, sz = part.CFrame, part.Size
				for x = -1, 1, 2 do
					for y = -1, 1, 2 do
						for z = -1, 1, 2 do
							local corner = cf * Vector3.new(x * sz.X / 2, y * sz.Y / 2, z * sz.Z / 2)
							minY = math.min(minY, corner.Y)
							maxY = math.max(maxY, corner.Y)
						end
					end
				end
			end
		end
		local baseY = mp.Y + marker.Size.Y / 2
		model:PivotTo(model:GetPivot() + Vector3.new(0, baseY - minY, 0))
		return maxY - minY
	end

	local function attachLabel(host: BasePart, offsetY: number, definitionId: string, level: any)
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Label"
		billboard.Size = UDim2.new(0, 160, 0, 28)
		billboard.StudsOffset = Vector3.new(0, offsetY, 0)
		billboard.AlwaysOnTop = true
		billboard.Parent = host
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeTransparency = 0
		label.TextScaled = true
		label.Text = enemyLabelText(definitionId, level)
		label.Parent = billboard
	end

	-- Builds the physical enemy body seated at (marker + horizontal spawnOffset) and returns it, the
	-- parts to fade on death, and the grounded pivot height Y (so the mover can keep the body on the
	-- floor as it roams). Uses the injected production template when one exists, else the provisional
	-- box; either way the body carries the RuntimeId/level attributes and the ENEMY_TAG, never a
	-- Humanoid. spawnOffset lets a whole population share one territory marker at spread-out points.
	local function buildEnemyModel(marker: BasePart, spawnOffset: Vector3, definitionId: string, state: any, container: Folder): (Model, { BasePart }, number)
		local model: Model
		local fadeParts: { BasePart } = {}
		local labelHost: BasePart
		local labelOffset: number

		local template = resolveTemplate(definitionId)
		if template then
			model = (template :: Model):Clone()
			model.Name = "Enemy_" .. definitionId
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = false
					table.insert(fadeParts, part)
				end
			end
			local height = seatModelOnMarker(model, marker)
			-- Spread this instance to its point within the territory, keeping it grounded.
			model:PivotTo(model:GetPivot() + Vector3.new(spawnOffset.X, 0, spawnOffset.Z))
			labelHost = model.PrimaryPart :: BasePart
			labelOffset = height / 2 + 1.5
		else
			model = Instance.new("Model")
			model.Name = "Enemy_" .. definitionId

			local body = Instance.new("Part")
			body.Name = "Body"
			body.Anchored = true
			body.CanCollide = false
			-- Provisional silhouettes so archetypes read as distinct even without production art: a tall
			-- red boss, a low elongated grey wolf, a green goblin/other.
			local isBoss = definitionId == "enemy_goblin_chieftain"
			local isWolf = definitionId == "enemy_wolf"
			body.Size = if isBoss then Vector3.new(6, 10, 6) elseif isWolf then Vector3.new(2.6, 3, 5) else Vector3.new(3, 5, 3)
			body.Color = if isBoss then Color3.fromRGB(120, 20, 20) elseif isWolf then Color3.fromRGB(85, 85, 95) else Color3.fromRGB(70, 130, 60)
			body.Material = Enum.Material.SmoothPlastic
			-- Sit the body on the marker (plus its territory offset) so its centre is above the floor.
			body.CFrame = marker.CFrame + Vector3.new(spawnOffset.X, body.Size.Y / 2, spawnOffset.Z)
			body.Parent = model
			model.PrimaryPart = body
			table.insert(fadeParts, body)
			labelHost = body
			labelOffset = body.Size.Y / 2 + 1.5
		end

		attachLabel(labelHost, labelOffset, definitionId, state.Level)

		model:SetAttribute(ATTR_ENEMY_DEFINITION_ID, definitionId)
		model:SetAttribute(ATTR_ENEMY_RUNTIME_ID, state.RuntimeId)
		model:SetAttribute(ATTR_ENEMY_LEVEL, state.Level)
		model:SetAttribute(ATTR_ENEMY_ALIVE, true)
		writeEnemyHealth(model, state)
		runtime.Collection:AddTag(model, ENEMY_TAG)
		model.Parent = container
		return model, fadeParts, model:GetPivot().Position.Y
	end

	-- A uniform-area random horizontal offset within a radius (server movement uses live math.random;
	-- determinism is only needed for the pure EnemyAI unit tests, which inject their own RNG).
	local function randomOffsetInRadius(radius: number): (number, number)
		local angle = math.random() * 2 * math.pi
		local r = math.sqrt(math.random()) * radius
		return math.cos(angle) * r, math.sin(angle) * r
	end

	local function freshMemory(): EnemyAI.Memory
		return { State = "Idle", RoamTarget = nil, PauseUntil = 0 }
	end

	-- Places an enemy at a fresh grounded point inside its territory and resets its behavioural brain.
	-- Used at first spawn and on respawn, so a killed enemy returns to its region (never popping back at
	-- the far-off spot where it died mid-chase) and populations don't all stack on one exact marker.
	local function seatInTerritory(record: EnemyRecord)
		local ox, oz = randomOffsetInRadius(record.Radius)
		record.BasePosition = Vector3.new(record.Home.X + ox, record.GroundY, record.Home.Z + oz)
		record.AIMemory = freshMemory()
		record.BobPhase = 0
		record.Model:PivotTo(CFrame.new(record.BasePosition))
	end

	local function rebindModel(record: EnemyRecord, state: any)
		record.RuntimeId = state.RuntimeId
		enemyModels[state.RuntimeId] = record.Model
		record.Model:SetAttribute(ATTR_ENEMY_RUNTIME_ID, state.RuntimeId)
		record.Model:SetAttribute(ATTR_ENEMY_LEVEL, state.Level)
		record.Model:SetAttribute(ATTR_ENEMY_ALIVE, true)
		-- A respawn rolls a fresh level, hence fresh MaxHealth/Health -- mirror the new authoritative state.
		writeEnemyHealth(record.Model, state)
		for _, part in record.FadeParts do
			part.Transparency = 0
		end
		-- A respawn may roll a new level, so refresh the visible billboard label to match.
		local body = record.Model.PrimaryPart
		if body then
			local billboard = body:FindFirstChild("Label")
			local label = billboard and billboard:FindFirstChildOfClass("TextLabel")
			if label then
				label.Text = enemyLabelText(record.DefinitionId, state.Level)
			end
		end
	end

	local function markDead(record: EnemyRecord, enemyCombat: EnemyCombat)
		record.Model:SetAttribute(ATTR_ENEMY_ALIVE, false)
		record.RespawnAt = runtime.Clock() + RESPAWN_SECONDS
		-- Drop provocation as soon as the enemy dies, not at the later respawn: a dead enemy has no
		-- active engagement, so retaliation must not linger through the respawn delay. Its cooldown and
		-- runtime->model mapping are cleared defensively at respawn, when the RuntimeId is retired.
		enemyCombat.ClearEnemy(record.RuntimeId)
		-- A dead enemy can never present positive health.
		record.Model:SetAttribute(ATTR_ENEMY_HEALTH, 0)
		for _, part in record.FadeParts do
			part.Transparency = 0.7
		end
	end

	local function respawn(record: EnemyRecord, enemies: Enemies, enemyCombat: EnemyCombat)
		local previousId = record.RuntimeId
		enemies.Remove(previousId)
		enemyModels[previousId] = nil
		-- The old RuntimeId is retired: drop its stale attack-cooldown timestamp and runtime->model
		-- mapping so a fresh instance starts clean. Provocation was already cleared at death (markDead);
		-- clearing it again here is defensive/idempotent, covering any path that retires an id directly.
		lastAttackAt[previousId] = nil
		enemyCombat.ClearEnemy(previousId)
		local state, reason = enemies.Create(record.DefinitionId)
		if not state then
			runtime.Warn(("[World] Respawn failed for %s: %s"):format(record.DefinitionId, tostring(reason)))
			return
		end
		rebindModel(record, state)
		-- Return to a fresh point inside the territory with a reset brain, rather than reviving in place.
		seatInTerritory(record)
		record.RespawnAt = nil
	end

	-- One shared, low-frequency settlement of every bound enemy against authoritative Alive state.
	local function pollDeaths(enemies: Enemies, enemyCombat: EnemyCombat)
		local now = runtime.Clock()
		for _, record in records do
			if record.RespawnAt ~= nil then
				if now >= record.RespawnAt then
					respawn(record, enemies, enemyCombat)
				end
			else
				local snapshot = enemies.GetSnapshot(record.RuntimeId)
				if snapshot then
					if snapshot.Alive == false then
						markDead(record, enemyCombat)
					else
						-- Mirror the authoritative current health onto the model so client target/boss bars
						-- track ongoing damage. Read-only: this never feeds back into the Enemies runtime.
						writeEnemyHealth(record.Model, snapshot)
					end
				end
			end
		end
	end

	-- One shared pass (same heartbeat as pollDeaths) that lets each alive enemy attack the nearest
	-- player within reach, gated by its cooldown. All gameplay authority (aggression, damage amount,
	-- Defense XP, death) lives in enemyCombat; World only decides "who is physically in range now" and
	-- turns a lethal result into the normal Roblox character respawn. No task-per-enemy.
	local function attackPass(enemies: Enemies, enemyCombat: EnemyCombat)
		local now = runtime.Clock()
		local players = runtime.Players:GetPlayers()
		if #players == 0 then
			return
		end
		for _, record in records do
			local body = record.Model.PrimaryPart
			if record.RespawnAt == nil and body and (now - (lastAttackAt[record.RuntimeId] or 0)) >= ENEMY_ATTACK_COOLDOWN then
				local snapshot = enemies.GetSnapshot(record.RuntimeId)
				if snapshot and snapshot.Alive then
					-- Every player physically in range, nearest first. The enemy attacks the nearest one
					-- it is actually engaged with (aggressive toward or provoked by); a closer passive,
					-- overleveled player is skipped rather than shielding an eligible one standing behind.
					local candidates: { { UserId: number, Root: BasePart, Distance: number } } = {}
					for _, player in players do
						local character = player.Character
						local root = character and character:FindFirstChild("HumanoidRootPart")
						if root and root:IsA("BasePart") then
							local distance = (root.Position - body.Position).Magnitude
							if distance <= ENEMY_ATTACK_RANGE then
								table.insert(candidates, { UserId = player.UserId, Root = root, Distance = distance })
							end
						end
					end
					local chosen, result = Service.SelectAttackTarget(candidates, function(userId: number)
						return enemyCombat.ResolveAttack(userId, snapshot)
					end)
					if chosen and result then
						-- The hit landed: rate-limit this enemy, and on a lethal hit trigger the normal
						-- character death/respawn (progression stays in PlayerData, untouched).
						lastAttackAt[record.RuntimeId] = now
						if (result :: any).Died then
							local humanoid = chosen.Root.Parent and chosen.Root.Parent:FindFirstChildOfClass("Humanoid")
							if humanoid then
								humanoid.Health = 0
							end
						end
					end
				end
			end
		end
	end

	-- One shared, server-authoritative movement pass over every enemy, driven by Heartbeat. For each
	-- awake enemy it asks the pure EnemyAI state machine what to do (roam / chase / return), then
	-- kinematically steps the anchored body toward the intent, keeping it grounded, facing its heading,
	-- with a gentle walk bob. Moving the model's pivot is the WHOLE integration: combat range, enemy
	-- melee, and the client all read the live pivot, so they stay consistent for free. This owns no
	-- gameplay outcome -- it never touches health, damage, aggression eligibility, or rewards.
	local function movePass(dt: number)
		if #records == 0 then
			return
		end
		local playerPositions: { Vector3 } = {}
		for _, player in runtime.Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				table.insert(playerPositions, root.Position)
			end
		end
		local now = runtime.Clock()
		for _, record in records do
			if record.RespawnAt == nil and record.Model.PrimaryPart ~= nil then
				local base = record.BasePosition
				-- Nearest player (flat) + sleep gate: an enemy with no player within activation range
				-- skips its brain entirely this frame.
				local nearest: Vector3? = nil
				local nearestDist: number? = nil
				for _, p in playerPositions do
					local dx, dz = p.X - base.X, p.Z - base.Z
					local d = math.sqrt(dx * dx + dz * dz)
					if nearestDist == nil or d < nearestDist then
						nearest = p
						nearestDist = d
					end
				end
				if nearestDist ~= nil and nearestDist <= ACTIVATION_RADIUS then
					local memory, intent = EnemyAI.Step(record.AIMemory, {
						Home = record.Home,
						Current = base,
						Now = now,
						NearestPlayer = nearest,
						NearestPlayerDistance = nearestDist,
						Config = record.AIConfig,
						Random = math.random,
					})
					record.AIMemory = memory

					local newBase = base
					local moving = false
					if intent.MoveTo ~= nil then
						local target = intent.MoveTo :: Vector3
						local dx, dz = target.X - base.X, target.Z - base.Z
						local dist = math.sqrt(dx * dx + dz * dz)
						if dist > 1e-3 then
							local step = math.min(intent.Speed * dt, dist)
							newBase = Vector3.new(base.X + dx / dist * step, record.GroundY, base.Z + dz / dist * step)
							moving = step > 1e-3
						end
					end
					record.BasePosition = newBase

					if moving then
						record.BobPhase += dt * intent.Speed * 0.6
					end
					local bobY = if moving then math.abs(math.sin(record.BobPhase)) * WALK_BOB_AMPLITUDE else 0
					local renderPos = Vector3.new(newBase.X, record.GroundY + bobY, newBase.Z)

					local cf: CFrame? = nil
					local facePos = intent.Face
					if facePos ~= nil then
						local fx = (facePos :: Vector3).X - renderPos.X
						local fz = (facePos :: Vector3).Z - renderPos.Z
						if fx * fx + fz * fz > 1e-4 then
							cf = CFrame.lookAt(renderPos, Vector3.new((facePos :: Vector3).X, renderPos.Y, (facePos :: Vector3).Z))
								* CFrame.Angles(0, math.rad(FACING_YAW_OFFSET), 0)
						end
					end
					if cf == nil then
						-- No new heading: keep the current facing, only translate (and bob).
						cf = record.Model:GetPivot().Rotation + renderPos
					end
					record.Model:PivotTo(cf)
				end
			end
		end
	end

	-- Spawns the enemy populations for every territory (and any legacy single-spawn marker), binds each
	-- to a repository runtime instance, starts the shared death poll, and -- when a Heartbeat is
	-- available -- the server-authoritative movement loop.
	function service.Start(enemies: Enemies, enemyCombat: EnemyCombat)
		assert(
			type(enemies) == "table"
				and type(enemies.Create) == "function"
				and type(enemies.GetSnapshot) == "function"
				and type(enemies.Remove) == "function",
			"World.Start requires the repository Enemies service"
		)
		assert(
			type(enemyCombat) == "table"
				and type(enemyCombat.ResolveAttack) == "function"
				and type(enemyCombat.OnSpawn) == "function"
				and type(enemyCombat.ClearEnemy) == "function",
			"World.Start requires the enemy-combat resolver"
		)

		-- Runtime health returns to full whenever a character (re)spawns. Hooking here (rather than a
		-- per-enemy or per-frame loop) keeps enemy death -> respawn -> full health a single clean path.
		local function hookPlayer(player: Player)
			enemyCombat.OnSpawn(player.UserId)
			player.CharacterAdded:Connect(function()
				enemyCombat.OnSpawn(player.UserId)
			end)
		end
		for _, player in runtime.Players:GetPlayers() do
			hookPlayer(player)
		end
		runtime.Players.PlayerAdded:Connect(hookPlayer)

		local container = runtime.Workspace:FindFirstChild("AR_Enemies")
		if not container then
			local created = Instance.new("Folder")
			created.Name = "AR_Enemies"
			created.Parent = runtime.Workspace
			container = created
		end

		-- Creates one enemy of definitionId belonging to a territory (home + radius + movement config),
		-- seated at a random point inside it, and registers its record with full movement state.
		local function spawnEnemy(definitionId: string, marker: BasePart, home: Vector3, radius: number, config: EnemyAI.Config)
			local state, reason = enemies.Create(definitionId)
			if not state then
				runtime.Warn(("[World] Enemy create failed for %s: %s"):format(definitionId, tostring(reason)))
				return
			end
			local ox, oz = randomOffsetInRadius(radius)
			local model, fadeParts, groundY = buildEnemyModel(marker, Vector3.new(ox, 0, oz), definitionId, state, container :: Folder)
			enemyModels[state.RuntimeId] = model
			local pivot = model:GetPivot().Position
			table.insert(records, {
				Model = model,
				Marker = marker,
				DefinitionId = definitionId,
				RuntimeId = state.RuntimeId,
				RespawnAt = nil,
				FadeParts = fadeParts,
				Home = home,
				Radius = radius,
				GroundY = groundY,
				BasePosition = Vector3.new(pivot.X, groundY, pivot.Z),
				AIConfig = config,
				AIMemory = freshMemory(),
				BobPhase = 0,
			})
		end

		-- Territories: a marker declares which archetype lives there, how many, and how far they roam.
		-- Each territory maintains a localized population that roams within (and leashes back to) it.
		for _, marker in runtime.Collection:GetTagged(ENEMY_TERRITORY_TAG) do
			if marker:IsA("BasePart") and isWorldContent(marker) then
				local definitionId = marker:GetAttribute(ATTR_ENEMY_DEFINITION_ID)
				if type(definitionId) ~= "string" or definitionId == "" then
					runtime.Warn(("[World] Territory %s has no %s attribute"):format(marker:GetFullName(), ATTR_ENEMY_DEFINITION_ID))
				else
					local radiusAttr = marker:GetAttribute(ATTR_TERRITORY_RADIUS)
					local radius = if type(radiusAttr) == "number" and radiusAttr > 0 then radiusAttr else DEFAULT_TERRITORY_RADIUS
					local populationAttr = marker:GetAttribute(ATTR_TERRITORY_POPULATION)
					local population = if type(populationAttr) == "number" and populationAttr >= 1 then math.floor(populationAttr) else DEFAULT_TERRITORY_POPULATION
					-- Roam covers the territory and leash extends a little past its edge, unless the marker
					-- overrides them explicitly; every other tuning value comes from EnemyAI defaults.
					local overrides: { [string]: number } = {}
					for _, key in TERRITORY_TUNING_KEYS do
						local value = marker:GetAttribute(key)
						if type(value) == "number" then
							overrides[key] = value
						end
					end
					if overrides.RoamRadius == nil then
						overrides.RoamRadius = radius
					end
					if overrides.LeashRadius == nil then
						overrides.LeashRadius = radius + TERRITORY_LEASH_BUFFER
					end
					local config = EnemyAI.ResolveConfig(overrides)
					local home = marker.Position
					for _ = 1, population do
						spawnEnemy(definitionId, marker, home, radius, config)
					end
				end
			end
		end

		-- Legacy single-enemy spawn markers still work: each becomes a one-member territory anchored at
		-- the marker, roaming with default tuning. (New world content uses territories instead.)
		for _, marker in runtime.Collection:GetTagged(ENEMY_SPAWN_TAG) do
			if marker:IsA("BasePart") and isWorldContent(marker) then
				local definitionId = marker:GetAttribute(ATTR_ENEMY_DEFINITION_ID)
				if type(definitionId) ~= "string" or definitionId == "" then
					runtime.Warn(("[World] Enemy spawn marker %s has no %s attribute"):format(marker:GetFullName(), ATTR_ENEMY_DEFINITION_ID))
				else
					spawnEnemy(definitionId, marker, marker.Position, 0, EnemyAI.ResolveConfig(nil))
				end
			end
		end

		runtime.Spawn(function()
			while true do
				runtime.Wait(DEATH_POLL_SECONDS)
				pollDeaths(enemies, enemyCombat)
				attackPass(enemies, enemyCombat)
			end
		end)

		-- Server-authoritative movement, when a per-frame signal is available (Studio runtime). Absent in
		-- headless tests, so enemies there stay put and only their combat/lifecycle facts are asserted.
		if runtime.Heartbeat ~= nil then
			runtime.Heartbeat:Connect(function(dt: number)
				movePass(dt)
			end)
		end
	end

	-- Read-only diagnostic view of the runtime-to-instance binding, for verification. Never a gameplay
	-- authority: it reports, it does not decide.
	function service.DescribeEnemies(): { { RuntimeId: string, DefinitionId: string, Alive: any, Health: any, MaxHealth: any, Position: { number } } }
		local out = {}
		for _, record in records do
			local body = record.Model.PrimaryPart
			local position = body and body.Position
			table.insert(out, {
				RuntimeId = record.RuntimeId,
				DefinitionId = record.DefinitionId,
				Alive = record.Model:GetAttribute(ATTR_ENEMY_ALIVE),
				-- The mirrored presentation health (a read-back of the attributes the client reads).
				Health = record.Model:GetAttribute(ATTR_ENEMY_HEALTH),
				MaxHealth = record.Model:GetAttribute(ATTR_ENEMY_MAX_HEALTH),
				Position = if position then { position.X, position.Y, position.Z } else { 0, 0, 0 },
			})
		end
		return out
	end

	return table.freeze(service)
end

return table.freeze(Service)
