--!strict

local RecipeIds = require("RecipeIds")
local CraftingDefinitions = require("CraftingDefinitions")
local ItemDefinitions = require("ItemDefinitions")
local ShopCatalog = require("ShopCatalog")
local SkillIds = require("SkillIds")
local SkillDefinitions = require("SkillDefinitions")
local Skills = require("SkillsService")
local Inventory = require("InventoryService")
local Crafting = require("CraftingService")

local IronBarRecipe = "recipe_iron_bar"
local SwordRecipe = "recipe_sword_upgraded"
local IronOre = "item_iron_ore"
local IronBar = "item_iron_bar"
local UpgradedSword = "weapon_sword_upgraded"

local passed = 0
local function test(name, run)
	local ok, message = pcall(run)
	assert(ok, name .. ": " .. tostring(message))
	passed += 1
	print("PASS " .. name)
end
local function equal(actual, expected)
	assert(actual == expected, ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
end

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

local function curve()
	local thresholds = {}
	for level = 1, SkillDefinitions.LevelCap do
		thresholds[level] = (level - 1) * 100
	end
	return { MaximumXP = 6000, Thresholds = thresholds }
end

local function fixture(nextInstanceIds, smithingModifiers)
	local records = {
		[7] = {
			Gold = 25,
			SkillXP = {
				[SkillIds.Melee] = 0,
				[SkillIds.Defense] = 0,
				[SkillIds.Mining] = 0,
				[SkillIds.Smithing] = 500,
			},
			Inventory = {
				Stacks = { [IronOre] = 10 },
				Items = {},
			},
			Equipment = {},
			Plot = { Stations = {} },
			ProgressionFlags = { flag_intro_complete = true },
		},
	}
	local playerData = { Calls = 0, FailReason = nil }
	function playerData.GetSnapshot(userId)
		return if records[userId] then copy(records[userId]) else nil
	end
	function playerData.Update(userId, change)
		playerData.Calls += 1
		if playerData.FailReason then
			return false, playerData.FailReason
		end
		local candidate = copy(records[userId])
		if not candidate then
			return false, "NotReady"
		end
		local ok = pcall(change, candidate)
		if not ok then
			return false, "InvalidMutation"
		end
		records[userId] = candidate
		return true, nil
	end
	local nextIndex = 0
	local runtime = {
		NewInstanceId = function()
			nextIndex += 1
			return (nextInstanceIds and nextInstanceIds[nextIndex]) or ("sword_" .. nextIndex)
		end,
	}
	local inventory = Inventory.New(playerData, runtime)
	local skills = Skills.New(playerData, { Curves = { curve_standard = curve() } })
	local service = Crafting.New(playerData, inventory, skills, smithingModifiers)
	return {
		Records = records,
		PlayerData = playerData,
		Inventory = inventory,
		Skills = skills,
		Service = service,
	}
end

test("Smithing recipes are stable, data-driven, and canonical Ore -> Bar -> Sword", function()
	local valid = CraftingDefinitions.Validate(CraftingDefinitions.ById)
	equal(valid, true)
	equal(RecipeIds.ById[RecipeIds.IronBar], true)
	equal(RecipeIds.ById[RecipeIds.SwordUpgraded], true)

	local barRecipe = CraftingDefinitions.ById[IronBarRecipe]
	equal(barRecipe.Id, IronBarRecipe)
	equal(barRecipe.SkillId, SkillIds.Smithing)
	equal(#barRecipe.Inputs, 1)
	equal(barRecipe.Inputs[1].ItemDefinitionId, IronOre)
	equal(barRecipe.OutputItemId, IronBar)
	equal(ItemDefinitions.ById[barRecipe.OutputItemId].Kind, "Stackable")

	local swordRecipe = CraftingDefinitions.ById[SwordRecipe]
	equal(swordRecipe.Id, SwordRecipe)
	equal(swordRecipe.SkillId, SkillIds.Smithing)
	equal(#swordRecipe.Inputs, 1)
	equal(swordRecipe.Inputs[1].ItemDefinitionId, IronBar)
	equal(swordRecipe.OutputItemId, UpgradedSword)
	equal(ItemDefinitions.ById[swordRecipe.OutputItemId].Kind, "Discrete")
	equal(swordRecipe.OutputAmount, 1)
end)

test("crafting Iron Ore into Iron Bar consumes inputs, adds output, and awards Smithing XP", function()
	local f = fixture()
	local recipe = CraftingDefinitions.ById[IronBarRecipe]
	local before = copy(f.Records[7])
	local result = assert(f.Service.Craft(7, IronBarRecipe))
	equal(result.RecipeId, IronBarRecipe)
	equal(result.OutputItemId, IronBar)
	equal(result.OutputAmount, 1)
	equal(result.OutputInstanceId, nil)
	equal(result.SmithingXP, recipe.SmithingXP)
	equal(f.Records[7].Inventory.Stacks[IronOre], before.Inventory.Stacks[IronOre] - recipe.Inputs[1].Amount)
	equal(f.Records[7].Inventory.Stacks[IronBar], 1)
	equal(f.Records[7].SkillXP[SkillIds.Smithing], before.SkillXP[SkillIds.Smithing] + recipe.SmithingXP)
	equal(result.SmithingState.XP, f.Records[7].SkillXP[SkillIds.Smithing])
	equal(f.Records[7].Gold, before.Gold)
	equal(f.Records[7].ProgressionFlags.flag_intro_complete, true)
end)

test("crafting Iron Bar into an upgraded Iron Sword uses a server-generated discrete instance", function()
	local f = fixture({ "generated_sword" })
	f.Records[7].Inventory.Stacks[IronBar] = 3
	local before = copy(f.Records[7])
	local result = assert(f.Service.Craft(7, SwordRecipe))
	equal(result.OutputItemId, UpgradedSword)
	equal(result.OutputInstanceId, "generated_sword")
	equal(f.Records[7].Inventory.Stacks[IronBar], nil)
	equal(f.Records[7].Inventory.Items.generated_sword.DefinitionId, UpgradedSword)
	equal(f.Records[7].SkillXP[SkillIds.Smithing], before.SkillXP[SkillIds.Smithing] + CraftingDefinitions.ById[SwordRecipe].SmithingXP)
	-- The crafted sword is a real Inventory-owned item, reachable through Inventory's own read API.
	local owned = assert(f.Inventory.GetDiscreteItem(7, result.OutputInstanceId :: string))
	equal(owned.DefinitionId, UpgradedSword)
end)

test("crafting rejects invalid recipe IDs, insufficient Smithing level, and insufficient materials", function()
	local f = fixture()
	local invalid, invalidReason = f.Service.Craft(7, "recipe_unknown")
	equal(invalid, nil)
	equal(invalidReason, "InvalidRecipeId")
	equal(f.PlayerData.Calls, 0)

	f.Records[7].SkillXP[SkillIds.Smithing] = 0
	local lowLevel, lowLevelReason = f.Service.Craft(7, SwordRecipe)
	equal(lowLevel, nil)
	equal(lowLevelReason, "InsufficientSmithingLevel")
	equal(f.Records[7].Inventory.Stacks[IronOre], 10)
	equal(next(f.Records[7].Inventory.Items), nil)
	f.Records[7].SkillXP[SkillIds.Smithing] = 500

	f.Records[7].Inventory.Stacks[IronOre] = 1
	local short, shortReason = f.Service.Craft(7, IronBarRecipe)
	equal(short, nil)
	equal(shortReason, "InsufficientItems")
	equal(f.Records[7].Inventory.Stacks[IronOre], 1)
	equal(f.Records[7].Inventory.Stacks[IronBar], nil)
end)

test("discrete output instance IDs are always server-generated and duplicate creation is rejected", function()
	local f = fixture({ "generated_sword" })
	f.Records[7].Inventory.Stacks[IronBar] = 6
	f.Records[7].Inventory.Items.generated_sword = { DefinitionId = UpgradedSword }
	local collision, collisionReason = f.Service.Craft(7, SwordRecipe)
	equal(collision, nil)
	equal(collisionReason, "InstanceIdCollision")
	equal(f.Records[7].Inventory.Stacks[IronBar], 6)
	equal(f.Records[7].SkillXP[SkillIds.Smithing], 500)
end)

test("material, output, and XP-cap failures roll back the combined crafting transaction", function()
	local f = fixture()
	f.Records[7].Inventory.Stacks[IronBar] = Inventory.MaximumStack
	local overflow, overflowReason = f.Service.Craft(7, IronBarRecipe)
	equal(overflow, nil)
	equal(overflowReason, "AmountOutOfBounds")
	equal(f.Records[7].Inventory.Stacks[IronOre], 10)
	equal(f.Records[7].Inventory.Stacks[IronBar], Inventory.MaximumStack)
	equal(f.Records[7].SkillXP[SkillIds.Smithing], 500)

	f.Records[7].Inventory.Stacks[IronBar] = nil
	f.Records[7].SkillXP[SkillIds.Smithing] = 6000
	local capped, cappedReason = f.Service.Craft(7, IronBarRecipe)
	equal(capped, nil)
	equal(cappedReason, "XPOutOfBounds")
	equal(f.Records[7].Inventory.Stacks[IronOre], 10)
	equal(f.Records[7].Inventory.Stacks[IronBar], nil)
	equal(f.Records[7].SkillXP[SkillIds.Smithing], 6000)
end)

test("Crafting has no instance-ID generator of its own and requires Inventory's discrete-item helper", function()
	local f = fixture()
	local ok = pcall(function()
		Crafting.New(f.PlayerData, {
			AddStackToData = f.Inventory.AddStackToData,
			RemoveStackFromData = f.Inventory.RemoveStackFromData,
		}, f.Skills)
	end)
	equal(ok, false)
end)

test("buying recipe inputs from the shop and reselling crafted outputs cannot guarantee Gold profit", function()
	local shop = ShopCatalog.ById.shop_hub
	local barRecipe = CraftingDefinitions.ById[IronBarRecipe]
	local swordRecipe = CraftingDefinitions.ById[SwordRecipe]

	local oreBuyPrice = shop.Entries[IronOre].BuyPrice
	local barSellPrice = shop.Entries[IronBar].SellPrice
	assert(oreBuyPrice * barRecipe.Inputs[1].Amount * barRecipe.OutputAmount >= barSellPrice)

	local swordSellPrice = shop.Entries[UpgradedSword].SellPrice
	local oreCostPerSword = oreBuyPrice * barRecipe.Inputs[1].Amount * swordRecipe.Inputs[1].Amount
	assert(oreCostPerSword > swordSellPrice)
end)

-- ===== Smithing Mastery: MaterialEfficiencyBonus (ProcessingSpeedBonus is intentionally inert) =====
-- The fixture injects a provider standing in for Mastery.GetModifiers(...Smithing) read from the same
-- transaction. Effective cost per input = max(1, ceil(amount * (1 - eff))) -- a SAFE rounding that never
-- yields a free/negative craft and never grants more discount than earned. IMPORTANT: at the real
-- configured Forgemaster values (+0.02 per node, +0.10 for a full branch) this rounds to NO change on
-- the slice's 2- and 3-unit single recipes; a whole unit is only saved once eff >= 1/amount. Meaningful
-- realization is therefore blocked on the already-required batch-crafting work. The two synthetic tests
-- below use above-configured efficiencies purely to prove the mechanism is wired for larger batches.

test("no Smithing selections consume the recipe's full material cost", function()
	local f = fixture(nil, function() return {} end)
	assert(f.Service.Craft(7, IronBarRecipe))
	equal(f.Records[7].Inventory.Stacks[IronOre], 8) -- 10 - 2
end)

test("the configured Forgemaster values cannot yet reduce a single 2- or 3-unit craft (blocked on batch crafting)", function()
	-- Real Mastery values: +0.02 per node up to +0.10 for a full Forgemaster branch. On the 2-ore Bar
	-- recipe and 3-bar Sword recipe these round to no change (eff would need to reach 1/amount).
	for _, eff in { 0.02, 0.10 } do
		local bar = fixture(nil, function() return { MaterialEfficiencyBonus = eff } end)
		assert(bar.Service.Craft(7, IronBarRecipe))
		equal(bar.Records[7].Inventory.Stacks[IronOre], 8) -- full 2 consumed, no discount realized

		local sword = fixture({ "generated_sword" }, function() return { MaterialEfficiencyBonus = eff } end)
		sword.Records[7].Inventory.Stacks[IronBar] = 3
		assert(sword.Service.Craft(7, SwordRecipe))
		equal(sword.Records[7].Inventory.Stacks[IronBar], nil) -- full 3 consumed
	end
end)

test("the efficiency formula does reduce consumption once the saving crosses a whole unit (forward-compatible)", function()
	-- Above-configured efficiency, standing in for a future batch that multiplies the effective quantity.
	local f = fixture(nil, function() return { MaterialEfficiencyBonus = 0.5 } end)
	assert(f.Service.Craft(7, IronBarRecipe))
	equal(f.Records[7].Inventory.Stacks[IronOre], 9) -- max(1, ceil(2 * 0.5)) == 1 consumed
	equal(f.Records[7].Inventory.Stacks[IronBar], 1) -- output still produced
end)

test("the efficiency formula reduces a multi-unit recipe's consumption once the saving crosses a whole unit", function()
	local f = fixture({ "generated_sword" }, function() return { MaterialEfficiencyBonus = 0.5 } end)
	f.Records[7].Inventory.Stacks[IronBar] = 3
	assert(f.Service.Craft(7, SwordRecipe))
	equal(f.Records[7].Inventory.Stacks[IronBar], 1) -- max(1, ceil(3 * 0.5)) == 2 consumed, 1 left
end)

test("material efficiency is clamped so a craft always costs at least one of each input", function()
	local f = fixture(nil, function() return { MaterialEfficiencyBonus = 5 } end)
	assert(f.Service.Craft(7, IronBarRecipe))
	equal(f.Records[7].Inventory.Stacks[IronOre], 9) -- clamped: still consumes 1, never 0/free
	equal(f.Records[7].Inventory.Stacks[IronBar], 1)
end)

test("ProcessingSpeedBonus does not change authoritative crafting (no action-time exists to shorten)", function()
	local base = fixture(nil, function() return {} end)
	assert(base.Service.Craft(7, IronBarRecipe))
	local withSpeed = fixture(nil, function() return { ProcessingSpeedBonus = 0.9 } end)
	assert(withSpeed.Service.Craft(7, IronBarRecipe))
	-- Identical consumption and output: ProcessingSpeedBonus is read but truthfully has nothing to act on.
	equal(withSpeed.Records[7].Inventory.Stacks[IronOre], base.Records[7].Inventory.Stacks[IronOre])
	equal(withSpeed.Records[7].Inventory.Stacks[IronBar], base.Records[7].Inventory.Stacks[IronBar])
end)

test("a respec clearing Smithing nodes restores full material cost immediately", function()
	local efficiency = 0.5
	local f = fixture(nil, function() return { MaterialEfficiencyBonus = efficiency } end)
	assert(f.Service.Craft(7, IronBarRecipe))
	equal(f.Records[7].Inventory.Stacks[IronOre], 9) -- reduced
	efficiency = 0
	assert(f.Service.Craft(7, IronBarRecipe))
	equal(f.Records[7].Inventory.Stacks[IronOre], 7) -- next craft consumes the full 2 again (9 - 2)
end)

test("a spoofed non-numeric MaterialEfficiencyBonus grants no discount", function()
	local f = fixture(nil, function() return { MaterialEfficiencyBonus = "0.9", Junk = 1 } end)
	assert(f.Service.Craft(7, IronBarRecipe))
	equal(f.Records[7].Inventory.Stacks[IronOre], 8) -- string ignored -> full 2 consumed
end)

test("a non-function Smithing modifier provider is rejected", function()
	local ok = pcall(function()
		return fixture(nil, 5)
	end)
	equal(ok, false)
end)

print(("%d Crafting checks passed"):format(passed))
