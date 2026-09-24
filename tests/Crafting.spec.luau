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

	-- Iron armour set: Bars -> Discrete armour, Smithing-gated, one instance per craft.
	for _, recipeId in { RecipeIds.IronHelm, RecipeIds.IronBody, RecipeIds.IronLegs } do
		equal(RecipeIds.ById[recipeId], true)
		local recipe = CraftingDefinitions.ById[recipeId]
		equal(recipe.Id, recipeId)
		equal(recipe.SkillId, SkillIds.Smithing)
		equal(recipe.Inputs[1].ItemDefinitionId, IronBar)
		local output = ItemDefinitions.ById[recipe.OutputItemId]
		equal(output.Kind, "Discrete")
		equal(recipe.OutputAmount, 1)
		assert(output.Armor ~= nil and output.Armor.DamageReduction > 0, "armour recipe output must carry a DamageReduction")
	end
end)

test("the steel tier chains a two-input Steel Bar (Iron Bar + Coal) into steel gear", function()
	-- Steel Bar: the only recipe with two distinct stackable inputs -> a stackable metal.
	local steelBar = CraftingDefinitions.ById[RecipeIds.SteelBar]
	equal(steelBar.OutputItemId, "item_steel_bar")
	equal(ItemDefinitions.ById.item_steel_bar.Kind, "Stackable")
	equal(#steelBar.Inputs, 2)
	local inputIds = { [steelBar.Inputs[1].ItemDefinitionId] = true, [steelBar.Inputs[2].ItemDefinitionId] = true }
	assert(inputIds[IronBar] and inputIds["item_coal"], "Steel Bar must be smelted from an Iron Bar and Coal")

	-- Steel sword sits above the iron sword on the weapon ladder.
	local steelSword = CraftingDefinitions.ById[RecipeIds.SwordSteel]
	equal(steelSword.OutputItemId, "weapon_sword_steel")
	assert(steelSword.RequiredSmithingLevel > CraftingDefinitions.ById[SwordRecipe].RequiredSmithingLevel, "steel sword gated above iron sword")
	assert(ItemDefinitions.ById.weapon_sword_steel.Melee.Damage > ItemDefinitions.ById[UpgradedSword].Melee.Damage, "steel sword hits harder")

	-- Steel armour set: Steel Bars -> Discrete armour, each piece beats its iron counterpart.
	for _, recipeId in { RecipeIds.SteelHelm, RecipeIds.SteelBody, RecipeIds.SteelLegs } do
		equal(RecipeIds.ById[recipeId], true)
		local recipe = CraftingDefinitions.ById[recipeId]
		equal(recipe.Inputs[1].ItemDefinitionId, "item_steel_bar")
		local output = ItemDefinitions.ById[recipe.OutputItemId]
		equal(output.Kind, "Discrete")
		equal(recipe.OutputAmount, 1)
		assert(output.Armor ~= nil and output.Armor.DamageReduction > 0, "steel armour must carry a DamageReduction")
	end
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

-- ===== Smithing Mastery: Forgemaster MaterialEfficiencyBonus (equipment crafts only) =====
-- Forgemaster is "material efficiency when forging EQUIPMENT" (docs/MASTERY_TREES.md), so the bonus
-- applies only to recipes whose output is an equippable item, detected from the output item's Equipment
-- metadata -- never a hard-coded recipe ID. Iron Ore -> Iron Bar smelting is excluded; the upgraded
-- sword qualifies. Effective cost per input = max(1, ceil(amount * (1 - eff))) -- a SAFE rounding that
-- never yields a free/negative craft. At the real configured values (+0.02 per node, +0.10 for a full
-- branch) even the eligible single sword craft rounds to NO change (a whole unit is saved only once
-- eff >= 1/amount); meaningful realization is blocked on the already-required batch-crafting work. The
-- above-configured (synthetic) values below only prove the equipment-only mechanism is wired.

test("no Smithing selections consume the recipe's full material cost", function()
	local f = fixture(nil, function() return {} end)
	assert(f.Service.Craft(7, IronBarRecipe))
	equal(f.Records[7].Inventory.Stacks[IronOre], 8) -- 10 - 2
end)

test("Forgemaster never reduces Iron Bar smelting inputs (non-equipment output), even with a large modifier", function()
	-- A synthetic, well-above-configured modifier must still be ignored for a smelting recipe.
	local f = fixture(nil, function() return { MaterialEfficiencyBonus = 0.9 } end)
	assert(f.Service.Craft(7, IronBarRecipe))
	equal(f.Records[7].Inventory.Stacks[IronOre], 8) -- full 2 consumed: Iron Bar is not equipment
	equal(f.Records[7].Inventory.Stacks[IronBar], 1)
end)

test("the upgraded sword is the eligible Forgemaster recipe: an above-configured modifier reduces its inputs", function()
	-- Proves the equipment-only efficiency mechanism is wired, standing in for a future batch craft.
	local f = fixture({ "generated_sword" }, function() return { MaterialEfficiencyBonus = 0.5 } end)
	f.Records[7].Inventory.Stacks[IronBar] = 3
	assert(f.Service.Craft(7, SwordRecipe))
	equal(f.Records[7].Inventory.Stacks[IronBar], 1) -- max(1, ceil(3 * 0.5)) == 2 consumed, 1 left
end)

test("configured Forgemaster values still round to no change on the single sword craft (blocked on batch crafting)", function()
	for _, eff in { 0.02, 0.10 } do
		local f = fixture({ "generated_sword" }, function() return { MaterialEfficiencyBonus = eff } end)
		f.Records[7].Inventory.Stacks[IronBar] = 3
		assert(f.Service.Craft(7, SwordRecipe))
		equal(f.Records[7].Inventory.Stacks[IronBar], nil) -- full 3 consumed, no whole-unit saving yet
	end
end)

test("equipment material efficiency is clamped so a craft always costs at least one of each input", function()
	local f = fixture({ "generated_sword" }, function() return { MaterialEfficiencyBonus = 5 } end)
	f.Records[7].Inventory.Stacks[IronBar] = 3
	assert(f.Service.Craft(7, SwordRecipe))
	equal(f.Records[7].Inventory.Stacks[IronBar], 2) -- clamped: ceil(3 * 0.1) == 1 consumed, never 0/free
end)

test("Smelter (ProcessingEfficiencyBonus) reduces ore used for SMELTING, but not for an equipment craft", function()
	-- Smelting recipe (Iron Ore -> Iron Bar): Smelter cuts the ore input. 2-ore recipe at 0.5 ->
	-- ceil(2 * (1 - 0.5)) = 1 ore consumed (never 0/free).
	local smelt = fixture(nil, function() return { ProcessingEfficiencyBonus = 0.5 } end)
	smelt.Records[7].Inventory.Stacks[IronOre] = 4
	assert(smelt.Service.Craft(7, IronBarRecipe))
	equal(smelt.Records[7].Inventory.Stacks[IronOre], 3)
	-- ProcessingEfficiencyBonus does NOT discount an EQUIPMENT craft (that is Forgemaster's role): the
	-- upgraded sword still consumes its full 3 bars.
	local equip = fixture({ "sword1" }, function() return { ProcessingEfficiencyBonus = 0.5 } end)
	equip.Records[7].Inventory.Stacks[IronBar] = 3
	assert(equip.Service.Craft(7, SwordRecipe))
	equal(equip.Records[7].Inventory.Stacks[IronBar], nil) -- full 3 bars consumed (empty stack is removed, not 0)
end)

test("a respec clearing Forgemaster nodes restores full material cost immediately (equipment craft)", function()
	local efficiency = 0.5
	local f = fixture({ "s1", "s2" }, function() return { MaterialEfficiencyBonus = efficiency } end)
	f.Records[7].Inventory.Stacks[IronBar] = 6
	assert(f.Service.Craft(7, SwordRecipe))
	equal(f.Records[7].Inventory.Stacks[IronBar], 4) -- reduced: ceil(3 * 0.5) == 2 consumed (6 - 2)
	efficiency = 0
	assert(f.Service.Craft(7, SwordRecipe))
	equal(f.Records[7].Inventory.Stacks[IronBar], 1) -- next craft consumes the full 3 again (4 - 3)
end)

test("a spoofed non-numeric MaterialEfficiencyBonus grants no discount on an equipment craft", function()
	local f = fixture({ "generated_sword" }, function() return { MaterialEfficiencyBonus = "0.9", Junk = 1 } end)
	f.Records[7].Inventory.Stacks[IronBar] = 3
	assert(f.Service.Craft(7, SwordRecipe))
	equal(f.Records[7].Inventory.Stacks[IronBar], nil) -- string ignored -> full 3 consumed
end)

test("a non-function Smithing modifier provider is rejected", function()
	local ok = pcall(function()
		return fixture(nil, 5)
	end)
	equal(ok, false)
end)

-- ===== Batch crafting (Craft 1 / N / Max, server-authoritative) =====

test("Craft 1 (explicit and default) preserves the existing single-craft behavior", function()
	local base = fixture()
	assert(base.Service.Craft(7, IronBarRecipe))
	local explicit = fixture()
	local result = assert(explicit.Service.Craft(7, IronBarRecipe, { Quantity = 1 }))
	equal(result.Quantity, 1)
	equal(result.SmithingXP, CraftingDefinitions.ById[IronBarRecipe].SmithingXP)
	-- Same authoritative consumption/output as the default single craft.
	equal(explicit.Records[7].Inventory.Stacks[IronOre], base.Records[7].Inventory.Stacks[IronOre])
	equal(explicit.Records[7].Inventory.Stacks[IronBar], base.Records[7].Inventory.Stacks[IronBar])
end)

test("Craft 5 consumes the aggregate materials and grants the aggregate output and XP", function()
	local f = fixture()
	f.Records[7].Inventory.Stacks[IronOre] = 12 -- leaves a non-zero remainder after consuming 10
	local recipe = CraftingDefinitions.ById[IronBarRecipe]
	local before = copy(f.Records[7])
	local result = assert(f.Service.Craft(7, IronBarRecipe, { Quantity = 5 }))
	equal(result.Quantity, 5)
	equal(f.Records[7].Inventory.Stacks[IronOre], before.Inventory.Stacks[IronOre] - recipe.Inputs[1].Amount * 5) -- 12 - 10 = 2
	equal(result.InputsConsumed[IronOre], recipe.Inputs[1].Amount * 5) -- 10 ore consumed
	equal(f.Records[7].Inventory.Stacks[IronBar], recipe.OutputAmount * 5) -- 5 bars
	equal(result.SmithingXP, recipe.SmithingXP * 5) -- 30
	equal(f.Records[7].SkillXP[SkillIds.Smithing], before.SkillXP[SkillIds.Smithing] + recipe.SmithingXP * 5)
end)

test("Craft Max is computed server-side from current authoritative materials", function()
	local f = fixture()
	f.Records[7].Inventory.Stacks[IronOre] = 11 -- 2 ore/bar -> max 5 (one ore left over)
	local result = assert(f.Service.Craft(7, IronBarRecipe, { Max = true }))
	equal(result.Quantity, 5)
	equal(f.Records[7].Inventory.Stacks[IronOre], 1) -- 11 - 10
	equal(f.Records[7].Inventory.Stacks[IronBar], 5)
end)

test("a client cannot request an invalid, negative, fractional, or unbounded quantity", function()
	for _, bad in { 0, -1, 1.5, math.huge, 0 / 0, 1000000000, "5", true } do
		local f = fixture()
		local result, reason = f.Service.Craft(7, IronBarRecipe, { Quantity = bad })
		equal(result, nil)
		equal(reason, "InvalidQuantity")
		equal(f.Records[7].Inventory.Stacks[IronOre], 10) -- nothing consumed
	end
	-- A non-table request is rejected too.
	equal(select(2, fixture().Service.Craft(7, IronBarRecipe, 5 :: any)), "InvalidCraftRequest")
end)

test("insufficient materials fail the whole batch safely (no partial consumption or output)", function()
	local f = fixture()
	f.Records[7].Inventory.Stacks[IronOre] = 3 -- only enough for one bar (needs 10 for five)
	local result, reason = f.Service.Craft(7, IronBarRecipe, { Quantity = 5 })
	equal(result, nil)
	equal(reason, "InsufficientItems")
	equal(f.Records[7].Inventory.Stacks[IronOre], 3) -- unchanged
	equal(f.Records[7].Inventory.Stacks[IronBar], nil) -- no partial output
end)

test("an equipment batch creates a distinct instance ID per craft through Inventory", function()
	local f = fixture()
	f.Records[7].Inventory.Stacks[IronBar] = 15 -- 3 bars/sword -> 5 swords
	local result = assert(f.Service.Craft(7, SwordRecipe, { Quantity = 5 }))
	equal(result.Quantity, 5)
	equal(#result.OutputInstanceIds, 5)
	equal(result.OutputInstanceId, result.OutputInstanceIds[1])
	local seen = {}
	for _, instanceId in result.OutputInstanceIds do
		assert(not seen[instanceId], "duplicate instance id: " .. tostring(instanceId))
		seen[instanceId] = true
		assert(f.Records[7].Inventory.Items[instanceId] ~= nil, "instance not owned in inventory")
	end
	equal(f.Records[7].Inventory.Stacks[IronBar], nil) -- all 15 consumed
end)

test("Forgemaster material efficiency reduces an equipment batch's cost but never Iron Bar smelting", function()
	-- Configured full Forgemaster branch (+10%). Sword batch of 20: ceil(3 * 20 * 0.9) = 54 bars (saves 6).
	local sword = fixture(nil, function() return { MaterialEfficiencyBonus = 0.10 } end)
	sword.Records[7].Inventory.Stacks[IronBar] = 60
	local swordResult = assert(sword.Service.Craft(7, SwordRecipe, { Quantity = 20 }))
	equal(swordResult.InputsConsumed[IronBar], 54)
	equal(sword.Records[7].Inventory.Stacks[IronBar], 6)
	-- Iron Bar smelting is NOT equipment, so the same modifier gives no discount: 2 * 20 = 40 ore.
	local bar = fixture(nil, function() return { MaterialEfficiencyBonus = 0.10 } end)
	bar.Records[7].Inventory.Stacks[IronOre] = 40
	local barResult = assert(bar.Service.Craft(7, IronBarRecipe, { Quantity = 20 }))
	equal(barResult.InputsConsumed[IronOre], 40)
end)

test("splitting an equivalent equipment quantity cannot beat the deterministic single-batch cost", function()
	-- base 3 bars, +10%: one batch of 10 costs ceil(3*10*0.9)=27; two batches of 5 cost ceil(13.5)*2=28;
	-- ten single crafts cost ceil(2.7)*10=30. The single batch is always the cheapest; splitting only
	-- ever costs the same or more, so there is no rounding exploit.
	local one = fixture(nil, function() return { MaterialEfficiencyBonus = 0.10 } end)
	one.Records[7].Inventory.Stacks[IronBar] = 100
	equal(assert(one.Service.Craft(7, SwordRecipe, { Quantity = 10 })).InputsConsumed[IronBar], 27)

	local split = fixture(nil, function() return { MaterialEfficiencyBonus = 0.10 } end)
	split.Records[7].Inventory.Stacks[IronBar] = 100
	assert(split.Service.Craft(7, SwordRecipe, { Quantity = 5 }))
	assert(split.Service.Craft(7, SwordRecipe, { Quantity = 5 }))
	local splitConsumed = 100 - split.Records[7].Inventory.Stacks[IronBar]
	equal(splitConsumed, 28)
	assert(27 <= splitConsumed, "one batch must never cost more than splitting")
end)

test("configured real Forgemaster values produce meaningful savings at appropriate batch sizes", function()
	-- +2% (single node) over a batch of 50 swords: ceil(3*50*0.98)=ceil(147)=147 bars, saving 3 vs 150.
	local f = fixture(nil, function() return { MaterialEfficiencyBonus = 0.02 } end)
	f.Records[7].Inventory.Stacks[IronBar] = 150
	local result = assert(f.Service.Craft(7, SwordRecipe, { Quantity = 50 }))
	equal(result.InputsConsumed[IronBar], 147)
	equal(f.Records[7].Inventory.Stacks[IronBar], 3)
	equal(#result.OutputInstanceIds, 50)
end)

test("Craft Max on an equipment recipe respects Forgemaster efficiency and the batch bound", function()
	-- +10% efficiency, 100 bars: max N with ceil(3*N*0.9) <= 100 -> floor(100/2.7)=37 (ceil(99.9)=100).
	local f = fixture(nil, function() return { MaterialEfficiencyBonus = 0.10 } end)
	f.Records[7].Inventory.Stacks[IronBar] = 100
	local result = assert(f.Service.Craft(7, SwordRecipe, { Max = true }))
	equal(result.Quantity, 37)
	equal(result.InputsConsumed[IronBar], 100) -- ceil(3*37*0.9) = ceil(99.9) = 100
end)

print(("%d Crafting checks passed"):format(passed))
