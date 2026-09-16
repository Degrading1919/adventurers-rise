--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(shared, "Missing ReplicatedStorage.Shared; check Script Sync mapping.")

local projectModule = shared:WaitForChild("Project", 10)
assert(projectModule and projectModule:IsA("ModuleScript"), "Missing Shared.Project ModuleScript; check Script Sync.")
local Project = require(projectModule)

local Store = require(script.Parent.PlayerData.Store)
local PlayerDataService = require(script.Parent.PlayerData.Service)
local Composition = require(script.Parent.Composition.Service)
local World = require(script.Parent.World.Service)
local StarterKit = require(script.Parent.StarterKit.Service)

local storeName = if RunService:IsStudio() then "AdventurersRise_PlayerData_Development" else "AdventurersRise_PlayerData"
local store = Store.New(DataStoreService:GetDataStore(storeName), {
	Now = os.time,
	Sleep = function(seconds) task.wait(seconds) end,
	NewToken = function() return HttpService:GenerateGUID(false) end,
})
local playerData = PlayerDataService.New(store, {
	Players = Players,
	Spawn = function(callback, ...) task.spawn(callback, ...) end,
	Wait = function(seconds) task.wait(seconds) end,
	Clock = os.clock,
	Now = os.time,
	BindToClose = function(callback) game:BindToClose(callback) end,
	Warn = warn,
})

-- Combat and Gathering both require real physical-world information (attacker/target distance and
-- gathering-node resolution) that only the live Studio scene can answer. The World module reads that
-- scene server-side and binds physical enemy instances to repository Enemy runtime IDs. It owns no
-- gameplay outcome -- health, damage, Gold, and progression stay in the repository services; the
-- injected adapters below only report physical positions and instance identity.
local world = World.New({
	Players = Players,
	Workspace = Workspace,
	Collection = CollectionService,
	Clock = os.clock,
	Warn = warn,
	Spawn = function(callback, ...) task.spawn(callback, ...) end,
	Wait = function(seconds) task.wait(seconds) end,
})
local worldAdapters = {
	CombatDistanceProvider = world.CombatDistanceProvider,
	GatheringNodeResolver = world.GatheringNodeResolver,
}

local rng = Random.new()
local composition = Composition.New(playerData, {
	-- Monotonic process time for Combat cooldowns, request throttling, and active Gathering/
	-- Training session timing -- never compared against a persisted epoch timestamp.
	Clock = os.clock,
	-- Wall/epoch time, the same domain PlayerData's Store stamps LastSessionAt with. This is the
	-- only clock OfflineTraining may be constructed against.
	Now = os.time,
	NewInstanceId = function() return HttpService:GenerateGUID(false) end,
	NewRuntimeId = function() return HttpService:GenerateGUID(false) end,
	RollInteger = function(minimum: number, maximum: number) return rng:NextInteger(minimum, maximum) end,
	Roll01 = function() return rng:NextNumber() end,
	Warn = warn,
	Spawn = function(callback, ...) task.spawn(callback, ...) end,
	Wait = function(seconds) task.wait(seconds) end,
}, worldAdapters)

-- Composition's PlayerData-ready/unavailable subscriptions (and its periodic-settlement
-- heartbeat) must be registered before PlayerData.Start() begins loading any already-connected
-- players, so a player present at boot still gets an observed ready event and the automatic
-- offline-return claim.
composition.Start()

-- First-time starter kit: granted server-side, exactly once per player, and equipped only into
-- empty slots. Subscribed before PlayerData.Start() (like Composition) so a player already
-- connected at boot still receives it, and after composition.Start() so composition's own ready
-- handler runs first. Failures are logged and simply retried on the next ready session.
local starterKit = StarterKit.New(playerData, composition.Services.Inventory, composition.Services.Equipment)
playerData.OnReady(function(userId)
	local _, reason = starterKit.EnsureForUser(userId)
	if reason then
		warn(("[Bootstrap] Starter kit failed for %d: %s"):format(userId, tostring(reason)))
	end
end)

playerData.Start()

-- Bind the physical scene to repository Enemy runtime state: spawn the provisional Goblins and the
-- shared Chieftain at their tagged markers, map each physical instance to a repository runtime ID,
-- and run the minimal death/respawn behavior needed to validate the loop. Enemies is the authority;
-- the physical models are only its presentation.
world.Start(composition.Services.Enemies)

-- Studio-only diagnostic seam so MCP-driven verification can exercise the real server-authoritative
-- request path and seed a test player through the real services. Guarded to Studio, so it never
-- exists in a live server, and it exposes only the same composition/world already constructed above
-- -- it introduces no second gameplay authority.
if RunService:IsStudio() then
	_G.__AdventurersRiseServer = { Composition = composition, World = world }
end

-- The one trusted client/server request boundary (see Composition/RequestIds.luau for the stable
-- request IDs). This callback does nothing but translate the server-provided Player into a userId
-- and forward to Composition.HandleRequest -- all validation/routing logic lives there, decoupled
-- from this Roblox transport object, so it can be exercised in tests without Studio.
local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = ReplicatedStorage

local request = Instance.new("RemoteFunction")
request.Name = "Request"
request.Parent = remotes
request.OnServerInvoke = function(player: Player, requestId: any, payload: any)
	return composition.HandleRequest(player.UserId, requestId, payload)
end

print(("[%s] Server bootstrap ready"):format(Project.Name))
