--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")

local shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(shared, "Missing ReplicatedStorage.Shared; check Script Sync mapping.")

local projectModule = shared:WaitForChild("Project", 10)
assert(projectModule and projectModule:IsA("ModuleScript"), "Missing Shared.Project ModuleScript; check Script Sync.")
local Project = require(projectModule)

local Store = require(script.Parent.PlayerData.Store)
local PlayerDataService = require(script.Parent.PlayerData.Service)
local Composition = require(script.Parent.Composition.Service)
local WorldAdapters = require(script.Parent.Composition.WorldAdapters)

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

-- Combat and Gathering both require real physical-world information (attacker/target distance,
-- node eligibility) that this repository-only task cannot truthfully provide -- that is Studio-
-- context work for a later task. These placeholders satisfy Composition's injected contract while
-- clearly failing closed (never fabricating a fake target/node) until the real Studio-side
-- adapters are implemented and wired in here.
local worldAdapters = {
	CombatDistanceProvider = WorldAdapters.FailClosedCombatDistanceProvider(),
	GatheringNodeResolver = WorldAdapters.FailClosedGatheringNodeResolver(),
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
playerData.Start()

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
