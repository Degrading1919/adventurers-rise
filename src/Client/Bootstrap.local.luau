--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(shared, "Missing ReplicatedStorage.Shared; check Script Sync mapping.")

local projectModule = shared:WaitForChild("Project", 10)
assert(projectModule and projectModule:IsA("ModuleScript"), "Missing Shared.Project ModuleScript; check Script Sync.")
local Project = require(projectModule)

local Net = require(script.Parent:WaitForChild("Net"))
local Interface = require(script.Parent:WaitForChild("Interface"))
local Controller = require(script.Parent:WaitForChild("Controller"))

local player = Players.LocalPlayer

-- Provisional vertical-slice client: HUD + interaction surface over the trusted request boundary.
local net = Net.New()
local interface = Interface.New(player)
local controller = Controller.New(player, net, interface)
controller.Start()

print(("[%s] Client bootstrap ready"):format(Project.Name))
