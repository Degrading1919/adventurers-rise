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

local function fixture(nextInstanceIds)
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
	local service = Crafting.New(playerData, inventory, skills)
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

print(("%d Crafting checks passed"):format(passed))
