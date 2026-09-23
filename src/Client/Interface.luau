--!strict

-- Provisional, mobile-conscious HUD and interaction surface. It renders server-authoritative state
-- and forwards player intent through callbacks the Controller sets; it never computes Gold, XP,
-- levels, distance, tiers, crafting outcomes, or eligibility itself.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SkillIds = require(Shared:WaitForChild("SkillIds"))
local EquipmentSlots = require(Shared:WaitForChild("EquipmentSlots"))
local ItemDefinitions = require(Shared:WaitForChild("ItemDefinitions"))
local RegionDefinitions = require(Shared:WaitForChild("RegionDefinitions"))
local SoundController = require(script.Parent:WaitForChild("SoundController"))

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
	item_chieftain_fang = "Goblin Chieftain Fang",
	item_warlord_seal = "Bandit Warlord Seal",
	weapon_sword_starter = "Starter Sword",
	weapon_sword_upgraded = "Upgraded Sword",
	tool_pickaxe_basic = "Basic Pickaxe",
	tool_pickaxe_upgraded = "Upgraded Pickaxe",
	armor_iron_helm = "Iron Helm",
	armor_iron_body = "Iron Chestplate",
	armor_iron_legs = "Iron Greaves",
	item_coal = "Coal",
	item_steel_bar = "Steel Bar",
	item_raw_gem = "Raw Gem",
	weapon_sword_steel = "Steel Sword",
	armor_steel_helm = "Steel Helm",
	armor_steel_body = "Steel Chestplate",
	armor_steel_legs = "Steel Greaves",
}
local function itemLabel(id: string): string
	return ITEM_LABELS[id] or id
end
-- Presentation-only rarity: special boss loot is badged/coloured so it never reads like a routine
-- resource. The item IDs and their authority stay server-owned; this only changes how they look.
local RARE_ITEMS: { [string]: boolean } = {
	item_chieftain_fang = true,
	item_warlord_seal = true,
}

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
	-- A disabled/unavailable control tint (kept as one token instead of repeated literals).
	Disabled = Color3.fromRGB(45, 47, 55),
	-- Rare/special-loot accent (warm gold), distinct from the routine blue/green feedback colours.
	Rare = Color3.fromRGB(224, 178, 92),
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

