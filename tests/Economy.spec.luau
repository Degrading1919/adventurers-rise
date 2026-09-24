--!strict

local Economy = require("EconomyService")
local ItemDefinitions = require("ItemDefinitions")
local ShopCatalog = require("ShopCatalog")

local Shop = "shop_hub"
local Ore = "item_iron_ore"
local Bar = "item_iron_bar"
local StarterSword = "weapon_sword_starter"
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

local function fixture(ids)
	local records = {
		[7] = {
			Gold = 1000,
			SkillXP = { skill_melee = 12 },
			Inventory = { Stacks = {}, Items = {} },
			Equipment = {},
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
		change(candidate)
		records[userId] = candidate
		return true, nil
	end
	local nextId = 0
	local service = Economy.New(playerData, {
		NewInstanceId = function()
			nextId += 1
			return (ids and ids[nextId]) or ("shop_instance_" .. nextId)
		end,
	})
	return { Records = records, PlayerData = playerData, Service = service }
end

test("catalog uses stable definitions and direct resale cannot produce Gold", function()
	local catalog = ShopCatalog.ById[Shop]
	equal(catalog.Id, Shop)
	equal(catalog.Entries[Ore].ItemDefinitionId, Ore)
	equal(catalog.Entries[Ore].BuyPrice, 10)
	equal(catalog.Entries[Ore].SellPrice, 4)
	equal(catalog.Entries[Bar].BuyPrice, nil)
	equal(catalog.Entries[Bar].SellPrice, 12)
	equal(catalog.Entries[UpgradedSword].BuyPrice, 500)
	equal(catalog.Entries[UpgradedSword].SellPrice, 50)
	assert(catalog.Entries[Ore].SellPrice < catalog.Entries[Ore].BuyPrice)
	assert(catalog.Entries[UpgradedSword].SellPrice < catalog.Entries[UpgradedSword].BuyPrice)
	equal(ItemDefinitions.ById[StarterSword].Kind, "Discrete")
end)

test("Gold reads and mutations preserve unrelated PlayerData state", function()
	local f = fixture()
	equal(assert(f.Service.GetGold(7)), 1000)
	equal(assert(f.Service.CreditGold(7, 25)), 1025)
	equal(assert(f.Service.DebitGold(7, 40)), 985)
	equal(f.Records[7].Gold, 985)
	equal(f.Records[7].SkillXP.skill_melee, 12)
	equal(f.Records[7].ProgressionFlags.flag_intro_complete, true)
	equal(next(f.Records[7].Inventory.Stacks), nil)
end)

test("Gold rejects invalid mutations, insufficient funds, and overflow", function()
	local f = fixture()
	for _, attempt in {
		function() return f.Service.CreditGold(0, 1) end,
		function() return f.Service.CreditGold(7, 0) end,
		function() return f.Service.CreditGold(7, -1) end,
		function() return f.Service.CreditGold(7, 1.5) end,
		function() return f.Service.CreditGold(7, math.huge) end,
		function() return f.Service.CreditGold(7, 0 / 0) end,
		function() return f.Service.DebitGold(7, 1001) end,
	} do
		local value, reason = attempt()
		equal(value, nil)
		assert(reason == "InvalidUserId" or reason == "InvalidAmount" or reason == "InsufficientGold")
	end
	f.Records[7].Gold = Economy.MaximumGold
	local overflow, overflowReason = f.Service.CreditGold(7, 1)
	equal(overflow, nil)
	equal(overflowReason, "GoldOutOfBounds")
	equal(f.Records[7].Gold, Economy.MaximumGold)
end)

test("stackable purchases and sales commit Gold and inventory together", function()
	local f = fixture()
	local purchase = assert(f.Service.PurchaseStack(7, Shop, Ore, 2))
	equal(purchase.Gold, 980)
	equal(f.Records[7].Gold, 980)
	equal(f.Records[7].Inventory.Stacks[Ore], 2)
	local sale = assert(f.Service.SellStack(7, Shop, Ore, 1))
	equal(sale.Gold, 984)
	equal(f.Records[7].Gold, 984)
	equal(f.Records[7].Inventory.Stacks[Ore], 1)
	local barPurchase, barPurchaseReason = f.Service.PurchaseStack(7, Shop, Bar, 1)
	equal(barPurchase, nil)
	equal(barPurchaseReason, "ItemNotBuyable")
end)

test("discrete purchases and sales use owned instances", function()
	local f = fixture({ "shop_sword" })
	local purchase = assert(f.Service.PurchaseDiscrete(7, Shop, UpgradedSword))
	equal(purchase.InstanceId, "shop_sword")
	equal(purchase.Gold, 500)
	equal(f.Records[7].Inventory.Items.shop_sword.DefinitionId, UpgradedSword)
	local sale = assert(f.Service.SellDiscrete(7, Shop, "shop_sword"))
	equal(sale.Gold, 550)
	equal(f.Records[7].Inventory.Items.shop_sword, nil)
end)

test("Merchant Smith sale-value bonus raises shop payouts, read from the same transactional data", function()
	local records = {
		[7] = {
			Gold = 1000,
			SkillXP = {},
			Inventory = { Stacks = { [Ore] = 2 }, Items = { blade = { DefinitionId = UpgradedSword } } },
			Equipment = {},
			ProgressionFlags = {},
		},
	}
	local playerData = {}
	function playerData.GetSnapshot(userId)
		return if records[userId] then copy(records[userId]) else nil
	end
	function playerData.Update(userId, change)
		local candidate = copy(records[userId])
		if not candidate then
			return false, "NotReady"
		end
		change(candidate)
		records[userId] = candidate
		return true, nil
	end
	-- The Merchant Smith bonus is scoped (in Composition) to goods the player forged, so the provider is
	-- item-aware: it receives the definition id of the exact good being sold. Here it grants +25% only to
	-- the forged sword and nothing to raw Ore, proving both that Economy routes the correct definition id
	-- through each sell path (SellStack -> the stack id; SellDiscrete -> the item's definition id) and that
	-- an unforged good keeps its base payout.
	local service = Economy.New(playerData, {
		NewInstanceId = function() return "x" end,
		SaleValueBonusFromData = function(_data, definitionId)
			return if definitionId == UpgradedSword then 0.25 else 0
		end,
	})
	-- Raw Ore is not a forged good: base sell 4, no bonus -> 1004.
	local oreSale = assert(service.SellStack(7, Shop, Ore, 1))
	equal(oreSale.Gold, 1004)
	-- The forged Upgraded Sword qualifies: base 50 -> 50 + floor(50*0.25 + 0.5) = 63.
	local swordSale = assert(service.SellDiscrete(7, Shop, "blade"))
	equal(swordSale.Gold, 1004 + 63)
end)

test("equipped discrete items cannot be sold", function()
	local f = fixture()
	f.Records[7].Inventory.Items.equipped = { DefinitionId = UpgradedSword }
	f.Records[7].Equipment.slot_weapon = "equipped"
	local sale, reason = f.Service.SellDiscrete(7, Shop, "equipped")
	equal(sale, nil)
	equal(reason, "ItemEquipped")
	equal(f.Records[7].Gold, 1000)
	equal(f.Records[7].Inventory.Items.equipped.DefinitionId, UpgradedSword)
end)

test("invalid catalog, item, and ownership requests do not mutate state", function()
	local f = fixture()
	for _, attempt in {
		function() return f.Service.PurchaseStack(7, "shop_unknown", Ore, 1) end,
		function() return f.Service.PurchaseStack(7, Shop, "item_unknown", 1) end,
		function() return f.Service.PurchaseStack(7, Shop, StarterSword, 1) end,
		function() return f.Service.PurchaseDiscrete(7, Shop, Ore) end,
		function() return f.Service.SellDiscrete(7, Shop, "not_owned") end,
		function() return f.Service.SellStack(7, Shop, Ore, 1) end,
	} do
		local value, reason = attempt()
		equal(value, nil)
		assert(reason == "InvalidCatalogId" or reason == "InvalidItemDefinitionId" or reason == "ItemNotListed" or reason == "ItemNotOwned" or reason == "InsufficientItems")
	end
	f.Records[7].Inventory.Items.corrupt = { DefinitionId = Ore }
	local corrupt, corruptReason = f.Service.SellDiscrete(7, Shop, "corrupt")
	equal(corrupt, nil)
	equal(corruptReason, "InvalidInventory")
	equal(f.Records[7].Gold, 1000)
	equal(next(f.Records[7].Inventory.Stacks), nil)
	equal(f.Records[7].Inventory.Items.corrupt.DefinitionId, Ore)
end)

test("failed transactions leave Gold and inventory unchanged", function()
	local f = fixture({ "collision" })
	f.Records[7].Inventory.Stacks[Ore] = Economy.MaximumStack
	local full, fullReason = f.Service.PurchaseStack(7, Shop, Ore, 1)
	equal(full, nil)
	equal(fullReason, "AmountOutOfBounds")
	equal(f.Records[7].Gold, 1000)
	equal(f.Records[7].Inventory.Stacks[Ore], Economy.MaximumStack)
	f.Records[7].Gold = Economy.MaximumGold
	f.Records[7].Inventory.Stacks[Ore] = 1
	local overflow, overflowReason = f.Service.SellStack(7, Shop, Ore, 1)
	equal(overflow, nil)
	equal(overflowReason, "GoldOutOfBounds")
	equal(f.Records[7].Gold, Economy.MaximumGold)
	equal(f.Records[7].Inventory.Stacks[Ore], 1)
	f.Records[7].Gold = 1000
	f.Records[7].Inventory.Items.collision = { DefinitionId = UpgradedSword }
	local collision, collisionReason = f.Service.PurchaseDiscrete(7, Shop, UpgradedSword)
	equal(collision, nil)
	equal(collisionReason, "InstanceIdCollision")
	equal(f.Records[7].Gold, 1000)
	equal(f.Records[7].Inventory.Items.collision.DefinitionId, UpgradedSword)
	f.PlayerData.FailReason = "NotReady"
	local unavailable, unavailableReason = f.Service.PurchaseStack(7, Shop, Ore, 1)
	equal(unavailable, nil)
	equal(unavailableReason, "NotReady")
	equal(f.Records[7].Gold, 1000)
	equal(f.Records[7].Inventory.Stacks[Ore], 1)
end)

print(("%d Economy checks passed"):format(passed))
