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

local ENEMY_SPAWN_TAG = "AR_EnemySpawn"
local ENEMY_TAG = "AR_Enemy"
local GATHERING_NODE_TAG = "AR_GatheringNode"
local TRAINING_STATION_TAG = "AR_TrainingStation"
local FORGE_TAG = "AR_Forge"
local SHOP_TAG = "AR_Shop"

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
		local displayName = if definitionId == "enemy_goblin_chieftain" then "Goblin Chieftain" else "Goblin"
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

	-- Builds the physical enemy body at a marker and returns it plus the parts to fade on death. Uses
	-- the injected production template when one exists, else the provisional box; either way the body
	-- carries the RuntimeId/level attributes and the ENEMY_TAG, and never a Humanoid.
	local function buildEnemyModel(marker: BasePart, definitionId: string, state: any, container: Folder): (Model, { BasePart })
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
			labelHost = model.PrimaryPart :: BasePart
			labelOffset = height / 2 + 1.5
		else
			model = Instance.new("Model")
			model.Name = "Enemy_" .. definitionId

			local body = Instance.new("Part")
			body.Name = "Body"
			body.Anchored = true
			body.CanCollide = false
			local isBoss = definitionId == "enemy_goblin_chieftain"
			body.Size = if isBoss then Vector3.new(6, 10, 6) else Vector3.new(3, 5, 3)
			body.Color = if isBoss then Color3.fromRGB(120, 20, 20) else Color3.fromRGB(70, 130, 60)
			body.Material = Enum.Material.SmoothPlastic
			-- Sit the body on the marker so its center is above the floor.
			body.CFrame = marker.CFrame + Vector3.new(0, body.Size.Y / 2, 0)
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
		return model, fadeParts
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

	-- Spawns the provisional physical enemies at every tagged marker, creating one repository runtime
	-- instance per marker and binding it to the physical model, then starts the shared death poll.
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

		for _, marker in runtime.Collection:GetTagged(ENEMY_SPAWN_TAG) do
			if marker:IsA("BasePart") and isWorldContent(marker) then
				local definitionId = marker:GetAttribute(ATTR_ENEMY_DEFINITION_ID)
				if type(definitionId) ~= "string" or definitionId == "" then
					runtime.Warn(("[World] Enemy spawn marker %s has no %s attribute"):format(marker:GetFullName(), ATTR_ENEMY_DEFINITION_ID))
				else
					local state, reason = enemies.Create(definitionId)
					if not state then
						runtime.Warn(("[World] Enemy create failed for %s: %s"):format(definitionId, tostring(reason)))
					else
						local model, fadeParts = buildEnemyModel(marker, definitionId, state, container :: Folder)
						enemyModels[state.RuntimeId] = model
						table.insert(records, {
							Model = model,
							Marker = marker,
							DefinitionId = definitionId,
							RuntimeId = state.RuntimeId,
							RespawnAt = nil,
							FadeParts = fadeParts,
						})
					end
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