-- Mobile-safe width: a surface fills the available width (its Size should use a Scale width minus a
-- side margin) but is capped at a comfortable desktop maximum, so wide HUD elements never overflow a
-- narrow phone yet never stretch awkwardly on desktop. optionalMinHeight caps the height similarly.
local function capSize(inst: Instance, maxWidth: number, maxHeight: number?, minWidth: number?, minHeight: number?)
	make("UISizeConstraint", {
		MaxSize = Vector2.new(maxWidth, if maxHeight then maxHeight else math.huge),
		MinSize = Vector2.new(if minWidth then minWidth else 0, if minHeight then minHeight else 0),
	}, inst)
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
		ForgeCraft = function(_recipeId: string, _request: { Quantity: number?, Max: boolean? }?) end,
		Equip = function(_slotId: string, _instanceId: string) end,
		Ascend = function(_rankId: string) end,
		AcknowledgeStarterFocus = function() end,
		SetOfflineFocus = function(_skillId: string) end,
		SelectMastery = function(_skillId: string, _nodeId: string) end,
		RespecMastery = function(_skillId: string) end,
		ShopBuy = function(_catalogId: string, _definitionId: string, _amount: number) end,
		ShopSell = function(_catalogId: string, _definitionId: string, _amount: number) end,
		ShopBuyDiscrete = function(_catalogId: string, _definitionId: string) end,
		ShopSellDiscrete = function(_catalogId: string, _instanceId: string) end,
	}

	local screen = make("ScreenGui", {
		Name = "AdventurersRiseHUD",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = false,
	}, playerGui)

	-- ===== HUD (top-left): Gold + slice skill levels =====
	local hud = make("Frame", {
		Size = UDim2.new(0, 210, 0, 158),
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
	local healthLabel = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(230, 90, 90), Text = "Health: --", LayoutOrder = 1,
	}, hud)
	local skillLabels: { [string]: TextLabel } = {}
	local order = 2
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
		Size = UDim2.new(1, -20, 0, 30), Position = UDim2.new(0.5, 0, 0, 12),
		AnchorPoint = Vector2.new(0.5, 0), BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.25,
		Font = Enum.Font.Gotham, TextSize = 15, TextColor3 = COLORS.Text, Text = "Welcome to Adventurer's Rise",
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, screen)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, status)
	capSize(status, 460)

	local function setStatus(text: string)
		status.Text = text
	end

	-- ===== Current objective (top-center, below status): the compact guided-onboarding surface =====
	-- Simulator-style single line, not a quest log. Tappable so the starter-focus step can reopen its
	-- framing panel. All completion is server-authoritative; this only presents the derived step.
	local objective = make("TextButton", {
		Size = UDim2.new(1, -20, 0, 46), Position = UDim2.new(0.5, 0, 0, 48), AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.15, AutoButtonColor = false, Text = "", Visible = false,
	}, screen)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, objective)
	capSize(objective, 460)
	make("UIStroke", { Color = COLORS.Accent, Thickness = 1.5, Transparency = 0.35 }, objective)
	make("UIPadding", { PaddingTop = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, objective)
	local objectiveTitle = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 15,
		TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left, Text = "",
	}, objective)
	local objectiveHint = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 15), Position = UDim2.new(0, 0, 0, 21), BackgroundTransparency = 1, Font = Enum.Font.Gotham,
		TextSize = 12, TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left, Text = "", TextTruncate = Enum.TextTruncate.AtEnd,
	}, objective)

	-- ===== Toast (temporary, center): provisional presentation for pushed reward outcomes =====
	local toast = make("TextLabel", {
		Size = UDim2.new(1, -40, 0, 96), Position = UDim2.new(0.5, 0, 0.5, 0), AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.08, Visible = false,
		Font = Enum.Font.GothamMedium, TextSize = 16, TextColor3 = COLORS.Text, TextWrapped = true,
		Text = "",
	}, screen)
	make("UICorner", { CornerRadius = UDim.new(0, 10) }, toast)
	capSize(toast, 360)
	make("UIStroke", { Color = COLORS.Accent, Thickness = 2, Transparency = 0.2 }, toast)
	make("UIPadding", {
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
	}, toast)
	-- One shared toast queue so every brief notification (onboarding step, boss reward, level-up,
	-- Mastery Point, aggregated gains) uses the same presentation and they never stomp each other.
	local toastQueue: { { Text: string, Accent: Color3 } } = {}
	local toastBusy = false
	local pumpToast: () -> ()
	function pumpToast()
		if toastBusy then
			return
		end
		local entry = table.remove(toastQueue, 1)
		if not entry then
			toast.Visible = false
			return
		end
		toastBusy = true
		toast.Text = entry.Text
		toast.TextColor3 = COLORS.Text
		local stroke = toast:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = entry.Accent
		end
		toast.Visible = true
		task.delay(3.4, function()
			toastBusy = false
			pumpToast()
		end)
	end
	local function showToast(text: string, accent: Color3)
		table.insert(toastQueue, { Text = text, Accent = accent })
		-- Cap the backlog so a burst never keeps the queue busy for too long.
		while #toastQueue > 6 do
			table.remove(toastQueue, 1)
		end
		pumpToast()
	end

	-- Presentation-only boss labels; stable IDs stay authoritative.
	local BOSS_LABELS: { [string]: string } = { enemy_goblin_chieftain = "Goblin Chieftain", enemy_bandit_warlord = "Bandit Warlord" }
	local function bossLabel(id: any): string
		return (type(id) == "string" and BOSS_LABELS[id]) or "the boss"
	end

	-- Shared helper: drives a health bar's fill fraction and "cur / max" readout from authoritative
	-- values. The client only DISPLAYS these; it never computes or owns enemy health.
	local function setHealthBar(fill: Frame, text: TextLabel, health: any, maxHealth: any)
		local h = if type(health) == "number" then math.max(health, 0) else 0
		local m = if type(maxHealth) == "number" and maxHealth > 0 then maxHealth else 0
		local frac = if m > 0 then math.clamp(h / m, 0, 1) else 0
		fill.Size = UDim2.new(frac, 0, 1, 0)
		text.Text = ("%d / %d"):format(math.floor(h + 0.5), math.floor(m + 0.5))
	end

	-- ===== Boss health bar (top-center): prominent shared-encounter presentation =====
	local bossBar = make("Frame", {
		Size = UDim2.new(1, -20, 0, 46), Position = UDim2.new(0.5, 0, 0, 104), AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.1, Visible = false,
	}, screen)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, bossBar)
	capSize(bossBar, 440)
	make("UIStroke", { Color = COLORS.Bad, Thickness = 2, Transparency = 0.15 }, bossBar)
	make("UIPadding", { PaddingTop = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, bossBar)
	local bossName = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 14,
		TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Center, Text = "",
	}, bossBar)
	local bossTrack = make("Frame", { Size = UDim2.new(1, 0, 0, 14), Position = UDim2.new(0, 0, 0, 21), BackgroundColor3 = Color3.fromRGB(50, 52, 60) }, bossBar)
	make("UICorner", { CornerRadius = UDim.new(0, 4) }, bossTrack)
	local bossFill = make("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = COLORS.Bad, BorderSizePixel = 0 }, bossTrack)
	make("UICorner", { CornerRadius = UDim.new(0, 4) }, bossFill)
	local bossHealthText = make("TextLabel", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 11, TextColor3 = COLORS.Text, Text = "" }, bossTrack)

	-- ===== Current-target readout (compact, above the action bar) =====
	local targetPanel = make("Frame", {
		Size = UDim2.new(0, 230, 0, 42), Position = UDim2.new(0.5, 0, 1, -78), AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.2, Visible = false,
	}, screen)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, targetPanel)
	make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, targetPanel)
	local targetName = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 15), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 13,
		TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left, Text = "",
	}, targetPanel)
	local targetTrack = make("Frame", { Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 0, 19), BackgroundColor3 = Color3.fromRGB(50, 52, 60) }, targetPanel)
	make("UICorner", { CornerRadius = UDim.new(0, 4) }, targetTrack)
	local targetFill = make("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = COLORS.Bad, BorderSizePixel = 0 }, targetTrack)
	make("UICorner", { CornerRadius = UDim.new(0, 4) }, targetFill)
	local targetHealthText = make("TextLabel", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 10, TextColor3 = COLORS.Text, Text = "" }, targetTrack)

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

	-- Primary moment-to-moment action, always present.
	local attackBtn = button("Attack (hold)", 1)
	-- World-contextual actions: shown only when the player is actually at the relevant world object
	-- (SetContext toggles their visibility), so the bar isn't crowded with impossible actions. Attack
	-- stays; these appear/disappear as you approach a node, station, forge, or shop.
	local mineBtn = button("Mine", 2)
	local trainBtn = button("Train", 3)
	local upgradeBtn = button("Upgrade", 4)
	local forgeBtn = button("Forge", 5)
	local shopBtn = button("Shop", 6)
	for _, b in { mineBtn, trainBtn, upgradeBtn, forgeBtn, shopBtn } do
		b.Visible = false
	end
	-- One grouped entry for the progression/menu destinations (Gear, Skills, Ascend, Offline) so they
	-- don't each occupy a permanent bar slot. It badges any spendable Mastery Points.
	local menuBtn = button("Menu", 20)

	-- ===== Panels =====
	local function panel(titleText: string, height: number?): (Frame, Frame)
		local h = height or 300
		-- Mobile-adaptive: fill most of the viewport (minus margins) but cap at a comfortable desktop
		-- size, so a panel is never wider than the phone nor taller than a short (landscape) screen. The
		-- scrolling content inside each panel absorbs any height reduction.
		local root = make("Frame", {
			Size = UDim2.new(1, -24, 1, -120), Position = UDim2.new(0.5, 0, 0.5, 0), AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = COLORS.Panel, Visible = false,
		}, screen)
		capSize(root, 360, h, 268, math.min(h, 220))
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

	local forgePanel, forgeContent = panel("Forge — Smithing", 360)
	local gearPanel, gearContent = panel("Gear — Inventory")
	local ascendPanel, ascendContent = panel("Ascension")
	local offlinePanel, offlineContent = panel("Offline Training")
	local mapPanel, mapContent = panel("Map — The Marchlands", 340)
	local shopPanel, shopContent = panel("Shop", 340)
	local masteryPanel, masteryContent = panel("Skills — Mastery", 430)
	local skillsPanel, skillsContent = panel("Skills — Progress", 320)
	local starterPanel, starterContent = panel("Choose Your Focus", 300)

	-- Forward-declared so the progression Menu popup (created later) shares the same close lifecycle as
	-- the modal panels: opening any panel closes it, and opening it closes any panel.
	local menu: Frame? = nil

	local function hideAllPanels()
		forgePanel.Visible = false
		gearPanel.Visible = false
		ascendPanel.Visible = false
		offlinePanel.Visible = false
		mapPanel.Visible = false
		shopPanel.Visible = false
		masteryPanel.Visible = false
		skillsPanel.Visible = false
		starterPanel.Visible = false
		if menu then
			menu.Visible = false
		end
	end

	-- ---- Starter-focus framing panel ----
	-- The slice's version of the designed starter-weapon moment. Sword is the only functional combat
	-- style in the slice, so Bow/Staff are shown but clearly unavailable rather than pretending their
	-- systems exist. Confirming Sword sends the intent to the server (which records the acknowledgement
	-- flag); it grants no equipment -- the existing StarterKit already equips the slice gear.
	make("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, starterContent)
	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 54), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 14, TextColor3 = COLORS.Text,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, LayoutOrder = 0,
		Text = "Pick your starting combat focus. This is an initial focus, not a permanent class — you can train every skill freely.",
	}, starterContent)
	local STARTER_CHOICES = {
		{ Label = "Sword", Available = true },
		{ Label = "Bow", Available = false },
		{ Label = "Staff", Available = false },
	}
	for index, choice in STARTER_CHOICES do
		local row = make("Frame", { Size = UDim2.new(1, 0, 0, 42), BackgroundColor3 = COLORS.PanelAlt, LayoutOrder = index }, starterContent)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
		make("TextLabel", {
			Size = UDim2.new(1, -120, 1, 0), Position = UDim2.new(0, 10, 0, 0), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
			TextSize = 15, TextColor3 = if choice.Available then COLORS.Text else COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left,
			Text = if choice.Available then choice.Label else (choice.Label .. "  (coming later)"),
		}, row)
		local act = make("TextButton", {
			Size = UDim2.new(0, 100, 0, 30), Position = UDim2.new(1, -108, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
			BackgroundColor3 = if choice.Available then COLORS.ButtonOn else Color3.fromRGB(45, 47, 55), Font = Enum.Font.GothamMedium,
			TextSize = 13, TextColor3 = if choice.Available then COLORS.Text else COLORS.Dim,
			Text = if choice.Available then "Confirm" else "Unavailable", Active = choice.Available, AutoButtonColor = choice.Available,
		}, row)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, act)
		if choice.Available then
			act.Activated:Connect(function()
				handlers.AcknowledgeStarterFocus()
				starterPanel.Visible = false
			end)
		end
	end

	-- Latest state cache so re-rendering a panel uses current data.
	local lastState: any = nil
	-- Combat has visual priority over the guided objective: while a boss bar is showing, the objective
	-- line yields (hides) so the two top-center surfaces never compete. SetCombat drives this flag.
	local bossActive = false

	-- ---- Forge panel ----
	-- Data-driven from the read-model Recipes (authoritative requirements) and current resources; the
	-- Craft 1/5/Max buttons only send intent. The server determines affordability, consumption, output,
	-- XP, and the Max quantity -- the client never computes how many crafts are affordable.
	local forgeInfo = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 20), Position = UDim2.new(0, 0, 0, 0), BackgroundTransparency = 1,
		Font = Enum.Font.Gotham, TextSize = 14, TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}, forgeContent)
	local forgeList = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, -26), Position = UDim2.new(0, 0, 0, 26), BackgroundTransparency = 1,
		ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, forgeContent)
	make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, forgeList)

	local function forgeCraftButton(text: string, offsetFromRight: number, row: Frame, onClick: () -> ())
		local b = make("TextButton", {
			Size = UDim2.new(0, 64, 0, 26), Position = UDim2.new(1, offsetFromRight, 1, -4), AnchorPoint = Vector2.new(0, 1),
			BackgroundColor3 = COLORS.Button, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = COLORS.Text, Text = text,
		}, row)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
		b.Activated:Connect(onClick)
	end

	local function renderForge()
		for _, child in forgeList:GetChildren() do
			if child:IsA("Frame") or child:IsA("TextLabel") then child:Destroy() end
		end
		if not lastState then return end
		local stacks = (lastState.Inventory and lastState.Inventory.Stacks) or {}
		local smithLevel = (lastState.Skills and lastState.Skills[SkillIds.Smithing] and lastState.Skills[SkillIds.Smithing].Level) or 0
		forgeInfo.Text = ("Iron Ore: %d    Iron Bars: %d    Smithing: Lv %d"):format(stacks.item_iron_ore or 0, stacks.item_iron_bar or 0, smithLevel)
		local recipes = lastState.Recipes
		if type(recipes) ~= "table" then return end
		local order2 = 0
		for _, recipe in recipes do
			local recipeId = recipe.RecipeId
			local row = make("Frame", { Size = UDim2.new(1, -6, 0, 74), BackgroundColor3 = COLORS.PanelAlt, LayoutOrder = order2 }, forgeList)
			make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
			-- Tell the player what the craft is FOR: armour outputs show their mitigation, weapons their
			-- damage, so the ladder (iron -> steel) reads as a real upgrade on the recipe list itself.
			local outDef = ItemDefinitions.ById[recipe.OutputItemId]
			local outStat = ""
			if outDef then
				if outDef.Armor then
					outStat = ("   ·  %d%% armour"):format(math.floor(outDef.Armor.DamageReduction * 100 + 0.5))
				elseif outDef.Melee then
					outStat = ("   ·  %d dmg"):format(outDef.Melee.Damage)
				end
			end
			make("TextLabel", {
				Size = UDim2.new(1, -12, 0, 18), Position = UDim2.new(0, 8, 0, 5), BackgroundTransparency = 1,
				Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left,
				Text = ("%s   (Smith Lv %d)%s"):format(itemLabel(recipe.OutputItemId), recipe.RequiredSmithingLevel, outStat),
			}, row)
			-- Authoritative input requirements, straight from the read model.
			local inputParts = {}
			for _, input in recipe.Inputs do
				table.insert(inputParts, ("%dx %s"):format(input.Amount, itemLabel(input.ItemDefinitionId)))
			end
			make("TextLabel", {
				Size = UDim2.new(1, -12, 0, 16), Position = UDim2.new(0, 8, 0, 24), BackgroundTransparency = 1,
				Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left,
				Text = "Needs: " .. table.concat(inputParts, ", "),
			}, row)
			forgeCraftButton("Max", -68, row, function() handlers.ForgeCraft(recipeId, { Max = true }) end)
			forgeCraftButton("Craft 5", -136, row, function() handlers.ForgeCraft(recipeId, { Quantity = 5 }) end)
			forgeCraftButton("Craft 1", -204, row, function() handlers.ForgeCraft(recipeId, { Quantity = 1 }) end)
			order2 += 1
		end
	end

	-- ---- Gear panel ----
	local gearList = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, ScrollBarThickness = 4,
		CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, gearContent)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, gearList)

	local SLOT_LABELS: { [string]: string } = {
		[EquipmentSlots.Weapon] = "Weapon",
		[EquipmentSlots.Tool] = "Tool",
		[EquipmentSlots.Head] = "Head",
		[EquipmentSlots.Body] = "Body",
		[EquipmentSlots.Legs] = "Legs",
	}
	local function gearHeader(text: string, order2: number)
		make("TextLabel", {
			Size = UDim2.new(1, -6, 0, 18), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12,
			TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left, Text = text, LayoutOrder = order2,
		}, gearList)
	end
	local function gearNote(text: string, order2: number)
		make("TextLabel", {
			Size = UDim2.new(1, -6, 0, 26), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 13,
			TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left, Text = text, LayoutOrder = order2,
		}, gearList)
	end

	-- Shows the current inventory as two readable sections: equippable Equipment (weapons + tools, with
	-- Equip/Equipped state per slot) and stackable Resources with counts. All state is authoritative;
	-- equipping only sends intent.
	local function renderGear()
		for _, child in gearList:GetChildren() do
			if child:IsA("Frame") or child:IsA("TextLabel") then child:Destroy() end
		end
		if not lastState then return end
		local equipment = lastState.Equipment or {}
		local items = (lastState.Inventory and lastState.Inventory.Items) or {}
		local stacks = (lastState.Inventory and lastState.Inventory.Stacks) or {}
		local order2 = 0

		gearHeader("EQUIPMENT", order2); order2 += 1
		-- Make the Defense/armour reward legible: the authoritative mitigation the server applies (Mastery
		-- + equipped armour), plus the armour-only share, as plain percentages. Without this the player
		-- crafts a full set and sees no number anywhere.
		local defense = lastState.Defense
		if type(defense) == "table" then
			local totalPct = math.floor((tonumber(defense.DamageReduction) or 0) * 100 + 0.5)
			local armorPct = math.floor((tonumber(defense.ArmorDamageReduction) or 0) * 100 + 0.5)
			local defenseText = if armorPct > 0
				then ("Damage reduction: %d%%   (armour %d%%)"):format(totalPct, armorPct)
				else ("Damage reduction: %d%%"):format(totalPct)
			make("TextLabel", {
				Size = UDim2.new(1, -6, 0, 22), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 13,
				TextColor3 = if totalPct > 0 then COLORS.Accent else COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left,
				Text = defenseText, LayoutOrder = order2,
			}, gearList)
			order2 += 1
		end
		local equippable: { { InstanceId: string, DefinitionId: string, SlotId: string } } = {}
		for instanceId, item in items do
			local def = ItemDefinitions.ById[item.DefinitionId]
			if def and def.Equipment then
				table.insert(equippable, { InstanceId = instanceId, DefinitionId = item.DefinitionId, SlotId = def.Equipment.SlotId })
			end
		end
		table.sort(equippable, function(a, b): boolean
			return a.DefinitionId < b.DefinitionId
		end)
		if #equippable == 0 then
			gearNote("No gear yet.", order2); order2 += 1
		end
		for _, entry in equippable do
			local slotEquipped = equipment[entry.SlotId]
			local isEquipped = type(slotEquipped) == "table" and slotEquipped.InstanceId == entry.InstanceId
			local row = make("Frame", { Size = UDim2.new(1, -6, 0, 36), BackgroundColor3 = COLORS.PanelAlt, LayoutOrder = order2 }, gearList)
			make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
			-- Show the piece's own contribution so the ladder is self-explanatory: armour pieces read their
			-- DamageReduction, weapons their attack damage. Presentation only; ItemDefinitions is already local.
			local entryDef = ItemDefinitions.ById[entry.DefinitionId]
			local statSuffix = ""
			if entryDef then
				if entryDef.Armor then
					statSuffix = ("  ·  %d%% armour"):format(math.floor(entryDef.Armor.DamageReduction * 100 + 0.5))
				elseif entryDef.Melee then
					statSuffix = ("  ·  %d dmg"):format(entryDef.Melee.Damage)
				end
			end
			make("TextLabel", {
				Size = UDim2.new(1, -96, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1,
				Font = Enum.Font.Gotham, TextSize = 14, TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left,
				Text = ("%s  (%s)%s"):format(itemLabel(entry.DefinitionId), SLOT_LABELS[entry.SlotId] or entry.SlotId, statSuffix),
			}, row)
			local act = make("TextButton", {
				Size = UDim2.new(0, 84, 0, 28), Position = UDim2.new(1, -88, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
				BackgroundColor3 = if isEquipped then COLORS.ButtonOn else COLORS.Accent, Font = Enum.Font.GothamMedium,
				TextSize = 13, TextColor3 = COLORS.Text, Text = if isEquipped then "Equipped" else "Equip",
			}, row)
			make("UICorner", { CornerRadius = UDim.new(0, 6) }, act)
			if not isEquipped then
				act.Activated:Connect(function() handlers.Equip(entry.SlotId, entry.InstanceId) end)
			end
			order2 += 1
		end

		gearHeader("RESOURCES", order2); order2 += 1
		local resources: { { DefinitionId: string, Count: number } } = {}
		for defId, count in stacks do
			if type(count) == "number" and count > 0 then
				table.insert(resources, { DefinitionId = defId, Count = count })
			end
		end
		-- Rare items sort to the top of Resources and are badged, so special boss loot never reads like a
		-- routine stack. Presentation only; ownership/counts stay authoritative.
		table.sort(resources, function(a, b): boolean
			local ar, br = RARE_ITEMS[a.DefinitionId] == true, RARE_ITEMS[b.DefinitionId] == true
			if ar ~= br then
				return ar
			end
			return a.DefinitionId < b.DefinitionId
		end)
		if #resources == 0 then
			gearNote("No resources yet.", order2); order2 += 1
		end
		for _, resource in resources do
			local isRare = RARE_ITEMS[resource.DefinitionId] == true
			local row = make("Frame", {
				Size = UDim2.new(1, -6, 0, 30), LayoutOrder = order2,
				BackgroundColor3 = if isRare then Color3.fromRGB(52, 45, 28) else COLORS.PanelAlt,
			}, gearList)
			make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
			if isRare then
				make("UIStroke", { Color = COLORS.Rare, Thickness = 1.5, Transparency = 0.15 }, row)
			end
			make("TextLabel", {
				Size = UDim2.new(1, if isRare then -64 else -16, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1,
				Font = if isRare then Enum.Font.GothamMedium else Enum.Font.Gotham, TextSize = 14,
				TextColor3 = if isRare then COLORS.Rare else COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
				Text = ("%s   x%d"):format(itemLabel(resource.DefinitionId), resource.Count),
			}, row)
			if isRare then
				local badge = make("TextLabel", {
					Size = UDim2.new(0, 46, 0, 20), Position = UDim2.new(1, -52, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
					BackgroundColor3 = COLORS.Rare, Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = Color3.fromRGB(30, 24, 10), Text = "RARE",
				}, row)
				make("UICorner", { CornerRadius = UDim.new(0, 4) }, badge)
			end
			order2 += 1
		end
	end

	-- ---- Ascend panel ----
	local ascendList = make("Frame", { Size = UDim2.new(1, 0, 1, -46), BackgroundTransparency = 1 }, ascendContent)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, ascendList)
	-- Readable names for the boss-milestone requirement, keyed by the ProgressionFlag id the server
		-- reports; generalised so each rank can require a different boss without a code change.
		local MILESTONE_LABELS: { [string]: string } = {
			flag_boss_goblin_chieftain_defeated = "Goblin Chieftain defeated",
			flag_boss_bandit_warlord_defeated = "Bandit Warlord defeated",
		}
		-- The rank the Ascend button currently targets (the player's next rank), refreshed by renderAscend
		-- so a click always ascends toward the right rank without the client hardcoding one.
		local ascendTargetRankId: string? = nil
		local ascendActionBtn = make("TextButton", {
		Size = UDim2.new(1, 0, 0, 38), Position = UDim2.new(0, 0, 1, -38), BackgroundColor3 = COLORS.Button,
		Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = COLORS.Text, Text = "Ascend",
	}, ascendContent)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, ascendActionBtn)
	ascendActionBtn.Activated:Connect(function()
		if ascendTargetRankId then handlers.Ascend(ascendTargetRankId) end
	end)

	local function reqLine(text: string, met: boolean, order2: number)
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 14,
			TextColor3 = if met then COLORS.Good else COLORS.Bad, TextXAlignment = Enum.TextXAlignment.Left,
			Text = (if met then "[✓] " else "[  ] ") .. text, LayoutOrder = order2,
		}, ascendList)
	end

	-- Formats an Ascension perk (a rank's permanent reward) into a short readable string, or nil if it
	-- grants nothing measurable.
	local function perkText(perkValue: any): string?
		if type(perkValue) ~= "table" then
			return nil
		end
		local parts = {}
		local hp = tonumber(perkValue.MaxHealthBonus) or 0
		local dr = tonumber(perkValue.IncomingDamageReduction) or 0
		if hp > 0 then
			table.insert(parts, ("+%d%% Max HP"):format(math.floor(hp * 100 + 0.5)))
		end
		if dr > 0 then
			table.insert(parts, ("+%d%% damage reduction"):format(math.floor(dr * 100 + 0.5)))
		end
		if #parts == 0 then
			return nil
		end
		return table.concat(parts, ", ")
	end
	local function ascendInfo(text: string, color: Color3, order2: number)
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 13,
			TextColor3 = color, TextXAlignment = Enum.TextXAlignment.Left, Text = text, LayoutOrder = order2,
		}, ascendList)
	end

	local function renderAscend()
		for _, child in ascendList:GetChildren() do
			if child:IsA("TextLabel") then child:Destroy() end
		end
		if not lastState or not lastState.Ascension then return end
		local asc = lastState.Ascension
		local nextRank = asc.NextRank
			local p = if type(nextRank) == "table" then nextRank.Progress else nil
		local order2 = 0
		if p then
			ascendInfo(("%s  ▶  %s"):format(tostring(asc.RankDisplayName or "—"), tostring(nextRank.DisplayName)), COLORS.Text, order2); order2 += 1
			local grantText = perkText(nextRank.Perk)
			if grantText then
				ascendInfo("Ascending grants: " .. grantText, COLORS.Good, order2); order2 += 1
			end
			for _, alt in p.Offense.Alternatives do
				reqLine(("Offense: %s %d/%d"):format(SKILL_LABELS[alt.SkillId] or alt.SkillId, alt.CurrentLevel, alt.RequiredLevel), alt.Met, order2)
				order2 += 1
			end
			reqLine(("Defense %d/%d"):format(p.Defense.CurrentLevel, p.Defense.RequiredLevel), p.Defense.Met, order2); order2 += 1
			for _, th in p.OverallSkilling.Thresholds do
				reqLine(("%s %d/%d"):format(SKILL_LABELS[th.SkillId] or th.SkillId, th.CurrentLevel, th.RequiredLevel), th.Met, order2)
				order2 += 1
			end
			reqLine(MILESTONE_LABELS[p.BossMilestone.MilestoneId] or "Boss milestone", p.BossMilestone.Met, order2); order2 += 1
		end
		if not p then
			-- Top of the ladder: no next rank -- show the rank held and the perk it grants.
			ascendInfo(("Highest rank: %s"):format(tostring(asc.RankDisplayName or "—")), COLORS.Text, order2); order2 += 1
			local held = perkText(asc.RankPerk)
			if held then
				ascendInfo("Rank perk: " .. held, COLORS.Good, order2); order2 += 1
			end
		end
		ascendTargetRankId = if type(nextRank) == "table" then nextRank.RankId else nil
		local canAscend = p ~= nil and p.Met == true
		ascendActionBtn.Text = if type(nextRank) ~= "table" then ("Rank: " .. (asc.RankDisplayName or "—") .. " (max)") elseif canAscend then ("Ascend to " .. nextRank.DisplayName) else "Requirements not met"
		ascendActionBtn.BackgroundColor3 = if canAscend then COLORS.ButtonOn else COLORS.Button
		ascendActionBtn.Active = canAscend
		ascendActionBtn.AutoButtonColor = canAscend
	end

	-- ---- Offline panel ----
	-- Player-chosen offline training focus (server owns rates/cap/claim) plus a compact "While You
	-- Were Away" summary rendered straight from the authoritative offline-return; no rewards are
	-- computed here. Only the currently supported focus skills (Melee, Defense) are offered.
	make("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, offlineContent)
	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left, Text = "OFFLINE FOCUS", LayoutOrder = 0,
	}, offlineContent)
	local offlineFocusLabel = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 15,
		TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left, Text = "Currently training: --", LayoutOrder = 1,
	}, offlineContent)
	local focusRow = make("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = 2 }, offlineContent)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
		VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder,
	}, focusRow)
	-- Only the server-supported offline focus skills; the labels are presentation, the SkillIds authoritative.
	local FOCUS_CHOICES = { { SkillId = SkillIds.Melee, Label = "Melee" }, { SkillId = SkillIds.Defense, Label = "Defense" } }
	local focusButtons: { [string]: TextButton } = {}
	for index, choice in FOCUS_CHOICES do
		local b = make("TextButton", {
			Size = UDim2.new(0.5, -4, 1, 0), BackgroundColor3 = COLORS.Button, AutoButtonColor = true,
			Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = COLORS.Text, Text = choice.Label, LayoutOrder = index,
		}, focusRow)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
		b.Activated:Connect(function() handlers.SetOfflineFocus(choice.SkillId) end)
		focusButtons[choice.SkillId] = b
	end
	make("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = COLORS.PanelAlt, BorderSizePixel = 0, LayoutOrder = 3 }, offlineContent)
	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left, Text = "WHILE YOU WERE AWAY", LayoutOrder = 4,
	}, offlineContent)
	local offlineSummary = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 72), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 14,
		TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true, Text = "", LayoutOrder = 5,
	}, offlineContent)

	local function renderOffline()
		if not lastState then return end
		local focus = lastState.OfflineFocusSkillId
		offlineFocusLabel.Text = "Currently training: " .. (if focus and SKILL_LABELS[focus] then SKILL_LABELS[focus] else "None selected")
		for skillId, b in focusButtons do
			local selected = skillId == focus
			b.BackgroundColor3 = if selected then COLORS.ButtonOn else COLORS.Button
			b.Text = if selected then (SKILL_LABELS[skillId] or skillId) .. "  ✓" else (SKILL_LABELS[skillId] or skillId)
		end
		-- Straight from the authoritative offline-return summary; the client never recomputes rewards.
		local ret = lastState.OfflineReturn
		if type(ret) == "table" and ret.Rewarded == true and type(ret.XPAwarded) == "number" and ret.XPAwarded > 0 then
			local skillLabel = (ret.FocusSkillId and SKILL_LABELS[ret.FocusSkillId]) or "Your focus skill"
			local hours = (if type(ret.CreditedElapsedSeconds) == "number" then ret.CreditedElapsedSeconds else 0) / 3600
			offlineSummary.Text = ("%s gained +%d XP while you were away (%.1f h credited)."):format(skillLabel, math.floor(ret.XPAwarded + 0.5), hours)
			offlineSummary.TextColor3 = COLORS.Good
		elseif focus then
			offlineSummary.Text = ("No offline gains yet. Leave and return, and your %s trains automatically while away."):format(SKILL_LABELS[focus] or "focus")
			offlineSummary.TextColor3 = COLORS.Dim
		else
			offlineSummary.Text = "Pick Melee or Defense above to train it while you're offline."
			offlineSummary.TextColor3 = COLORS.Dim
		end
	end

	-- ---- Shop panel ----
	-- Buy/sell the hub catalog's items using the server-authoritative Economy requests. Prices come
	-- straight from the read-model Shop; the client never prices, validates, or mutates anything.
	local shopGoldLabel = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 20), Position = UDim2.new(0, 0, 0, 0), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(240, 210, 90), Text = "Gold: --",
	}, shopContent)
	local shopList = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, -26), Position = UDim2.new(0, 0, 0, 26), BackgroundTransparency = 1,
		ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, shopContent)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, shopList)

	local function renderShop()
		for _, child in shopList:GetChildren() do
			if child:IsA("Frame") or child:IsA("TextLabel") then child:Destroy() end
		end
		if not lastState then return end
		shopGoldLabel.Text = "Gold: " .. tostring(lastState.Gold)
		local shop = lastState.Shop
		if type(shop) ~= "table" or type(shop.Entries) ~= "table" then
			return
		end
		local stacks = (lastState.Inventory and lastState.Inventory.Stacks) or {}
		local items = (lastState.Inventory and lastState.Inventory.Items) or {}
		local equippedWeapon = lastState.Equipment and lastState.Equipment[EquipmentSlots.Weapon]
		local equippedInstance = if type(equippedWeapon) == "table" then equippedWeapon.InstanceId else nil
		local order2 = 0
		for _, entry in shop.Entries do
			local defId = entry.ItemDefinitionId
			local def = ItemDefinitions.ById[defId]
			local isStack = def ~= nil and def.Kind == "Stackable"

			-- Owned count and, for discrete items, a real owned instance to sell (never fabricated). A
			-- non-equipped instance is preferred; if only the equipped one is owned the server rejects it.
			local ownedCount = 0
			local sellInstanceId: string? = nil
			local firstOwnedInstanceId: string? = nil
			if isStack then
				ownedCount = stacks[defId] or 0
			else
				for instanceId, item in items do
					if item.DefinitionId == defId then
						ownedCount += 1
						firstOwnedInstanceId = firstOwnedInstanceId or instanceId
						if instanceId ~= equippedInstance then
							sellInstanceId = sellInstanceId or instanceId
						end
					end
				end
				sellInstanceId = sellInstanceId or firstOwnedInstanceId
			end

			local row = make("Frame", { Size = UDim2.new(1, -6, 0, 40), BackgroundColor3 = COLORS.PanelAlt, LayoutOrder = order2 }, shopList)
			make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
			make("TextLabel", {
				Size = UDim2.new(1, -150, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1,
				Font = Enum.Font.Gotham, TextSize = 14, TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left,
				TextWrapped = true, Text = ("%s  (have %d)"):format(itemLabel(defId), ownedCount),
			}, row)
			if type(entry.BuyPrice) == "number" then
				local buy = make("TextButton", {
					Size = UDim2.new(0, 66, 0, 28), Position = UDim2.new(1, -146, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
					BackgroundColor3 = COLORS.Accent, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = COLORS.Text,
					Text = ("Buy %d"):format(entry.BuyPrice),
				}, row)
				make("UICorner", { CornerRadius = UDim.new(0, 6) }, buy)
				buy.Activated:Connect(function()
					if isStack then
						handlers.ShopBuy(shop.Id, defId, 1)
					else
						handlers.ShopBuyDiscrete(shop.Id, defId)
					end
				end)
			end
			-- Sell is offered when the catalog lists a sell price and the player actually owns the item:
			-- a quantity for a stackable resource, or a specific owned instance for a discrete item. The
			-- server re-validates the price and rejects equipped/invalid items.
			local canSell = type(entry.SellPrice) == "number" and (if isStack then ownedCount > 0 else sellInstanceId ~= nil)
			if canSell then
				local sell = make("TextButton", {
					Size = UDim2.new(0, 66, 0, 28), Position = UDim2.new(1, -74, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
					BackgroundColor3 = COLORS.Button, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = COLORS.Text,
					Text = ("Sell %d"):format(entry.SellPrice),
				}, row)
				make("UICorner", { CornerRadius = UDim.new(0, 6) }, sell)
				local instanceId = sellInstanceId
				sell.Activated:Connect(function()
					if isStack then
						handlers.ShopSell(shop.Id, defId, 1)
					elseif instanceId then
						handlers.ShopSellDiscrete(shop.Id, instanceId)
					end
				end)
			end
			order2 += 1
		end
	end

	-- ---- Mastery panel ----
	-- Inspect and spend Mastery from the authoritative read-model State (points, branches, node states,
	-- respec free/cost). The client only presents that state and forwards select/respec intent.
	local masterySelectedSkill = SkillIds.Melee
	local renderMastery: () -> ()
	local tabRow = make("Frame", { Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 0, 0), BackgroundTransparency = 1 }, masteryContent)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4),
		VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder,
	}, tabRow)
	local masteryTabs: { [string]: TextButton } = {}
	for index, skillId in SKILL_ORDER do
		local tab = make("TextButton", {
			Size = UDim2.new(0.25, -3, 1, 0), BackgroundColor3 = COLORS.Button, AutoButtonColor = true,
			Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = COLORS.Text, Text = SKILL_LABELS[skillId] or skillId, LayoutOrder = index,
		}, tabRow)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, tab)
		tab.Activated:Connect(function()
			masterySelectedSkill = skillId
			renderMastery()
		end)
		masteryTabs[skillId] = tab
	end
	local masteryPointsLabel = make("TextLabel", {
		Size = UDim2.new(1, -112, 0, 26), Position = UDim2.new(0, 0, 0, 36), BackgroundTransparency = 1,
		Font = Enum.Font.Gotham, TextSize = 14, TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left, Text = "",
	}, masteryContent)
	local respecBtn = make("TextButton", {
		Size = UDim2.new(0, 106, 0, 26), Position = UDim2.new(1, -106, 0, 36), BackgroundColor3 = COLORS.Button,
		Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = COLORS.Text, Text = "Respec",
	}, masteryContent)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, respecBtn)
	respecBtn.Activated:Connect(function() handlers.RespecMastery(masterySelectedSkill) end)
	local masteryList = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, -70), Position = UDim2.new(0, 0, 0, 70), BackgroundTransparency = 1,
		ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, masteryContent)
	make("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, masteryList)

	-- Compact presentation of an authoritative LockedReason; never recomputed here. Distinguishes the
	-- three real cases: required skill level, unmet prerequisite node, and insufficient Mastery Points.
	local function lockedTag(reason: any, requiredLevel: any): string
		if reason == "InsufficientSkillLevel" then
			return ("Need Lv %s"):format(tostring(requiredLevel))
		elseif reason == "PrerequisiteNodeNotSelected" then
			return "Prereq"
		elseif reason == "InsufficientMasteryPoints" then
			return "No points"
		end
		return "Locked"
	end

	function renderMastery()
		for skillId, tab in masteryTabs do
			tab.BackgroundColor3 = if skillId == masterySelectedSkill then COLORS.ButtonOn else COLORS.Button
		end
		for _, child in masteryList:GetChildren() do
			if child:IsA("Frame") or child:IsA("TextLabel") then child:Destroy() end
		end
		local m = lastState and lastState.Mastery and lastState.Mastery[masterySelectedSkill]
		if not m then
			masteryPointsLabel.Text = ""
			return
		end
		masteryPointsLabel.Text = ("Available %d · Earned %d · Spent %d"):format(m.AvailablePoints, m.EarnedPoints, m.SpentPoints)
		if m.FreeRespecAvailable == true then
			respecBtn.Text = "Free Respec"
			respecBtn.BackgroundColor3 = if (m.SpentPoints or 0) > 0 then COLORS.Accent else COLORS.Button
		elseif type(m.NextRespecGoldCost) == "number" and m.NextRespecGoldCost > 0 then
			respecBtn.Text = ("Respec %dg"):format(m.NextRespecGoldCost)
			respecBtn.BackgroundColor3 = COLORS.Accent
		else
			respecBtn.Text = "Respec"
			respecBtn.BackgroundColor3 = COLORS.Button
		end
		local order2 = 0
		for _, branch in m.Branches do
			make("TextLabel", {
				Size = UDim2.new(1, -6, 0, 18), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 13,
				TextColor3 = COLORS.Accent, TextXAlignment = Enum.TextXAlignment.Left, Text = branch.DisplayName, LayoutOrder = order2,
			}, masteryList)
			order2 += 1
			for _, node in branch.Nodes do
				local row = make("Frame", { Size = UDim2.new(1, -6, 0, 50), BackgroundColor3 = COLORS.PanelAlt, LayoutOrder = order2 }, masteryList)
				make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
				-- Two-line node: name, then the authoritative Description so the player understands what
				-- selecting it changes. Both come from the read model; nothing is computed here.
				make("TextLabel", {
					Size = UDim2.new(1, -88, 0, 18), Position = UDim2.new(0, 8, 0, 5), BackgroundTransparency = 1,
					Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left,
					Text = node.DisplayName,
				}, row)
				make("TextLabel", {
					Size = UDim2.new(1, -88, 0, 24), Position = UDim2.new(0, 8, 0, 23), BackgroundTransparency = 1,
					Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, Text = if type(node.Description) == "string" then node.Description else "",
				}, row)
				if node.Selected == true then
					local tag = make("TextLabel", {
						Size = UDim2.new(0, 78, 0, 24), Position = UDim2.new(1, -82, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
						BackgroundColor3 = COLORS.ButtonOn, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = COLORS.Text, Text = "Owned ✓",
					}, row)
					make("UICorner", { CornerRadius = UDim.new(0, 6) }, tag)
				elseif node.Selectable == true then
					local sel = make("TextButton", {
						Size = UDim2.new(0, 78, 0, 24), Position = UDim2.new(1, -82, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
						BackgroundColor3 = COLORS.Accent, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = COLORS.Text, Text = "Select",
					}, row)
					make("UICorner", { CornerRadius = UDim.new(0, 6) }, sel)
					local nodeId = node.Id
					sel.Activated:Connect(function() handlers.SelectMastery(masterySelectedSkill, nodeId) end)
				else
					local tag = make("TextLabel", {
						Size = UDim2.new(0, 78, 0, 24), Position = UDim2.new(1, -82, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
						BackgroundColor3 = Color3.fromRGB(45, 47, 55), Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = COLORS.Dim,
						Text = lockedTag(node.LockedReason, node.RequiredLevel),
					}, row)
					make("UICorner", { CornerRadius = UDim.new(0, 6) }, tag)
				end
				order2 += 1
			end
		end
	end

	-- ---- Skills progress panel ----
	-- A compact progress surface distinct from the Mastery detail: per slice skill, the authoritative
	-- level, XP progress toward the next level (or MAX at the cap), and a shortcut into that skill's
	-- Mastery tree (badging any available point). All values come straight from the read model.
	local function openMastery(skillId: string)
		masterySelectedSkill = skillId
		hideAllPanels()
		renderMastery()
		masteryPanel.Visible = true
	end
	-- One-line framing so the skill → XP → Mastery relationship reads at a glance: train a skill toward
	-- level milestones, which grant Mastery Points to spend in that skill's tree via the "Mastery" button.
	-- (Points come at milestone levels, not every level; the authoritative thresholds live server-side.)
	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12,
		TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true, Text = "Reach level milestones in a skill to earn Mastery Points, then spend them in its tree.",
	}, skillsContent)
	local skillsList = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 1, -32), Position = UDim2.new(0, 0, 0, 32), BackgroundTransparency = 1, ScrollBarThickness = 4,
		CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, skillsContent)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, skillsList)
	local function renderSkills()
		for _, child in skillsList:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		if not lastState then
			return
		end
		local order2 = 0
		for _, skillId in SKILL_ORDER do
			local s = lastState.Skills and lastState.Skills[skillId]
			local row = make("Frame", { Size = UDim2.new(1, -6, 0, 52), BackgroundColor3 = COLORS.PanelAlt, LayoutOrder = order2 }, skillsList)
			make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
			make("TextLabel", {
				Size = UDim2.new(1, -104, 0, 18), Position = UDim2.new(0, 8, 0, 4), BackgroundTransparency = 1,
				Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left,
				Text = ("%s   Lv %d"):format(SKILL_LABELS[skillId], if s then s.Level else 0),
			}, row)
			-- XP progress within the current level, or MAX at the cap (XPForNextLevel is nil there).
			local track = make("Frame", { Size = UDim2.new(1, -104, 0, 12), Position = UDim2.new(0, 8, 0, 26), BackgroundColor3 = Color3.fromRGB(50, 52, 60) }, row)
			make("UICorner", { CornerRadius = UDim.new(0, 4) }, track)
			local fill = make("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = COLORS.Accent, BorderSizePixel = 0 }, track)
			make("UICorner", { CornerRadius = UDim.new(0, 4) }, fill)
			local progressText = make("TextLabel", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 10, TextColor3 = COLORS.Text, Text = "" }, track)
			if s and type(s.XPForNextLevel) == "number" and type(s.XPAtLevel) == "number" then
				local span = s.XPForNextLevel - s.XPAtLevel
				local into = s.XP - s.XPAtLevel
				local frac = if span > 0 then math.clamp(into / span, 0, 1) else 0
				fill.Size = UDim2.new(frac, 0, 1, 0)
				progressText.Text = ("%d / %d XP"):format(math.floor(into + 0.5), math.floor(span + 0.5))
			else
				fill.Size = UDim2.new(1, 0, 1, 0)
				fill.BackgroundColor3 = COLORS.Good
				progressText.Text = "MAX"
			end
			-- Shortcut into the Mastery tree for this skill, badging any spendable points.
			local mastery = lastState.Mastery and lastState.Mastery[skillId]
			local available = if mastery and type(mastery.AvailablePoints) == "number" then mastery.AvailablePoints else 0
			local masteryBtn = make("TextButton", {
				Size = UDim2.new(0, 92, 0, 30), Position = UDim2.new(1, -96, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
				BackgroundColor3 = if available > 0 then COLORS.ButtonOn else COLORS.Button, Font = Enum.Font.GothamMedium,
				TextSize = 12, TextColor3 = COLORS.Text, Text = if available > 0 then ("Mastery (%d)"):format(available) else "Mastery",
			}, row)
			make("UICorner", { CornerRadius = UDim.new(0, 6) }, masteryBtn)
			masteryBtn.Activated:Connect(function() openMastery(skillId) end)
			order2 += 1
		end
	end

	-- ===== Public update / context APIs =====
	local iface: any = {}
	iface.Handlers = handlers
	iface.SetStatus = setStatus

	-- Renders a sanitized boss personal-reward push (see Composition/PlayerEvents) as a temporary toast.
	-- Pure presentation of server-authoritative data; the client never grants anything from this.
	function iface.ShowBossReward(payload: any)
		SoundController.Play("BossReward")
		if type(payload) ~= "table" then
			return
		end
		local boss = bossLabel(payload.BossDefinitionId)
		-- Three distinct states. Reward details are shown only when the reward was actually granted, so
		-- no fabricated Gold/items ever appear. Internal failure reasons are never surfaced.
		if payload.Qualified ~= true then
			showToast(("You joined the fight against %s, but didn't deal enough damage to earn a reward."):format(boss), COLORS.Dim)
			return
		end
		if payload.RewardGranted ~= true then
			showToast(("You earned a %s reward, but it couldn't be granted right now."):format(boss), COLORS.Bad)
			return
		end
		local lines = { ("Defeated %s!"):format(boss) }
		local gold = if type(payload.GoldAwarded) == "number" then math.floor(payload.GoldAwarded + 0.5) else 0
		if gold > 0 then
			table.insert(lines, ("+%d Gold"):format(gold))
		end
		if type(payload.CommonItemDefinitionId) == "string" then
			local amount = if type(payload.CommonItemAmount) == "number" then payload.CommonItemAmount else 1
			table.insert(lines, ("%dx %s"):format(amount, itemLabel(payload.CommonItemDefinitionId)))
		end
		-- A rare drop gets the warm gold accent (not the routine green), so it clearly reads as special.
		local gotRare = type(payload.RareItemDefinitionId) == "string"
		if gotRare then
			local amount = if type(payload.RareItemAmount) == "number" then payload.RareItemAmount else 1
			table.insert(lines, ("★ RARE  —  %dx %s"):format(amount, itemLabel(payload.RareItemDefinitionId)))
		end
		showToast(table.concat(lines, "\n"), if gotRare then COLORS.Rare else COLORS.Good)
	end

	-- Renders the compact current-objective surface from the sanitized authoritative Onboarding view and
	-- surfaces brief step-advance/completion feedback. The server owns completion; this only presents it.
	-- The step id mirrors Onboarding/Definitions StepIds.StarterFocus (a stable id).
	local STARTER_FOCUS_STEP_ID = "onboarding_starter_focus"
	local lastObjectiveStepId: string? = nil
	local starterAutoOpened = false
	-- Whether the objective banner is currently showing an onboarding step or the post-onboarding
	-- Ascension goal, so a tap routes to the right place.
	local objectiveMode: string = "onboarding"
	-- Where each boss-milestone requirement is earned, so the next-rank goal can name a PLACE to go.
	local MILESTONE_INFO: { [string]: { Boss: string, Zone: string } } = {
		flag_boss_goblin_chieftain_defeated = { Boss = "Goblin Chieftain", Zone = "the Goblin Warren" },
		flag_boss_bandit_warlord_defeated = { Boss = "Bandit Warlord", Zone = "the Ashen Ruins" },
	}
	-- After onboarding, the objective banner becomes a live "next Ascension rank" goal: it names the rank
	-- and the single most salient unmet requirement (boss first -- it's a landmark + a place -- then the
	-- skill gates), so the player always has a concrete reason and direction. Nil at the top of the ladder.
	local function nextRankGoal(ascension: any): ({ Title: string, Hint: string })?
		if type(ascension) ~= "table" then
			return nil
		end
		if type(ascension.NextRank) ~= "table" then
			-- Top of the ladder: keep a forward-looking goal so the endgame never dead-ends into a blank
			-- banner. There is always more to master, and new regions are on the roadmap.
			return {
				Title = ("Highest rank: %s"):format(tostring(ascension.RankDisplayName or "—")),
				Hint = "Master every skill tree and gear tier — new frontiers are on the way.",
			}
		end
		local nextRank = ascension.NextRank
		local p = nextRank.Progress
		if type(p) ~= "table" then
			return nil
		end
		local hint: string? = nil
		if type(p.BossMilestone) == "table" and p.BossMilestone.Met ~= true then
			local info = MILESTONE_INFO[p.BossMilestone.MilestoneId]
			hint = if info then ("Defeat the %s in %s"):format(info.Boss, info.Zone) else "Defeat the region boss"
		end
		if not hint and type(p.Offense) == "table" and p.Offense.Met ~= true and type(p.Offense.Alternatives) == "table" then
			local alt = p.Offense.Alternatives[1]
			if alt then
				hint = ("Train %s to Level %d (%d/%d)"):format(SKILL_LABELS[alt.SkillId] or alt.SkillId, alt.RequiredLevel, alt.CurrentLevel, alt.RequiredLevel)
			end
		end
		if not hint and type(p.Defense) == "table" and p.Defense.Met ~= true then
			hint = ("Train Defense to Level %d (%d/%d)"):format(p.Defense.RequiredLevel, p.Defense.CurrentLevel, p.Defense.RequiredLevel)
		end
		if not hint and type(p.OverallSkilling) == "table" and p.OverallSkilling.Met ~= true and type(p.OverallSkilling.Thresholds) == "table" then
			for _, th in p.OverallSkilling.Thresholds do
				if th.Met ~= true then
					hint = ("Train %s to Level %d (%d/%d)"):format(SKILL_LABELS[th.SkillId] or th.SkillId, th.RequiredLevel, th.CurrentLevel, th.RequiredLevel)
					break
				end
			end
		end
		if not hint then
			hint = ("All set — open Menu → Ascend to become %s!"):format(tostring(nextRank.DisplayName))
		end
		return { Title = ("Next rank: %s"):format(tostring(nextRank.DisplayName)), Hint = hint }
	end
	local function renderObjective(state: any)
		local ob = state.Onboarding
		if type(ob) ~= "table" then
			return
		end
		if ob.Complete == true then
			if lastObjectiveStepId ~= nil and lastObjectiveStepId ~= "__complete__" then
				showToast("You're now an Adept — your guided journey is complete!", COLORS.Good)
			end
			lastObjectiveStepId = "__complete__"
			-- Onboarding done: the objective banner becomes the live "next Ascension rank" goal, routing
			-- the player toward the next rank (and the boss/skills it needs). Nil only at the top rank.
			local goal = nextRankGoal(state.Ascension)
			if goal then
				objectiveMode = "ascension"
				objective.Visible = not bossActive
				objectiveTitle.Text = goal.Title
				objectiveHint.Text = goal.Hint
			else
				objective.Visible = false
			end
			return
		end
		objectiveMode = "onboarding"
		-- Yields to the boss bar so the two top-center surfaces never compete for attention.
		objective.Visible = not bossActive
		local progressText = ""
		local progress = ob.Progress
		if type(progress) == "table" and type(progress.Current) == "number" and type(progress.Required) == "number" then
			progressText = ("   %d / %d"):format(progress.Current, progress.Required)
		end
		objectiveTitle.Text = ("Objective: %s%s"):format(tostring(ob.Title), progressText)
		objectiveHint.Text = tostring(ob.Hint)
		if ob.StepId == STARTER_FOCUS_STEP_ID and not starterAutoOpened then
			starterAutoOpened = true
			hideAllPanels()
			starterPanel.Visible = true
		end
		if lastObjectiveStepId ~= nil and lastObjectiveStepId ~= "__complete__" and lastObjectiveStepId ~= ob.StepId then
			SoundController.Play("Objective")
			showToast(("Objective complete!\nNext: %s"):format(tostring(ob.Title)), COLORS.Good)
		end
		lastObjectiveStepId = ob.StepId
	end
	-- Tapping the objective routes the player: on the starter-focus step it reopens that framing panel;
	-- once it is the post-onboarding Ascension goal, it opens the Ascend panel (the full requirement list).
	objective.Activated:Connect(function()
		if objectiveMode == "ascension" then
			hideAllPanels()
			renderAscend()
			ascendPanel.Visible = true
		elseif lastObjectiveStepId == STARTER_FOCUS_STEP_ID then
			hideAllPanels()
			starterPanel.Visible = true
		end
	end)

	-- Reflects the current combat target and any engaged boss onto the target readout / boss bar. Pure
	-- presentation of authoritative values the Controller reads from the bound enemy models.
	function iface.SetCombat(ctx: any)
		local target = if type(ctx) == "table" then ctx.Target else nil
		if type(target) == "table" then
			targetName.Text = ("%s   Lv %s"):format(tostring(target.Name), tostring(target.Level))
			setHealthBar(targetFill, targetHealthText, target.Health, target.MaxHealth)
			targetPanel.Visible = true
		else
			targetPanel.Visible = false
		end
		local boss = if type(ctx) == "table" then ctx.Boss else nil
		local bossShown = type(boss) == "table"
		if bossShown then
			bossName.Text = tostring(boss.Name)
			setHealthBar(bossFill, bossHealthText, boss.Health, boss.MaxHealth)
			bossBar.Visible = true
		else
			bossBar.Visible = false
		end
		-- When the boss bar appears/disappears, re-apply the objective's visibility so it yields to (and
		-- returns after) the boss encounter.
		if bossShown ~= bossActive then
			bossActive = bossShown
			if type(lastState) == "table" then
				renderObjective(lastState)
			end
		end
	end

	-- Aggregated Gold/XP gains and level/Mastery feedback, derived by comparing successive AUTHORITATIVE
	-- snapshots. Presentation only: it reports what the server already granted and never awards anything.
	-- Gains are buffered and flushed briefly so continuous mining/training never becomes per-tick spam.
	local gainsGold = 0
	local gainsXP: { [string]: number } = {}
	local gainsPending = false
	local flushCounter = 0
	local function flushGains()
		local parts = {}
		if gainsGold > 0 then
			table.insert(parts, ("+%d Gold"):format(gainsGold))
		end
		for _, skillId in SKILL_ORDER do
			local amount = gainsXP[skillId]
			if amount and amount > 0 then
				table.insert(parts, ("+%d %s XP"):format(amount, SKILL_LABELS[skillId]))
			end
		end
		gainsGold = 0
		gainsXP = {}
		gainsPending = false
		if #parts > 0 then
			showToast(table.concat(parts, "   "), COLORS.Accent)
		end
	end
	local function detectProgressionFeedback(previous: any, state: any)
		if type(previous) ~= "table" then
			return -- the first snapshot only establishes the baseline; never announce pre-existing progress
		end
		local prevSkills = if type(previous.Skills) == "table" then previous.Skills else {}
		local newSkills = if type(state.Skills) == "table" then state.Skills else {}
		local prevMastery = if type(previous.Mastery) == "table" then previous.Mastery else {}
		local newMastery = if type(state.Mastery) == "table" then state.Mastery else {}
		for _, skillId in SKILL_ORDER do
			local oldS = prevSkills[skillId]
			local newS = newSkills[skillId]
			if type(oldS) == "table" and type(newS) == "table" then
				if type(newS.XP) == "number" and type(oldS.XP) == "number" and newS.XP > oldS.XP then
					gainsXP[skillId] = (gainsXP[skillId] or 0) + (newS.XP - oldS.XP)
					gainsPending = true
				end
				-- A level gain (with any Mastery Points it unlocked this refresh) is an immediate toast.
				if type(newS.Level) == "number" and type(oldS.Level) == "number" and newS.Level > oldS.Level then
					local oldM = prevMastery[skillId]
					local newM = newMastery[skillId]
					local pointsDelta = 0
					if type(oldM) == "table" and type(newM) == "table" and type(newM.EarnedPoints) == "number" and type(oldM.EarnedPoints) == "number" then
						pointsDelta = newM.EarnedPoints - oldM.EarnedPoints
					end
					local extra = if pointsDelta == 1 then "   ·   +1 Mastery Point" elseif pointsDelta > 1 then ("   ·   +%d Mastery Points"):format(pointsDelta) else ""
					SoundController.Play("LevelUp")
					showToast(("%s reached Level %d!%s"):format(SKILL_LABELS[skillId], newS.Level, extra), COLORS.Good)
				end
			end
		end
		if type(state.Gold) == "number" and type(previous.Gold) == "number" and state.Gold > previous.Gold then
			gainsGold += (state.Gold - previous.Gold)
			gainsPending = true
		end
		flushCounter += 1
		if gainsPending and flushCounter >= 3 then
			flushCounter = 0
			flushGains()
		end
	end

	function iface.Update(state: any)
		local previous = lastState
		lastState = state
		if type(state) ~= "table" then return end
		goldLabel.Text = "Gold: " .. tostring(state.Gold)
		renderObjective(state)
		if state.Health then
			healthLabel.Text = ("Health: %d / %d"):format(math.floor(state.Health.Health + 0.5), state.Health.MaxHealth)
		end
		if state.Skills then
			for _, skillId in SKILL_ORDER do
				local s = state.Skills[skillId]
				if s then
					skillLabels[skillId].Text = ("%s: Lv %d"):format(SKILL_LABELS[skillId], s.Level)
				end
			end
		end
		-- Spendable Mastery Points across all skills, surfaced on the Menu button and Skills entry so the
		-- skill → XP → points → tree relationship is visible without opening a panel.
		local totalAvailable = 0
		if type(state.Mastery) == "table" then
			for _, skillId in SKILL_ORDER do
				local m = state.Mastery[skillId]
				if type(m) == "table" and type(m.AvailablePoints) == "number" then
					totalAvailable += m.AvailablePoints
				end
			end
		end
		iface.SetMasteryBadge(totalAvailable)
		if forgePanel.Visible then renderForge() end
		if gearPanel.Visible then renderGear() end
		if ascendPanel.Visible then renderAscend() end
		if offlinePanel.Visible then renderOffline() end
		if shopPanel.Visible then renderShop() end
		if masteryPanel.Visible then renderMastery() end
		if skillsPanel.Visible then renderSkills() end
		detectProgressionFeedback(previous, state)
	end

	-- Opens the Offline panel showing the current focus and the latest While You Were Away summary.
	-- The Controller calls this on a rewarded offline return so the summary surfaces on rejoin.
	function iface.OpenOfflineReturn()
		hideAllPanels()
		renderOffline()
		offlinePanel.Visible = true
	end

	-- ===== Contextual interaction info: one compact surface for the nearby station / node / forge / shop =====
	local contextInfo = make("Frame", {
		Size = UDim2.new(1, -40, 0, 40), Position = UDim2.new(0.5, 0, 1, -126), AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.2, Visible = false,
	}, screen)
	make("UICorner", { CornerRadius = UDim.new(0, 6) }, contextInfo)
	make("UIStroke", { Color = COLORS.Accent, Thickness = 1, Transparency = 0.5 }, contextInfo)
	capSize(contextInfo, 340)
	make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, contextInfo)
	local contextTitle = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 13,
		TextColor3 = COLORS.Text, TextXAlignment = Enum.TextXAlignment.Left, Text = "",
	}, contextInfo)
	local contextDetail = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 14), Position = UDim2.new(0, 0, 0, 18), BackgroundTransparency = 1, Font = Enum.Font.Gotham,
		TextSize = 11, TextColor3 = COLORS.Dim, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "",
	}, contextInfo)

	-- Builds the contextual info from authoritative read-model state (station tiers/rates, node
	-- requirements, equipped tool, skill levels). All balance data comes from the server; this only
	-- presents it. Eligibility shown here is a hint -- the server independently validates every action.
	local function renderContextInfo(ctx: any)
		if ctx.NearStationId ~= nil then
			local st = lastState and lastState.PlotStations and lastState.PlotStations[ctx.NearStationId]
			local skillLabel = if st and SKILL_LABELS[st.SkillId] then SKILL_LABELS[st.SkillId] else "Training"
			contextTitle.Text = ("%s Station  —  Tier %s"):format(skillLabel, if st then tostring(st.Tier) else "?")
			if st then
				local base = ("+%s XP/s"):format(tostring(st.XPPerSecond))
				local upgrade = if type(st.NextUpgradeCostGold) == "number"
					then ("Upgrade %dg → +%s XP/s"):format(st.NextUpgradeCostGold, tostring(st.NextXPPerSecond))
					else "Max tier"
				contextDetail.Text = if ctx.TrainingActive then ("Training…   (%s)"):format(base) else (base .. "   ·   " .. upgrade)
			else
				contextDetail.Text = ""
			end
			contextInfo.Visible = true
			return
		end
		if ctx.NearNode == true then
			local node = if lastState and type(lastState.GatheringNodes) == "table" then lastState.GatheringNodes[1] else nil
			local name = if node then node.DisplayName else "Iron Ore"
			local reqLevel = if node then node.RequiredMiningLevel else 1
			contextTitle.Text = ("%s  —  Mining Lv %s"):format(tostring(name), tostring(reqLevel))
			local tool = lastState and lastState.Equipment and lastState.Equipment[EquipmentSlots.Tool]
			local toolName = if type(tool) == "table" then itemLabel(tool.DefinitionId) else nil
			local miningLevel = (lastState and lastState.Skills and lastState.Skills[SkillIds.Mining] and lastState.Skills[SkillIds.Mining].Level) or 0
			local status
			if ctx.MiningActive then
				status = "Mining…"
			elseif toolName == nil then
				status = "Equip a pickaxe (Tool)"
			elseif miningLevel < reqLevel then
				status = ("Need Mining Lv %d"):format(reqLevel)
			else
				status = "Ready — press Mine"
			end
			contextDetail.Text = ("Tool: %s   ·   %s"):format(if toolName then toolName else "none", status)
			contextInfo.Visible = true
			return
		end
		if ctx.NearForge == true then
			contextTitle.Text = "Forge"
			contextDetail.Text = "Open Forge to smelt bars and craft."
			contextInfo.Visible = true
			return
		end
		if ctx.NearShop == true then
			contextTitle.Text = "Shop"
			contextDetail.Text = "Open Shop to buy and sell."
			contextInfo.Visible = true
			return
		end
		contextInfo.Visible = false
	end

	-- ctx: { NearStationId: string?, NearNode: boolean, NearForge: boolean, NearShop: boolean,
	--        TrainingActive: boolean?, MiningActive: boolean? }
	function iface.SetContext(ctx: any)
		-- World-contextual buttons are shown only where the action is actually possible (or in progress),
		-- so the bar never carries permanently prominent buttons for actions the player can't do here.
		-- The server still owns proximity authority; hiding a button is presentation only.
		local nearStation = ctx.NearStationId ~= nil
		-- Read the nearby station's authoritative state once (skill label, and whether a next tier exists).
		local station = if nearStation and lastState and lastState.PlotStations then lastState.PlotStations[ctx.NearStationId] else nil
		local trainUsable = nearStation or ctx.TrainingActive == true
		trainBtn.Visible = trainUsable
		trainBtn.Active = trainUsable
		trainBtn.AutoButtonColor = trainUsable
		-- Name the trained skill so the player knows Melee vs Defense, not a generic Train.
		local stationSkillLabel = if station then SKILL_LABELS[station.SkillId] else nil
		trainBtn.Text = if ctx.TrainingActive then "Stop Train" elseif stationSkillLabel then ("Train %s"):format(stationSkillLabel) else "Train"
		trainBtn.BackgroundColor3 = if ctx.TrainingActive then COLORS.ButtonOn elseif nearStation then COLORS.Button else COLORS.Disabled
		-- Upgrade only makes sense where a next tier actually exists; a max-tier station (authoritative
		-- NextUpgradeCostGold == nil) shows its "Max tier" context line but no Upgrade action. Cost comes
		-- straight from the read model -- tier definitions are never duplicated client-side.
		local upgradeUsable = station ~= nil and type(station.NextUpgradeCostGold) == "number"
		upgradeBtn.Visible = upgradeUsable
		upgradeBtn.Active = upgradeUsable
		upgradeBtn.AutoButtonColor = upgradeUsable
		upgradeBtn.Text = if upgradeUsable then ("Upgrade (%d g)"):format(station.NextUpgradeCostGold) else "Upgrade"

		local mineUsable = ctx.NearNode == true or ctx.MiningActive == true
		mineBtn.Visible = mineUsable
		mineBtn.Active = mineUsable
		mineBtn.AutoButtonColor = mineUsable
		mineBtn.Text = if ctx.MiningActive then "Stop Mine" else "Mine"
		mineBtn.BackgroundColor3 = if ctx.MiningActive then COLORS.ButtonOn elseif ctx.NearNode then COLORS.Button else COLORS.Disabled

		local nearForge = ctx.NearForge == true
		forgeBtn.Visible = nearForge
		forgeBtn.Active = nearForge
		forgeBtn.AutoButtonColor = nearForge
		forgeBtn.BackgroundColor3 = if nearForge then COLORS.Button else COLORS.Disabled
		-- Once the player walks away from the Forge, the panel/action must stop behaving as usable
		-- (the server also rejects a far craft). Close it so the buttons can't be tapped from afar.
		if not nearForge then
			forgePanel.Visible = false
		end

		-- Shop is a contextual world interaction, mirroring the Forge: usable only near the shop, and the
		-- panel closes when the player walks away (the server rejects a far transaction regardless).
		local nearShop = ctx.NearShop == true
		shopBtn.Visible = nearShop
		shopBtn.Active = nearShop
		shopBtn.AutoButtonColor = nearShop
		shopBtn.BackgroundColor3 = if nearShop then COLORS.Button else COLORS.Disabled
		if not nearShop then
			shopPanel.Visible = false
		end

		renderContextInfo(ctx)
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
	forgeBtn.Activated:Connect(function() hideAllPanels(); renderForge(); forgePanel.Visible = true end)
	shopBtn.Activated:Connect(function() hideAllPanels(); renderShop(); shopPanel.Visible = true end)

	-- ===== Progression menu (grouped destinations) =====
	-- Gear, Skills, Ascend, and Offline live behind one "Menu" button instead of each holding a
	-- permanent bar slot. This is a single flat popup, not a nested menu tree.
	local menuFrame = make("Frame", {
		Size = UDim2.new(0, 176, 0, 0), Position = UDim2.new(1, -12, 1, -80), AnchorPoint = Vector2.new(1, 1),
		BackgroundColor3 = COLORS.Panel, BackgroundTransparency = 0.05, Visible = false, AutomaticSize = Enum.AutomaticSize.Y,
	}, screen)
	menu = menuFrame -- share the forward-declared handle so hideAllPanels() closes it too
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, menuFrame)
	make("UIStroke", { Color = COLORS.Accent, Thickness = 1, Transparency = 0.4 }, menuFrame)
	make("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, menuFrame)
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, menuFrame)

	-- ---- Map panel ----
	-- A schematic top-down map of Region I: each zone plotted by its world centre (RegionDefinitions),
	-- discovered vs unknown from the read-model Discovery set, with a live player marker. Client-only
	-- presentation over data the server already owns.
	local mapArea = make("Frame", {
		Size = UDim2.new(1, 0, 1, -6), Position = UDim2.new(0, 0, 0, 3), BackgroundColor3 = COLORS.PanelAlt,
		ClipsDescendants = true,
	}, mapContent)
	make("UICorner", { CornerRadius = UDim.new(0, 8) }, mapArea)
	-- Difficulty hue by zone tier (safe -> deadly), so the map reads as a gradient outward from town.
	local TIER_COLORS: { [number]: Color3 } = {
		[1] = Color3.fromRGB(120, 200, 130),
		[2] = Color3.fromRGB(210, 200, 110),
		[3] = Color3.fromRGB(220, 150, 90),
		[4] = Color3.fromRGB(220, 110, 100),
	}
	-- Plotted world half-extent (studs); covers every zone centre with a margin.
	local MAP_WORLD_EXTENT = 380
	local function worldToMapScale(x: number, z: number): (number, number)
		-- East (+x) -> right; North (+z) -> up. Clamped so a far-flung marker stays on the map.
		local u = math.clamp((x + MAP_WORLD_EXTENT) / (2 * MAP_WORLD_EXTENT), 0.04, 0.96)
		local v = math.clamp((MAP_WORLD_EXTENT - z) / (2 * MAP_WORLD_EXTENT), 0.06, 0.94)
		return u, v
	end
	-- Persistent player marker (repositioned live by UpdateMapMarker), above the zone dots.
	local playerDot = make("Frame", {
		Size = UDim2.new(0, 12, 0, 12), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = COLORS.Accent,
		BorderSizePixel = 0, ZIndex = 6, Visible = false,
	}, mapArea)
	make("UICorner", { CornerRadius = UDim.new(1, 0) }, playerDot)
	make("UIStroke", { Color = COLORS.Text, Thickness = 1.5 }, playerDot)

	-- The boss whose milestone gates the player's NEXT rank tells the map which zone to flag as the
	-- current goal; boss arenas are plotted so that goal has a visible place. Keyed by the stable ids the
	-- read model / territory markers report.
	local MAP_MILESTONE_ZONE: { [string]: string } = {
		flag_boss_goblin_chieftain_defeated = "zone_goblin_warren",
		flag_boss_bandit_warlord_defeated = "zone_ashen_ruins",
	}
	local MAP_BOSS_LABELS: { [string]: string } = {
		enemy_goblin_chieftain = "Goblin Chieftain",
		enemy_bandit_warlord = "Bandit Warlord",
	}
	local function renderMap()
		for _, child in mapArea:GetChildren() do
			if child ~= playerDot and (child:IsA("Frame") or child:IsA("TextLabel")) then
				child:Destroy()
			end
		end
		local discovered = (lastState and lastState.Discovery and lastState.Discovery.DiscoveredZoneIds) or {}
		-- Which zone is the current objective: the one holding the boss the player's next rank still needs.
		local objectiveZoneId: string? = nil
		local nextRank = lastState and lastState.Ascension and lastState.Ascension.NextRank
		if type(nextRank) == "table" and type(nextRank.Progress) == "table" then
			local milestone = nextRank.Progress.BossMilestone
			if type(milestone) == "table" and milestone.Met ~= true then
				objectiveZoneId = MAP_MILESTONE_ZONE[milestone.MilestoneId]
			end
		end
		for i, zone in RegionDefinitions.Zones do
			local u, v = worldToMapScale(zone.CenterX, zone.CenterZ)
			local known = zone.Safe == true or discovered[zone.Id] == true
			local isObjective = zone.Id == objectiveZoneId
			-- Highlight ring behind the current-objective zone so the player sees WHERE to go next.
			if isObjective then
				local ring = make("Frame", {
					Size = UDim2.new(0, 30, 0, 30), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(u, 0, v, 0),
					BackgroundColor3 = COLORS.Good, BackgroundTransparency = 0.75, BorderSizePixel = 0, ZIndex = 2,
				}, mapArea)
				make("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
				make("UIStroke", { Color = COLORS.Good, Thickness = 1.5, Transparency = 0.1 }, ring)
			end
			local dot = make("Frame", {
				Size = UDim2.new(0, 14, 0, 14), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(u, 0, v, 0),
				BackgroundColor3 = if known then (TIER_COLORS[zone.Tier] or COLORS.Accent) else COLORS.Dim,
				BorderSizePixel = 0, ZIndex = 3,
			}, mapArea)
			make("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
			-- Stagger labels vertically by index so neighbouring zones (e.g. the eastern Meadow + Warren,
			-- which sit close together) don't overprint each other.
			local labelYOffset = 10 + (i % 2) * 16
			-- Anchor labels toward the interior near the panel edges so long names don't clip.
			local ax = if u > 0.72 then 1 elseif u < 0.28 then 0 else 0.5
			local ox = if ax == 1 then -6 elseif ax == 0 then 6 else 0
			make("TextLabel", {
				Size = UDim2.new(0, 118, 0, 14), AnchorPoint = Vector2.new(ax, 0), Position = UDim2.new(u, ox, v, labelYOffset),
				TextXAlignment = if ax == 1 then Enum.TextXAlignment.Right elseif ax == 0 then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center,
				BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 11,
				TextColor3 = if isObjective then COLORS.Good elseif known then COLORS.Text else COLORS.Dim,
				Text = if isObjective then ("▶ " .. zone.DisplayName) elseif known then zone.DisplayName else "???",
				ZIndex = 4,
			}, mapArea)
		end

		-- Plot the boss arenas (from their placed territory markers) as red diamonds, so the map shows the
		-- landmark goals -- and, with the objective ring above, exactly which boss the next rank needs.
		for _, marker in CollectionService:GetTagged("AR_EnemyTerritory") do
			if marker:IsA("BasePart") then
				local definitionId = marker:GetAttribute("EnemyDefinitionId")
				local label = if type(definitionId) == "string" then MAP_BOSS_LABELS[definitionId] else nil
				if label then
					local u, v = worldToMapScale(marker.Position.X, marker.Position.Z)
					local diamond = make("Frame", {
						Size = UDim2.new(0, 12, 0, 12), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(u, 0, v, 0),
						BackgroundColor3 = Color3.fromRGB(214, 74, 74), BorderSizePixel = 0, Rotation = 45, ZIndex = 5,
					}, mapArea)
					make("UIStroke", { Color = COLORS.Text, Thickness = 1 }, diamond)
					local bax = if u > 0.72 then 1 elseif u < 0.28 then 0 else 0.5
					local box = if bax == 1 then -6 elseif bax == 0 then 6 else 0
					make("TextLabel", {
						Size = UDim2.new(0, 118, 0, 12), AnchorPoint = Vector2.new(bax, 1), Position = UDim2.new(u, box, v, -10),
						TextXAlignment = if bax == 1 then Enum.TextXAlignment.Right elseif bax == 0 then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center,
						BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 10,
						TextColor3 = Color3.fromRGB(235, 150, 150), Text = label, ZIndex = 5,
					}, mapArea)
				end
			end
		end
	end

	-- Live player marker, driven cheaply from the Controller's proximity loop (only moves a frame).
	function iface.UpdateMapMarker(x: number, z: number)
		if not mapPanel.Visible then
			return
		end
		local u, v = worldToMapScale(x, z)
		playerDot.Position = UDim2.new(u, 0, v, 0)
		playerDot.Visible = true
	end

	local function menuEntry(text: string, order2: number, open: () -> ()): TextButton
		local b = make("TextButton", {
			Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = COLORS.Button, AutoButtonColor = true,
			Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = COLORS.Text, Text = text, LayoutOrder = order2,
		}, menuFrame)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, b)
		-- hideAllPanels() closes this Menu popup as well, so opening a destination never leaves it behind.
		b.Activated:Connect(function()
			hideAllPanels()
			open()
		end)
		return b
	end
	menuEntry("Gear", 1, function() renderGear(); gearPanel.Visible = true end)
	-- The Skills entry opens the compact progress surface; Mastery is reached from a skill row there.
	local skillsMenuEntry = menuEntry("Skills", 2, function() renderSkills(); skillsPanel.Visible = true end)
	menuEntry("Ascend", 3, function() renderAscend(); ascendPanel.Visible = true end)
	menuEntry("Offline", 4, function() renderOffline(); offlinePanel.Visible = true end)
	menuEntry("Map", 5, function() renderMap(); mapPanel.Visible = true end)

	menuBtn.Activated:Connect(function()
		if menuFrame.Visible then
			menuFrame.Visible = false
		else
			-- Mutually exclusive with the modal panels: close any open panel, then show the Menu.
			hideAllPanels()
			menuFrame.Visible = true
		end
	end)

	-- Reflects spendable Mastery Points onto the Menu button and its Skills entry, so the player can see
	-- there's progression to spend without opening anything. Purely derived from authoritative state.
	function iface.SetMasteryBadge(totalAvailable: number)
		if totalAvailable > 0 then
			menuBtn.Text = ("Menu (%d)"):format(totalAvailable)
			menuBtn.BackgroundColor3 = COLORS.ButtonOn
			skillsMenuEntry.Text = ("Skills (%d)"):format(totalAvailable)
			skillsMenuEntry.BackgroundColor3 = COLORS.ButtonOn
		else
			menuBtn.Text = "Menu"
			menuBtn.BackgroundColor3 = COLORS.Button
			skillsMenuEntry.Text = "Skills"
			skillsMenuEntry.BackgroundColor3 = COLORS.Button
		end
	end

	-- ===== Region-entry banner (open-world zone announcements) =====
	-- A large, briefly-shown title + blurb when the player enters a named zone, so the world reads as
	-- distinct places. Presentation only; the Controller drives it from RegionDefinitions.ZoneAt.
	local TweenService = game:GetService("TweenService")
	local regionBanner = make("Frame", {
		Size = UDim2.new(1, -40, 0, 82), Position = UDim2.new(0.5, 0, 0.22, 0), AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(12, 14, 20), BackgroundTransparency = 1, Visible = false,
	}, screen)
	make("UICorner", { CornerRadius = UDim.new(0, 10) }, regionBanner)
	make("UIStroke", { Color = COLORS.Accent, Thickness = 1.5, Transparency = 1 }, regionBanner)
	capSize(regionBanner, 560)
	local regionTitle = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 46), BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 36,
		TextColor3 = COLORS.Text, TextTransparency = 1, TextStrokeColor3 = Color3.fromRGB(0, 0, 0), TextStrokeTransparency = 1, Text = "",
	}, regionBanner)
	local regionBlurb = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 22), Position = UDim2.new(0, 0, 0, 50), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
		TextSize = 15, TextColor3 = COLORS.Dim, TextTransparency = 1, TextStrokeColor3 = Color3.fromRGB(0, 0, 0), TextStrokeTransparency = 1,
		TextWrapped = true, Text = "",
	}, regionBanner)
	local bannerToken = 0
	function iface.ShowRegionBanner(displayName: any, blurb: any)
		SoundController.Play("Banner")
		bannerToken += 1
		local myToken = bannerToken
		regionTitle.Text = tostring(displayName)
		regionBlurb.Text = tostring(blurb or "")
		regionBanner.Visible = true
		local stroke = regionBanner:FindFirstChildOfClass("UIStroke")
		local tin = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(regionBanner, tin, { BackgroundTransparency = 0.28 }):Play()
		if stroke then TweenService:Create(stroke, tin, { Transparency = 0.35 }):Play() end
		TweenService:Create(regionTitle, tin, { TextTransparency = 0, TextStrokeTransparency = 0.2 }):Play()
		TweenService:Create(regionBlurb, tin, { TextTransparency = 0.05, TextStrokeTransparency = 0.4 }):Play()
		task.delay(2.8, function()
			if myToken ~= bannerToken then return end
			local tout = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			TweenService:Create(regionBanner, tout, { BackgroundTransparency = 1 }):Play()
			if stroke then TweenService:Create(stroke, tout, { Transparency = 1 }):Play() end
			TweenService:Create(regionTitle, tout, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			TweenService:Create(regionBlurb, tout, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			task.delay(0.75, function()
				if myToken == bannerToken then
					regionBanner.Visible = false
				end
			end)
		end)
	end

	-- First-visit discovery reward feedback (server-authoritative outcome), shown as a toast alongside
	-- the region-entry banner so exploration feels rewarded.
	function iface.ShowDiscovery(zoneName: any, rewardGold: any)
		SoundController.Play("Discovery")
		local name = if type(zoneName) == "string" and zoneName ~= "" then zoneName else "a new area"
		local gold = if type(rewardGold) == "number" then rewardGold else 0
		if gold > 0 then
			showToast(("Discovered %s!\n+%d Gold"):format(name, gold), COLORS.Good)
		else
			showToast(("Discovered %s!"):format(name), COLORS.Good)
		end
	end

	return iface
end

return Interface
