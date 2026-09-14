--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(shared, "Missing ReplicatedStorage.Shared; check Script Sync mapping.")

local projectModule = shared:WaitForChild("Project", 10)
assert(projectModule and projectModule:IsA("ModuleScript"), "Missing Shared.Project ModuleScript; check Script Sync.")
local Project = require(projectModule)

local Store = require(script.Parent.PlayerData.Store)
local Service = require(script.Parent.PlayerData.Service)
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local storeName = if RunService:IsStudio() then "AdventurersRise_PlayerData_Development" else "AdventurersRise_PlayerData"
local store = Store.New(game:GetService("DataStoreService"):GetDataStore(storeName), {
	Now = os.time,
	Sleep = function(seconds) task.wait(seconds) end,
	NewToken = function() return HttpService:GenerateGUID(false) end,
})
local PlayerData = Service.New(store, {
	Players = game:GetService("Players"),
	Spawn = function(callback, ...) task.spawn(callback, ...) end,
	Wait = function(seconds) task.wait(seconds) end,
	Clock = os.clock,
	Now = os.time,
	BindToClose = function(callback) game:BindToClose(callback) end,
	Warn = warn,
})
PlayerData.Start()

print(("[%s] Server bootstrap ready"):format(Project.Name))
