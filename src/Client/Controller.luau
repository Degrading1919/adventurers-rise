--!strict

-- Ties player input and the physical scene to the trusted request boundary. It only SELECTS targets
-- and REQUESTS actions; the server owns every outcome. Proximity, targeting, and displayed distances
-- are presentation conveniences -- the server independently re-derives real distance, elapsed time,
-- rewards, tiers, and eligibility and is free to reject anything here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RequestIds = require(Shared:WaitForChild("RequestIds"))
local GatheringNodeIds = require(Shared:WaitForChild("GatheringNodeIds"))
local AscensionIds = require(Shared:WaitForChild("AscensionIds"))
local EquipmentSlots = require(Shared:WaitForChild("EquipmentSlots"))

local INTERACT_RADIUS = 14
local TARGET_RADIUS = 60
local ATTACK_INTERVAL = 0.4
local REFRESH_INTERVAL = 1
local PROXIMITY_INTERVAL = 0.2

local ENEMY_TAG = "AR_Enemy"
local NODE_TAG = "AR_GatheringNode"
local STATION_TAG = "AR_TrainingStation"
local FORGE_TAG = "AR_Forge"

local Controller = {}

local function reasonText(reason: any): string
	return if type(reason) == "string" then reason else "Failed"
end

function Controller.New(player: Player, net: any, iface: any)
	local controller = {}

	local miningActive = false
	local trainingActive = false
	local attackActive = false
	local currentStationId: string? = nil
	local currentTarget: string? = nil
	local currentTargetLabel: string? = nil

	local function rootPosition(): Vector3?
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root.Position
		end
		return nil
	end

	local function refresh()
		local ok, result = net.Request(RequestIds.StateGet, nil)
		if ok and type(result) == "table" then
			iface.Update(result)
			return result
		end
		return nil
	end
	controller.Refresh = refresh

	-- ===== Nearest-instance scans (presentation only) =====
	local function nearestTagged(tag: string, position: Vector3, radius: number): (Instance?, number?)
		local best: Instance? = nil
		local bestDist: number? = nil
		for _, inst in CollectionService:GetTagged(tag) do
			if inst:IsDescendantOf(workspace) then
				local pos: Vector3? = nil
				if inst:IsA("BasePart") then
					pos = inst.Position
				elseif inst:IsA("Model") then
					pos = inst:GetPivot().Position
				end
				if pos then
					local d = (position - pos).Magnitude
					if d <= radius and (bestDist == nil or d < bestDist) then
						best = inst
						bestDist = d
					end
				end
			end
		end
		return best, bestDist
	end

	local function nearestEnemy(position: Vector3): (string?, string?, number?)
		local bestId: string? = nil
		local bestLabel: string? = nil
		local bestDist: number? = nil
		for _, model in CollectionService:GetTagged(ENEMY_TAG) do
			if model:IsA("Model") and model:IsDescendantOf(workspace) and model:GetAttribute("EnemyAlive") ~= false then
				local runtimeId = model:GetAttribute("EnemyRuntimeId")
				if type(runtimeId) == "string" and runtimeId ~= "" then
					local d = (position - model:GetPivot().Position).Magnitude
					if d <= TARGET_RADIUS and (bestDist == nil or d < bestDist) then
						bestId = runtimeId
						local defId = model:GetAttribute("EnemyDefinitionId")
						local level = model:GetAttribute("EnemyLevel")
						bestLabel = (if defId == "enemy_goblin_chieftain" then "Goblin Chieftain" else "Goblin") .. (if level then " Lv" .. tostring(level) else "")
						bestDist = d
					end
				end
			end
		end
		return bestId, bestLabel, bestDist
	end

	-- ===== Proximity / targeting loop =====
	local proximityAccum = 0
	RunService.Heartbeat:Connect(function(dt)
		proximityAccum += dt
		if proximityAccum < PROXIMITY_INTERVAL then return end
		proximityAccum = 0
		local position = rootPosition()
		if not position then
			iface.SetContext({ TrainingActive = trainingActive, MiningActive = miningActive })
			return
		end
		local station = nearestTagged(STATION_TAG, position, INTERACT_RADIUS)
		local node = nearestTagged(NODE_TAG, position, INTERACT_RADIUS)
		local forge = nearestTagged(FORGE_TAG, position, INTERACT_RADIUS)
		currentStationId = if station then station:GetAttribute("StationId") else nil

		local targetId, targetLabel = nearestEnemy(position)
		currentTarget = targetId
		currentTargetLabel = targetLabel

		iface.SetContext({
			NearStationId = currentStationId,
			NearNode = node ~= nil,
			NearForge = forge ~= nil,
			TrainingActive = trainingActive,
			MiningActive = miningActive,
		})

		-- Keep client mining state honest: if we drift out of range while mining, end it so the
		-- server session and the UI agree (the server also fails such a session closed on settle).
		if miningActive and node == nil then
			net.Request(RequestIds.GatheringEnd, nil)
			miningActive = false
			iface.SetStatus("Mining stopped (left the node).")
			refresh()
		end
	end)

	-- ===== Attack (hold) =====
	iface.Handlers.AttackDown = function()
		if attackActive then return end
		attackActive = true
		task.spawn(function()
			while attackActive do
				if currentTarget then
					local ok, _, reason = net.Request(RequestIds.CombatMeleeAttack, { TargetId = currentTarget })
					if ok then
						iface.SetStatus(("Hit %s"):format(currentTargetLabel or "target"))
						refresh()
					elseif reason == "TargetOutOfRange" then
						iface.SetStatus(("%s is out of range -- move closer"):format(currentTargetLabel or "Target"))
					elseif reason ~= "AttackOnCooldown" then
						iface.SetStatus("Attack: " .. reasonText(reason))
					end
				else
					iface.SetStatus("No enemy nearby")
				end
				task.wait(ATTACK_INTERVAL)
			end
		end)
	end
	iface.Handlers.AttackUp = function()
		attackActive = false
	end

	-- ===== Mining toggle =====
	iface.Handlers.MineToggle = function()
		if miningActive then
			net.Request(RequestIds.GatheringEnd, nil)
			miningActive = false
			iface.SetStatus("Mining stopped.")
			refresh()
		else
			local ok, _, reason = net.Request(RequestIds.GatheringBegin, { NodeId = GatheringNodeIds.IronOre })
			if ok then
				miningActive = true
				iface.SetStatus("Mining Iron Ore...")
			else
				iface.SetStatus("Mine: " .. reasonText(reason))
			end
			refresh()
		end
	end

	-- ===== Training toggle =====
	iface.Handlers.TrainToggle = function()
		if trainingActive then
			net.Request(RequestIds.TrainingEnd, nil)
			trainingActive = false
			iface.SetStatus("Training stopped.")
			refresh()
		else
			if not currentStationId then
				iface.SetStatus("Stand on a training station first.")
				return
			end
			local ok, _, reason = net.Request(RequestIds.TrainingBegin, { StationId = currentStationId })
			if ok then
				trainingActive = true
				iface.SetStatus("Training...")
			else
				iface.SetStatus("Train: " .. reasonText(reason))
			end
			refresh()
		end
	end

	-- ===== Station upgrade =====
	iface.Handlers.Upgrade = function()
		if not currentStationId then
			iface.SetStatus("Stand on a training station to upgrade it.")
			return
		end
		local ok, _, reason = net.Request(RequestIds.PlotUpgradeStation, { StationId = currentStationId })
		iface.SetStatus(if ok then "Station upgraded." else ("Upgrade: " .. reasonText(reason)))
		refresh()
	end

	-- ===== Forge crafting =====
	iface.Handlers.ForgeCraft = function(recipeId: string)
		local ok, _, reason = net.Request(RequestIds.CraftingCraft, { RecipeId = recipeId })
		iface.SetStatus(if ok then "Smithing succeeded." else ("Smith: " .. reasonText(reason)))
		refresh()
	end

	-- ===== Equip =====
	iface.Handlers.Equip = function(instanceId: string)
		local ok, _, reason = net.Request(RequestIds.EquipmentEquip, { SlotId = EquipmentSlots.Weapon, InstanceId = instanceId })
		iface.SetStatus(if ok then "Equipped." else ("Equip: " .. reasonText(reason)))
		refresh()
	end

	-- ===== Ascend =====
	iface.Handlers.Ascend = function()
		local ok, _, reason = net.Request(RequestIds.AscensionAscend, { RankId = AscensionIds.Adept })
		iface.SetStatus(if ok then "Ascended to Adept!" else ("Ascend: " .. reasonText(reason)))
		refresh()
	end

	-- ===== Startup: wait for a ready session, then poll state =====
	function controller.Start()
		task.spawn(function()
			while true do
				local state = refresh()
				if state then
					local ret = state.OfflineReturn
					if ret and ret.Rewarded and ret.AwardedXP and ret.AwardedXP > 0 then
						iface.SetStatus(("Offline training added %s XP while away."):format(tostring(ret.AwardedXP)))
					end
					break
				end
				iface.SetStatus("Connecting to server...")
				task.wait(0.5)
			end
			while true do
				task.wait(REFRESH_INTERVAL)
				refresh()
			end
		end)
	end

	return controller
end

return Controller
