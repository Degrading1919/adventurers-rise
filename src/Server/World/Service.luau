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

-- Attribute keys (stable identifiers, never display names).
local ATTR_ENEMY_DEFINITION_ID = "EnemyDefinitionId"
local ATTR_ENEMY_RUNTIME_ID = "EnemyRuntimeId"
local ATTR_ENEMY_LEVEL = "EnemyLevel"
local ATTR_ENEMY_ALIVE = "EnemyAlive"
local ATTR_GATHERING_NODE_ID = "GatheringNodeId"

-- Provisional respawn cadence and a low-frequency death poll. Event-driven death is not exposed by
-- the repository Enemies service, so a single shared poll re-reads authoritative Alive state; this is
-- intentionally minimal, not a general AI/spawning framework.
local RESPAWN_SECONDS = 5
local DEATH_POLL_SECONDS = 0.5

export type Enemies = {
	read Create: (string) -> (any?, string?),
	read GetSnapshot: (string) -> (any?, string?),
	read Remove: (string) -> (any?, string?),
}

export type Runtime = {
	read Players: Players,
	read Workspace: Workspace,
	read Collection: CollectionService,
	read Clock: () -> number,
	read Warn: (string) -> (),
	read Spawn: ((...any) -> (), ...any) -> (),
	read Wait: (number) -> (),
}

type EnemyRecord = {
	Model: Model,
	Marker: BasePart,
	DefinitionId: string,
	RuntimeId: string,
	RespawnAt: number?,
}

local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
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
			if instance:IsA("BasePart") and instance.Parent and instance:GetAttribute(ATTR_GATHERING_NODE_ID) == nodeId then
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

	local function buildEnemyModel(marker: BasePart, definitionId: string, state: any, container: Folder): Model
		local model = Instance.new("Model")
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

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Label"
		billboard.Size = UDim2.new(0, 160, 0, 28)
		billboard.StudsOffset = Vector3.new(0, body.Size.Y / 2 + 1.5, 0)
		billboard.AlwaysOnTop = true
		billboard.Parent = body
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeTransparency = 0
		label.TextScaled = true
		label.Text = (if isBoss then "Goblin Chieftain" else "Goblin") .. " Lv" .. tostring(state.Level)
		label.Parent = billboard

		model:SetAttribute(ATTR_ENEMY_DEFINITION_ID, definitionId)
		model:SetAttribute(ATTR_ENEMY_RUNTIME_ID, state.RuntimeId)
		model:SetAttribute(ATTR_ENEMY_LEVEL, state.Level)
		model:SetAttribute(ATTR_ENEMY_ALIVE, true)
		runtime.Collection:AddTag(model, ENEMY_TAG)
		model.Parent = container
		return model
	end

	local function rebindModel(record: EnemyRecord, state: any)
		record.RuntimeId = state.RuntimeId
		enemyModels[state.RuntimeId] = record.Model
		record.Model:SetAttribute(ATTR_ENEMY_RUNTIME_ID, state.RuntimeId)
		record.Model:SetAttribute(ATTR_ENEMY_LEVEL, state.Level)
		record.Model:SetAttribute(ATTR_ENEMY_ALIVE, true)
		local body = record.Model.PrimaryPart
		if body then
			body.Transparency = 0
		end
	end

	local function markDead(record: EnemyRecord)
		record.Model:SetAttribute(ATTR_ENEMY_ALIVE, false)
		record.RespawnAt = runtime.Clock() + RESPAWN_SECONDS
		local body = record.Model.PrimaryPart
		if body then
			body.Transparency = 0.7
		end
	end

	local function respawn(record: EnemyRecord, enemies: Enemies)
		local previousId = record.RuntimeId
		enemies.Remove(previousId)
		enemyModels[previousId] = nil
		local state, reason = enemies.Create(record.DefinitionId)
		if not state then
			runtime.Warn(("[World] Respawn failed for %s: %s"):format(record.DefinitionId, tostring(reason)))
			return
		end
		rebindModel(record, state)
		record.RespawnAt = nil
	end

	-- One shared, low-frequency settlement of every bound enemy against authoritative Alive state.
	local function pollDeaths(enemies: Enemies)
		local now = runtime.Clock()
		for _, record in records do
			if record.RespawnAt ~= nil then
				if now >= record.RespawnAt then
					respawn(record, enemies)
				end
			else
				local snapshot = enemies.GetSnapshot(record.RuntimeId)
				if snapshot and snapshot.Alive == false then
					markDead(record)
				end
			end
		end
	end

	-- Spawns the provisional physical enemies at every tagged marker, creating one repository runtime
	-- instance per marker and binding it to the physical model, then starts the shared death poll.
	function service.Start(enemies: Enemies)
		assert(
			type(enemies) == "table"
				and type(enemies.Create) == "function"
				and type(enemies.GetSnapshot) == "function"
				and type(enemies.Remove) == "function",
			"World.Start requires the repository Enemies service"
		)

		local container = runtime.Workspace:FindFirstChild("AR_Enemies")
		if not container then
			local created = Instance.new("Folder")
			created.Name = "AR_Enemies"
			created.Parent = runtime.Workspace
			container = created
		end

		for _, marker in runtime.Collection:GetTagged(ENEMY_SPAWN_TAG) do
			if marker:IsA("BasePart") then
				local definitionId = marker:GetAttribute(ATTR_ENEMY_DEFINITION_ID)
				if type(definitionId) ~= "string" or definitionId == "" then
					runtime.Warn(("[World] Enemy spawn marker %s has no %s attribute"):format(marker:GetFullName(), ATTR_ENEMY_DEFINITION_ID))
				else
					local state, reason = enemies.Create(definitionId)
					if not state then
						runtime.Warn(("[World] Enemy create failed for %s: %s"):format(definitionId, tostring(reason)))
					else
						local model = buildEnemyModel(marker, definitionId, state, container :: Folder)
						enemyModels[state.RuntimeId] = model
						table.insert(records, {
							Model = model,
							Marker = marker,
							DefinitionId = definitionId,
							RuntimeId = state.RuntimeId,
							RespawnAt = nil,
						})
					end
				end
			end
		end

		runtime.Spawn(function()
			while true do
				runtime.Wait(DEATH_POLL_SECONDS)
				pollDeaths(enemies)
			end
		end)
	end

	-- Read-only diagnostic view of the runtime-to-instance binding, for verification. Never a gameplay
	-- authority: it reports, it does not decide.
	function service.DescribeEnemies(): { { RuntimeId: string, DefinitionId: string, Alive: any, Position: { number } } }
		local out = {}
		for _, record in records do
			local body = record.Model.PrimaryPart
			local position = if body then body.Position else Vector3.zero
			table.insert(out, {
				RuntimeId = record.RuntimeId,
				DefinitionId = record.DefinitionId,
				Alive = record.Model:GetAttribute(ATTR_ENEMY_ALIVE),
				Position = { position.X, position.Y, position.Z },
			})
		end
		return out
	end

	return table.freeze(service)
end

return table.freeze(Service)
