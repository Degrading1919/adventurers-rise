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
local EventIds = require(Shared:WaitForChild("EventIds"))

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
	local trainingStationId: string? = nil
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

		-- Mirror the server's authoritative training proximity: leaving the station we are training
		-- at (or wandering to a different one) stops the session. The server also clears it on its
		-- next settlement; ending here keeps the UI honest and immediate.
		if trainingActive and currentStationId ~= trainingStationId then
			net.Request(RequestIds.TrainingEnd, nil)
			trainingActive = false
			trainingStationId = nil
			iface.SetStatus("Training stopped (left the station).")
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
			trainingStationId = nil
			iface.SetStatus("Training stopped.")
			refresh()
		else
			if not currentStationId then
				iface.SetStatus("Stand on a training station first.")
				return
			end
			local stationId = currentStationId
			local ok, _, reason = net.Request(RequestIds.TrainingBegin, { StationId = stationId })
			if ok then
				trainingActive = true
				trainingStationId = stationId
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

	-- ===== Forge crafting (single / batch / max) =====
	-- The client forwards the chosen recipe and requested batch shape only. The server validates the
	-- quantity, computes Craft Max from authoritative state, and owns all consumption/output/XP.
	iface.Handlers.ForgeCraft = function(recipeId: string, request: { Quantity: number?, Max: boolean? }?)
		local payload: { RecipeId: string, Quantity: number?, Max: boolean? } = { RecipeId = recipeId }
		if type(request) == "table" then
			if request.Max == true then
				payload.Max = true
			elseif type(request.Quantity) == "number" then
				payload.Quantity = request.Quantity
			end
		end
		local ok, result, reason = net.Request(RequestIds.CraftingCraft, payload)
		if ok and type(result) == "table" and type(result.Quantity) == "number" then
			iface.SetStatus(("Crafted x%d."):format(result.Quantity))
		else
			iface.SetStatus(if ok then "Crafted." else ("Smith: " .. reasonText(reason)))
		end
		refresh()
	end

	-- ===== Equip (any slot) =====
	iface.Handlers.Equip = function(slotId: string, instanceId: string)
		local ok, _, reason = net.Request(RequestIds.EquipmentEquip, { SlotId = slotId, InstanceId = instanceId })
		iface.SetStatus(if ok then "Equipped." else ("Equip: " .. reasonText(reason)))
		refresh()
	end

	-- ===== Mastery (select / respec) =====
	-- The read model carries the authoritative Mastery state (points, node states, respec free/cost);
	-- the client only forwards select/respec intent through the existing requests and re-reads state.
	iface.Handlers.SelectMastery = function(skillId: string, nodeId: string)
		local ok, _, reason = net.Request(RequestIds.MasterySelectNode, { SkillId = skillId, NodeId = nodeId })
		iface.SetStatus(if ok then "Mastery node selected." else ("Mastery: " .. reasonText(reason)))
		refresh()
	end
	iface.Handlers.RespecMastery = function(skillId: string)
		local ok, _, reason = net.Request(RequestIds.MasteryRespec, { SkillId = skillId })
		iface.SetStatus(if ok then "Mastery respec applied." else ("Respec: " .. reasonText(reason)))
		refresh()
	end

	-- ===== Shop (buy / sell) =====
	-- The server owns prices, Gold, and validation; the client forwards the chosen catalog action only.
	iface.Handlers.ShopBuy = function(catalogId: string, definitionId: string, amount: number)
		local ok, _, reason = net.Request(RequestIds.EconomyPurchaseStack, { CatalogId = catalogId, DefinitionId = definitionId, Amount = amount })
		iface.SetStatus(if ok then "Purchased." else ("Buy: " .. reasonText(reason)))
		refresh()
	end
	iface.Handlers.ShopSell = function(catalogId: string, definitionId: string, amount: number)
		local ok, _, reason = net.Request(RequestIds.EconomySellStack, { CatalogId = catalogId, DefinitionId = definitionId, Amount = amount })
		iface.SetStatus(if ok then "Sold." else ("Sell: " .. reasonText(reason)))
		refresh()
	end
	iface.Handlers.ShopBuyDiscrete = function(catalogId: string, definitionId: string)
		local ok, _, reason = net.Request(RequestIds.EconomyPurchaseDiscrete, { CatalogId = catalogId, DefinitionId = definitionId })
		iface.SetStatus(if ok then "Purchased." else ("Buy: " .. reasonText(reason)))
		refresh()
	end
	-- Sells a specific owned discrete item instance; the server validates ownership, the catalog sell
	-- price, and rejects an equipped/invalid item. The client never sends a price.
	iface.Handlers.ShopSellDiscrete = function(catalogId: string, instanceId: string)
		local ok, _, reason = net.Request(RequestIds.EconomySellDiscrete, { CatalogId = catalogId, InstanceId = instanceId })
		iface.SetStatus(if ok then "Sold." else ("Sell: " .. reasonText(reason)))
		refresh()
	end

	-- ===== Ascend =====
	iface.Handlers.Ascend = function()
		local ok, _, reason = net.Request(RequestIds.AscensionAscend, { RankId = AscensionIds.Adept })
		iface.SetStatus(if ok then "Ascended to Adept!" else ("Ascend: " .. reasonText(reason)))
		refresh()
	end

	-- ===== Offline training focus =====
	-- The player explicitly chooses which supported skill (Melee/Defense) trains while offline. The
	-- server owns validation, rates, the cap, and the claim; the client only forwards the choice and
	-- re-reads authoritative state (which carries the selected focus back for display).
	iface.Handlers.SetOfflineFocus = function(skillId: string)
		local ok, _, reason = net.Request(RequestIds.OfflineTrainingSetFocus, { SkillId = skillId })
		iface.SetStatus(if ok then "Offline focus updated." else ("Offline focus: " .. reasonText(reason)))
		refresh()
	end

	-- ===== Server -> client presentation events =====
	-- Receive pushed, sanitized player-specific outcomes and present them. This is display only: the
	-- client cannot send on this channel, and it never grants anything from a received event.
	net.OnEvent(function(eventId: string, payload: any)
		if eventId == EventIds.BossPersonalReward then
			iface.ShowBossReward(payload)
			-- The reward already changed authoritative state server-side; re-read so the HUD reflects it.
			refresh()
		end
	end)

	-- ===== Startup: wait for a ready session, then poll state =====
	function controller.Start()
		task.spawn(function()
			while true do
				local state = refresh()
				if state then
					local ret = state.OfflineReturn
					if ret and ret.Rewarded and ret.XPAwarded and ret.XPAwarded > 0 then
						iface.SetStatus(("Offline training added %d XP while away."):format(math.floor(ret.XPAwarded + 0.5)))
						-- Surface the compact While You Were Away summary on rejoin.
						iface.OpenOfflineReturn()
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
