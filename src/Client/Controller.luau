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

function Controller.New(player: Player, net: any, iface: any, equipmentVisuals: any?)
	local controller = {}

	local miningActive = false
	local trainingActive = false
	local trainingStationId: string? = nil
	local attackActive = false
	local currentStationId: string? = nil
	local currentTarget: string? = nil
	local currentTargetLabel: string? = nil
	-- The model of the current combat target, so the objective highlight and combat-target indicator
	-- can coexist (the combat indicator owns the model when they would otherwise overlap).
	local currentTargetModel: Instance? = nil
	-- The current onboarding objective's world target (sanitized read-model hint), used only to
	-- highlight the relevant nearby object. Presentation-only: it never decides step completion.
	local objectiveTarget: any = nil

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
			-- Presentation-only: reflect the authoritative equipped items on the local character.
			if equipmentVisuals then
				equipmentVisuals.Apply(result.Equipment)
			end
			-- Presentation-only guidance hint for the current objective (highlighted in the proximity loop).
			objectiveTarget = if type(result.Onboarding) == "table" and result.Onboarding.Complete ~= true then result.Onboarding.Target else nil
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

	local BOSS_DEFINITION_ID = "enemy_goblin_chieftain"
	local BOSS_ENGAGE_RADIUS = 90

	local function enemyName(defId: any, level: any): string
		return (if defId == BOSS_DEFINITION_ID then "Goblin Chieftain" else "Goblin") .. (if level then " Lv" .. tostring(level) else "")
	end
	-- Reads an enemy's presentation facts from the authoritative attributes World mirrors onto the model.
	-- The client only READS these; it never computes, predicts, or writes enemy health.
	local function enemyInfo(model: Instance): any
		return {
			RuntimeId = model:GetAttribute("EnemyRuntimeId"),
			DefinitionId = model:GetAttribute("EnemyDefinitionId"),
			Level = model:GetAttribute("EnemyLevel"),
			Health = model:GetAttribute("EnemyHealth"),
			MaxHealth = model:GetAttribute("EnemyMaxHealth"),
			Model = model,
		}
	end

	-- One pass over alive enemy models: the nearest overall is the current soft-target; the nearest alive
	-- Chieftain within engage range is the boss. Returns both (either may be nil).
	local function scanCombat(position: Vector3): (any?, any?)
		local target: any = nil
		local targetDist: number? = nil
		local boss: any = nil
		local bossDist: number? = nil
		for _, model in CollectionService:GetTagged(ENEMY_TAG) do
			if model:IsA("Model") and model:IsDescendantOf(workspace) and model:GetAttribute("EnemyAlive") ~= false then
				local runtimeId = model:GetAttribute("EnemyRuntimeId")
				if type(runtimeId) == "string" and runtimeId ~= "" then
					local d = (position - model:GetPivot().Position).Magnitude
					if d <= TARGET_RADIUS and (targetDist == nil or d < targetDist) then
						target = enemyInfo(model)
						targetDist = d
					end
					if model:GetAttribute("EnemyDefinitionId") == BOSS_DEFINITION_ID and d <= BOSS_ENGAGE_RADIUS and (bossDist == nil or d < bossDist) then
						boss = enemyInfo(model)
						bossDist = d
					end
				end
			end
		end
		return target, boss
	end

	-- ===== Objective guidance highlight (presentation-only) =====
	-- Subtly highlights the nearest world object relevant to the CURRENT objective only. It never
	-- decides completion; the server owns that. Enemies are tagged models; static world objects are
	-- invisible anchor parts carrying a "Visual" mesh child, so we adorn the visible mesh when present.
	local GUIDE_RADIUS = 90
	local guidanceHighlight = Instance.new("Highlight")
	guidanceHighlight.Name = "AR_ObjectiveGuide"
	guidanceHighlight.FillColor = Color3.fromRGB(120, 180, 255)
	guidanceHighlight.FillTransparency = 0.8
	guidanceHighlight.OutlineColor = Color3.fromRGB(150, 205, 255)
	guidanceHighlight.OutlineTransparency = 0
	guidanceHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	guidanceHighlight.Enabled = false
	guidanceHighlight.Parent = workspace

	-- Distinct combat-target indicator (warm tint) so it never fights the cool objective-guidance
	-- highlight over the same presentation object; when both would pick the same model, guidance yields.
	local targetHighlight = Instance.new("Highlight")
	targetHighlight.Name = "AR_CombatTarget"
	targetHighlight.FillColor = Color3.fromRGB(255, 120, 120)
	targetHighlight.FillTransparency = 0.85
	targetHighlight.OutlineColor = Color3.fromRGB(255, 165, 165)
	targetHighlight.OutlineTransparency = 0
	targetHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	targetHighlight.Enabled = false
	targetHighlight.Parent = workspace

	local function adorneeFor(inst: Instance): Instance?
		local visual = inst:FindFirstChild("Visual")
		if visual and visual:IsA("Model") then
			return visual
		end
		if inst:IsA("Model") or inst:IsA("BasePart") then
			return inst
		end
		return nil
	end
	local function positionOf(inst: Instance): Vector3?
		if inst:IsA("Model") then
			return inst:GetPivot().Position
		elseif inst:IsA("BasePart") then
			return inst.Position
		end
		return nil
	end
	local function updateGuidance(position: Vector3?)
		local target = objectiveTarget
		if not position or type(target) ~= "table" or type(target.Tag) ~= "string" then
			guidanceHighlight.Enabled = false
			guidanceHighlight.Adornee = nil
			return
		end
		local best: Instance? = nil
		local bestDist: number? = nil
		for _, inst in CollectionService:GetTagged(target.Tag) do
			if inst:IsDescendantOf(workspace) then
				local matches = target.MatchAttribute == nil or inst:GetAttribute(target.MatchAttribute) == target.MatchValue
				if matches and inst:GetAttribute("EnemyAlive") == false then
					matches = false -- a dead/fading enemy is not a live objective target
				end
				if matches then
					local p = positionOf(inst)
					if p then
						local d = (position - p).Magnitude
						if d <= GUIDE_RADIUS and (bestDist == nil or d < bestDist) then
							best = inst
							bestDist = d
						end
					end
				end
			end
		end
		-- Coexist with the combat-target indicator: if the objective would highlight the very model the
		-- player is currently targeting, let the (warm) combat indicator own it -- no double outline.
		if best ~= nil and best == currentTargetModel then
			best = nil
		end
		local adornee = if best then adorneeFor(best) else nil
		guidanceHighlight.Adornee = adornee
		guidanceHighlight.Enabled = adornee ~= nil
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
			currentTarget = nil
			currentTargetModel = nil
			iface.SetCombat(nil)
			targetHighlight.Adornee = nil
			targetHighlight.Enabled = false
			updateGuidance(nil)
			return
		end
		local station = nearestTagged(STATION_TAG, position, INTERACT_RADIUS)
		local node = nearestTagged(NODE_TAG, position, INTERACT_RADIUS)
		local forge = nearestTagged(FORGE_TAG, position, INTERACT_RADIUS)
		currentStationId = if station then station:GetAttribute("StationId") else nil

		-- Soft-target + boss scan, and the authoritative-health readouts + combat-target indicator.
		local target, boss = scanCombat(position)
		currentTarget = if target then target.RuntimeId else nil
		currentTargetLabel = if target then enemyName(target.DefinitionId, target.Level) else nil
		currentTargetModel = if target then target.Model else nil
		iface.SetCombat({
			Target = if target then { Name = enemyName(target.DefinitionId, target.Level), Level = target.Level, Health = target.Health, MaxHealth = target.MaxHealth } else nil,
			Boss = if boss then { Name = "Goblin Chieftain", Level = boss.Level, Health = boss.Health, MaxHealth = boss.MaxHealth } else nil,
		})
		targetHighlight.Adornee = currentTargetModel
		targetHighlight.Enabled = currentTargetModel ~= nil

		iface.SetContext({
			NearStationId = currentStationId,
			NearNode = node ~= nil,
			NearForge = forge ~= nil,
			TrainingActive = trainingActive,
			MiningActive = miningActive,
		})

		updateGuidance(position)

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

	-- ===== Starter focus (onboarding step 1) =====
	-- Forwards the one-time starter-focus acknowledgement. The server records the flag; the client
	-- grants nothing. The Sword gear itself is already granted by the server StarterKit on first ready.
	iface.Handlers.AcknowledgeStarterFocus = function()
		local ok, _, reason = net.Request(RequestIds.OnboardingAcknowledgeStarterFocus, nil)
		iface.SetStatus(if ok then "Starter focus set: Sword. Time to train!" else ("Focus: " .. reasonText(reason)))
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
