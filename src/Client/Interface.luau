--!strict

-- Provisional, mobile-conscious HUD and interaction surface. It renders server-authoritative state
-- and forwards player intent through callbacks the Controller sets; it never computes Gold, XP,
-- levels, distance, tiers, crafting outcomes, or eligibility itself.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SkillIds = require(Shared:WaitForChild("SkillIds"))
local RecipeIds = require(Shared:WaitForChild("RecipeIds"))
local EquipmentSlots = require(Shared:WaitForChild("EquipmentSlots"))
local ItemDefinitions = require(Shared:WaitForChild("ItemDefinitions"))

-- Presentation-only labels (the client owns presentation; stable IDs stay authoritative).
local SKILL_LABELS: { [string]: string } = {
	[SkillIds.Melee] = "Melee",
	[SkillIds.Defense] = "Defense",
	[SkillIds.Mining] = "Mining",
	[SkillIds.Smithing] = "Smithing",
}
local SKILL_ORDER = { SkillIds.Melee, SkillIds.Defense, SkillIds.Mining, SkillIds.Smithing }
local ITEM_LABELS: { [string]: string } = {
	item_iron_ore = "Iron Ore",
	item_iron_bar = "Iron Bar",
	item_chieftain_fang = "Chieftain Fang",
	weapon_sword_starter = "Starter Sword",
	weapon_sword_upgraded = "Upgraded Sword",
	tool_pickaxe_basic = "Basic Pickaxe",
	tool_pickaxe_upgraded = "Upgraded Pickaxe",
}
local function itemLabel(id: string): string
	return ITEM_LABELS[id] or id
end

local COLORS = {
	Panel = Color3.fromRGB(28, 30, 38),
	PanelAlt = Color3.fromRGB(40, 44, 55),
	Accent = Color3.fromRGB(90, 140, 220),
	Good = Color3.fromRGB(90, 190, 110),
	Bad = Color3.fromRGB(210, 90, 90),
	Text = Color3.fromRGB(240, 240, 245),
	Dim = Color3.fromRGB(170, 175, 185),
	Button = Color3.fromRGB(55, 60, 74),
	ButtonOn = Color3.fromRGB(70, 120, 90),
}

local function make(class: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(class)
	for key, value in props do
		(inst :: any)[key] = value
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local Interface = {}

function Interface.New(player: Player)
	local playerGui = player:WaitForChild("PlayerGui")

	-- Callbacks the Controller assigns. Defaults are no-ops so the UI is safe before wiring.
	local handlers = {
		AttackDown = function() end,
		AttackUp = function() end,
		MineToggle = function() end,
		TrainToggle = function() end,
		Upgrade = function() end,
		ForgeCraft = function(_recipeId: string) end,
		Equip = function(_instanceId: string) end,
		Ascend = function() end,
	}

	local screen = make("ScreenGui", {
		Name = "AdventurersRiseHUD",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = false,
	}, playerGui)

	-- ===== HUD (top-left): Gold + slice skill levels =====
	local hud = make("Frame", {
		Size = UDim2.new(0, 210, 0, 132),
		Position = UDim2.new(0, 10, 0, 10),
		BackgroundColor3 = COLORS.Panel,
		BackgroundTransparency = 0.1,
	}, screen)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, hud)
	make("UIPadding", {
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
	}, hud)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, hud)

	local goldLabel = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(240, 210, 90), Text = "Gold: --", LayoutOrder = 0,
	}, hud)
	local skillLabels: { [string]: TextLabel } = {}
	local order = 1
	for _, skillId in SKILL_ORDER do
		skillLabels[skillId] = make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1,
			Font = Enum.Font.Gotham, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = COLORS.Text, Text = SKILL_LABELS[skillId] .. ": --", LayoutOrder = order,
		}, hud)
		order += 1
	end

	-- ===== Status line (top-center) =====
	local status = make("TextLabel", {
		Size = UDim2.new(0, 460, 0, 30), Position = UDim2.new(0.5, 0, 0, 12),
		AnchorPoint = Vector2.new(0.5, 0), BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.25,
		Font = Enum.Font.Gotham, TextSize = 15, TextColor3 = COLORS.Text, Text = "Welcome to Adventurer's Rise",
	}, screen)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, status)

	local function setStatus(text: string)
		status.Text = text
	end

	-- ===== Action bar (bottom): scrollable so it fits narrow screens =====
	local bar = make("ScrollingFrame", {
		Size = UDim2.new(1, -20, 0, 60), Position = UDim2.new(0.5, 0, 1, -10),
		AnchorPoint = Vector2.new(0.5, 1), BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.15,
		ScrollingDirection = Enum.ScrollingDirection.X, AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 4,
	}, screen)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, bar)
	make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, bar)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
		VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder,
	}, bar)

	local function button(text: string, order2: number): TextButton
		local b = make("TextButton", {
			Size = UDim2.new(0, 96, 0, 42), BackgroundColor3 = COLORS.Button, AutoButtonColor = true,
			Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = COLORS.Text, Text = text, LayoutOrder = order2,
		}, bar)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
		return b
	end

	local attackBtn = button("Attack (hold)", 1)
	local mineBtn = button("Mine", 2)
	local trainBtn = button("Train", 3)
	local forgeBtn = button("Forge", 4)
	local upgradeBtn = button("Upgrade", 5)
	local gearBtn = button("Gear", 6)
	local ascendBtn = button("Ascend", 7)

	-- ===== Panels =====
	local function panel(titleText: string): (Frame, Frame)
		local root = make("Frame", {
			Size = UDim2.new(0, 360, 0, 300), Position = UDim2.new(0.5, 0, 0.5, 0), AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = COLORS.Panel, Visible = false,
		}, screen)
		make("UICorner", { CornerRadius = UDim.new(0, 10) }, root)
		make("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, root)
		make("TextLabel", {
			Size = UDim2.new(1, -30, 0, 26), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 18,
			TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left, Text = titleText,
		}, root)
		local close = make("TextButton", {
			Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(1, -26, 0, 0), BackgroundColor3 = COLORS.Bad,
			Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = COLORS.Text, Text = "X",
		}, root)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, close)
		local content = make("Frame", {
			Size = UDim2.new(1, 0, 1, -34), Position = UDim2.new(0, 0, 0, 32), BackgroundTransparency = 1,
		}, root)
		close.Activated:Connect(function() root.Visible = false end)
		return root, content
	end

	local forgePanel, forgeContent = panel("Forge — Smithing")
	local gearPanel, gearContent = panel("Gear — Equipment")
	local ascendPanel, ascendContent = panel("Ascension — Adept")

	local function hideAllPanels()
		forgePanel.Visible = false
		gearPanel.Visible = false
		ascendPanel.Visible = false
	end

	-- Latest state cache so re-rendering a panel uses current data.
	local lastState: any = nil

	-- ---- Forge panel ----
	make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, forgeContent)
	local forgeInfo = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 14,
		TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true, Text = "", LayoutOrder = 0,
	}, forgeContent)
	local function craftRow(text: string, recipeId: string, order2: number)
		local b = make("TextButton", {
			Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = COLORS.Button, Font = Enum.Font.GothamMedium,
			TextSize = 14, TextColor3 = COLORS.Text, Text = text, LayoutOrder = order2,
		}, forgeContent)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
		b.Activated:Connect(function() handlers.ForgeCraft(recipeId) end)
	end
	craftRow("Smith Iron Bar (2 Iron Ore)", RecipeIds.IronBar, 1)
	craftRow("Smith Upgraded Sword (3 Iron Bars, Smith 5)", RecipeIds.SwordUpgraded, 2)

	-- ---- Gear panel ----
	local gearList = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, ScrollBarThickness = 4,
		CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, gearContent)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, gearList)

	local function renderGear()
		for _, child in gearList:GetChildren() do
			if child:IsA("Frame") then child:Destroy() end
		end
		if not lastState then return end
		local equippedWeapon = lastState.Equipment and lastState.Equipment[EquipmentSlots.Weapon]
		local equippedInstance = equippedWeapon and equippedWeapon.InstanceId
		local items = (lastState.Inventory and lastState.Inventory.Items) or {}
		local order2 = 0
		local any = false
		for instanceId, item in items do
			local def = ItemDefinitions.ById[item.DefinitionId]
			local isWeapon = def and def.Equipment and def.Equipment.SlotId == EquipmentSlots.Weapon
			if isWeapon then
				any = true
				local isEquipped = instanceId == equippedInstance
				local row = make("Frame", { Size = UDim2.new(1, -6, 0, 36), BackgroundColor3 = COLORS.PanelAlt, LayoutOrder = order2 }, gearList)
				make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
				make("TextLabel", {
					Size = UDim2.new(1, -96, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1,
					Font = Enum.Font.Gotham, TextSize = 14, TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left,
					Text = itemLabel(item.DefinitionId),
				}, row)
				local act = make("TextButton", {
					Size = UDim2.new(0, 84, 0, 28), Position = UDim2.new(1, -88, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
					BackgroundColor3 = if isEquipped then COLORS.ButtonOn else COLORS.Accent, Font = Enum.Font.GothamMedium,
					TextSize = 13, TextColor3 = COLORS.Text, Text = if isEquipped then "Equipped" else "Equip",
				}, row)
				make("UICorner", { CornerRadius = UDim.new(0, 6) }, act)
				if not isEquipped then
					act.Activated:Connect(function() handlers.Equip(instanceId) end)
				end
				order2 += 1
			end
		end
		if not any then
			make("TextLabel", {
				Size = UDim2.new(1, -6, 0, 30), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 14,
				TextColor3 = COLORS.Dim, Text = "No weapons in inventory yet.", LayoutOrder = 0,
			}, gearList)
		end
	end

	-- ---- Ascend panel ----
	local ascendList = make("Frame", { Size = UDim2.new(1, 0, 1, -46), BackgroundTransparency = 1 }, ascendContent)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, ascendList)
	local ascendActionBtn = make("TextButton", {
		Size = UDim2.new(1, 0, 0, 38), Position = UDim2.new(0, 0, 1, -38), BackgroundColor3 = COLORS.Button,
		Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = COLORS.Text, Text = "Ascend to Adept",
	}, ascendContent)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, ascendActionBtn)
	ascendActionBtn.Activated:Connect(function() handlers.Ascend() end)

	local function reqLine(text: string, met: boolean, order2: number)
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 14,
			TextColor3 = if met then COLORS.Good else COLORS.Bad, TextXAlignment = Enum.TextXAlignment.Left,
			Text = (if met then "[✓] " else "[  ] ") .. text, LayoutOrder = order2,
		}, ascendList)
	end

	local function renderAscend()
		for _, child in ascendList:GetChildren() do
			if child:IsA("TextLabel") then child:Destroy() end
		end
		if not lastState or not lastState.Ascension then return end
		local rankId = lastState.Ascension.RankId
		local p = lastState.Ascension.AdeptProgress
		local order2 = 0
		if p then
			for _, alt in p.Offense.Alternatives do
				reqLine(("Offense: %s %d/%d"):format(SKILL_LABELS[alt.SkillId] or alt.SkillId, alt.CurrentLevel, alt.RequiredLevel), alt.Met, order2)
				order2 += 1
			end
			reqLine(("Defense %d/%d"):format(p.Defense.CurrentLevel, p.Defense.RequiredLevel), p.Defense.Met, order2); order2 += 1
			for _, th in p.OverallSkilling.Thresholds do
				reqLine(("%s %d/%d"):format(SKILL_LABELS[th.SkillId] or th.SkillId, th.CurrentLevel, th.RequiredLevel), th.Met, order2)
				order2 += 1
			end
			reqLine("Goblin Chieftain defeated", p.BossMilestone.Met, order2); order2 += 1
		end
		local alreadyAdept = rankId ~= nil and rankId ~= "ascension_adventurer"
		local canAscend = (not alreadyAdept) and p ~= nil and p.Met == true
		ascendActionBtn.Text = if alreadyAdept then "Rank: Adept" else (if canAscend then "Ascend to Adept" else "Requirements not met")
		ascendActionBtn.BackgroundColor3 = if canAscend then COLORS.ButtonOn else COLORS.Button
		ascendActionBtn.Active = canAscend
		ascendActionBtn.AutoButtonColor = canAscend
	end

	-- ===== Public update / context APIs =====
	local iface: any = {}
	iface.Handlers = handlers
	iface.SetStatus = setStatus

	function iface.Update(state: any)
		lastState = state
		if type(state) ~= "table" then return end
		goldLabel.Text = "Gold: " .. tostring(state.Gold)
		if state.Skills then
			for _, skillId in SKILL_ORDER do
				local s = state.Skills[skillId]
				if s then
					skillLabels[skillId].Text = ("%s: Lv %d"):format(SKILL_LABELS[skillId], s.Level)
				end
			end
		end
		local oreCount = (state.Inventory and state.Inventory.Stacks and state.Inventory.Stacks.item_iron_ore) or 0
		local barCount = (state.Inventory and state.Inventory.Stacks and state.Inventory.Stacks.item_iron_bar) or 0
		local smithLevel = (state.Skills and state.Skills[SkillIds.Smithing] and state.Skills[SkillIds.Smithing].Level) or 0
		forgeInfo.Text = ("Iron Ore: %d    Iron Bars: %d    Smithing: Lv %d"):format(oreCount, barCount, smithLevel)
		if gearPanel.Visible then renderGear() end
		if ascendPanel.Visible then renderAscend() end
	end

	-- ctx: { NearStationId: string?, NearStationLabel: string?, NearNode: boolean, NearForge: boolean,
	--        UpgradeCost: number? }
	function iface.SetContext(ctx: any)
		local nearStation = ctx.NearStationId ~= nil
		local trainUsable = nearStation or ctx.TrainingActive == true
		trainBtn.Active = trainUsable
		trainBtn.AutoButtonColor = trainUsable
		trainBtn.Text = if ctx.TrainingActive then "Stop Train" else "Train"
		trainBtn.BackgroundColor3 = if ctx.TrainingActive then COLORS.ButtonOn elseif nearStation then COLORS.Button else Color3.fromRGB(45, 47, 55)
		upgradeBtn.Active = nearStation
		upgradeBtn.AutoButtonColor = nearStation
		upgradeBtn.Text = if nearStation and ctx.UpgradeCost then ("Upgrade (%d g)"):format(ctx.UpgradeCost) else "Upgrade"

		local mineUsable = ctx.NearNode == true or ctx.MiningActive == true
		mineBtn.Active = mineUsable
		mineBtn.AutoButtonColor = mineUsable
		mineBtn.Text = if ctx.MiningActive then "Stop Mine" else "Mine"
		mineBtn.BackgroundColor3 = if ctx.MiningActive then COLORS.ButtonOn elseif ctx.NearNode then COLORS.Button else Color3.fromRGB(45, 47, 55)

		forgeBtn.Active = ctx.NearForge == true
		forgeBtn.AutoButtonColor = ctx.NearForge == true
	end

	-- ===== Wire buttons to handlers =====
	-- Hold-to-attack works for both mouse and touch via the button's own input events.
	attackBtn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			attackBtn.BackgroundColor3 = COLORS.ButtonOn
			handlers.AttackDown()
		end
	end)
	attackBtn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			attackBtn.BackgroundColor3 = COLORS.Button
			handlers.AttackUp()
		end
	end)
	-- Keyboard convenience: hold F to attack.
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.F then
			attackBtn.BackgroundColor3 = COLORS.ButtonOn
			handlers.AttackDown()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.F then
			attackBtn.BackgroundColor3 = COLORS.Button
			handlers.AttackUp()
		end
	end)

	mineBtn.Activated:Connect(function() handlers.MineToggle() end)
	trainBtn.Activated:Connect(function() handlers.TrainToggle() end)
	upgradeBtn.Activated:Connect(function() handlers.Upgrade() end)
	forgeBtn.Activated:Connect(function() hideAllPanels(); forgePanel.Visible = true end)
	gearBtn.Activated:Connect(function() hideAllPanels(); renderGear(); gearPanel.Visible = true end)
	ascendBtn.Activated:Connect(function() hideAllPanels(); renderAscend(); ascendPanel.Visible = true end)

	return iface
end

return Interface
