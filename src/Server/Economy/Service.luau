--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local ItemDefinitions = require(Shared.ItemDefinitions)
local ShopCatalog = require(script.Parent.ShopCatalog)

export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type Runtime = {
	NewInstanceId: () -> string,
	-- Optional: the fractional shop SALE-value bonus for selling a SPECIFIC item, read from the same
	-- transactional data the sell mutates. Smithing "Merchant Smith" is scoped to personally forged goods
	-- (crafting outputs -- bars + forged equipment), so the provider returns 0 for raw/mined resources.
	-- Defaults to none when not injected.
	SaleValueBonusFromData: ((any, string) -> number)?,
}
export type StackTransaction = {
	Gold: number,
	DefinitionId: string,
	Amount: number,
}
export type DiscreteTransaction = {
	Gold: number,
	DefinitionId: string,
	InstanceId: string,
}

local Service = { MaximumGold = 9007199254740991, MaximumStack = 9007199254740991 }

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= Service.MaximumGold
end

local function validWhole(value: any, maximum: number): boolean
	return type(value) == "number" and value >= 0 and value <= maximum and value % 1 == 0
end

local function validPositiveWhole(value: any, maximum: number): boolean
	return validWhole(value, maximum) and value > 0
end

local function validInstanceId(instanceId: any): boolean
	return type(instanceId) == "string" and instanceId ~= ""
end

local function validCatalogId(catalogId: any): boolean
	return type(catalogId) == "string" and catalogId ~= ""
end

local function validDefinitionId(definitionId: any): boolean
	return type(definitionId) == "string" and definitionId ~= ""
end

local function totalPrice(price: number, amount: number): (number?, string?)
	if amount > math.floor(Service.MaximumGold / price) then
		return nil, "AmountOutOfBounds"
	end
	return price * amount, nil
end

local function validateCatalogs()
	for catalogId, catalog in ShopCatalog.ById do
		assert(validCatalogId(catalogId) and catalog.Id == catalogId, "Shop catalog IDs must be stable nonempty strings")
		for definitionId, entry in catalog.Entries do
			assert(validDefinitionId(definitionId) and entry.ItemDefinitionId == definitionId, "Shop catalog entry IDs must match their keys")
			assert(ItemDefinitions.ById[definitionId], "Shop catalog entries must reference item definitions")
			assert(entry.BuyPrice or entry.SellPrice, "Shop catalog entries require a buy or sell price")
			if entry.BuyPrice then
				assert(validPositiveWhole(entry.BuyPrice, Service.MaximumGold), "Shop buy prices must be positive whole Gold")
			end
			if entry.SellPrice then
				assert(validPositiveWhole(entry.SellPrice, Service.MaximumGold), "Shop sell prices must be positive whole Gold")
			end
			if entry.BuyPrice and entry.SellPrice then
				assert(entry.SellPrice < entry.BuyPrice, "Shop direct resale must not produce Gold")
			end
		end
	end
end

function Service.New(playerData: PlayerData, runtime: Runtime)
	assert(type(playerData) == "table", "Economy requires a PlayerData service")
	assert(type(runtime) == "table" and type(runtime.NewInstanceId) == "function", "Economy requires an instance ID generator")
	validateCatalogs()

	local service = {}

	-- Applies the player's shop sale-value bonus (Smithing Merchant Smith mastery) to a base sale price,
	-- read from the SAME transactional data the sell is mutating so it is always current. The bonus is a
	-- non-negative fraction; a missing/invalid provider yields the base price unchanged.
	local saleValueBonusFromData = runtime.SaleValueBonusFromData
	local function saleValueFor(data: any, definitionId: string, basePrice: number): number
		if type(saleValueBonusFromData) ~= "function" then
			return basePrice
		end
		local bonus = saleValueBonusFromData(data, definitionId)
		if type(bonus) ~= "number" or bonus ~= bonus or bonus <= 0 then
			return basePrice
		end
		return basePrice + math.floor(basePrice * bonus + 0.5)
	end

	local function catalogFor(catalogId: any): (ShopCatalog.Catalog?, string?)
		if not validCatalogId(catalogId) then
			return nil, "InvalidCatalogId"
		end
		local catalog = ShopCatalog.ById[catalogId]
		if not catalog then
			return nil, "InvalidCatalogId"
		end
		return catalog, nil
	end

	local function entryFor(catalog: ShopCatalog.Catalog, definitionId: any, direction: "Buy" | "Sell"): (ItemDefinitions.Definition?, number?, string?)
		if not validDefinitionId(definitionId) then
			return nil, nil, "InvalidItemDefinitionId"
		end
		local definition = ItemDefinitions.ById[definitionId]
		if not definition then
			return nil, nil, "InvalidItemDefinitionId"
		end
		local entry = catalog.Entries[definitionId]
		if not entry then
			return nil, nil, "ItemNotListed"
		end
		local price = if direction == "Buy" then entry.BuyPrice else entry.SellPrice
		if price == nil then
			return nil, nil, if direction == "Buy" then "ItemNotBuyable" else "ItemNotSellable"
		end
		return definition, price, nil
	end

	local function goldFor(data: any): (number?, string?)
		if not validWhole(data.Gold, Service.MaximumGold) then
			return nil, "InvalidGold"
		end
		return data.Gold, nil
	end

	local function inventoryFor(data: any): (any?, string?)
		local inventory = data.Inventory
		if type(inventory) ~= "table" or type(inventory.Stacks) ~= "table" or type(inventory.Items) ~= "table" then
			return nil, "InvalidInventory"
		end
		return inventory, nil
	end

	function service.GetGold(userId: number): (number?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		return goldFor(data)
	end

	-- Trusted server compositions may use this inside one PlayerData.Update transaction.
	function service.CreditGoldToData(data: any, amount: number): (number?, string?)
		if not validPositiveWhole(amount, Service.MaximumGold) then
			return nil, "InvalidAmount"
		end
		local gold, goldReason = goldFor(data)
		if not gold then
			return nil, goldReason
		end
		if gold > Service.MaximumGold - amount then
			return nil, "GoldOutOfBounds"
		end
		local result = gold + amount
		data.Gold = result
		return result, nil
	end

	function service.CreditGold(userId: number, amount: number): (number?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validPositiveWhole(amount, Service.MaximumGold) then
			return nil, "InvalidAmount"
		end
		local result: number? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			result, mutationReason = service.CreditGoldToData(data, amount)
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	-- Trusted server compositions may use this inside one PlayerData.Update transaction.
	function service.DebitGoldToData(data: any, amount: number): (number?, string?)
		if not validPositiveWhole(amount, Service.MaximumGold) then
			return nil, "InvalidAmount"
		end
		local gold, goldReason = goldFor(data)
		if not gold then
			return nil, goldReason
		end
		if gold < amount then
			return nil, "InsufficientGold"
		end
		local result = gold - amount
		data.Gold = result
		return result, nil
	end

	function service.DebitGold(userId: number, amount: number): (number?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validPositiveWhole(amount, Service.MaximumGold) then
			return nil, "InvalidAmount"
		end
		local result: number? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			result, mutationReason = service.DebitGoldToData(data, amount)
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	function service.PurchaseStack(userId: number, catalogId: string, definitionId: string, amount: number): (StackTransaction?, string?)
		local catalog, catalogReason = catalogFor(catalogId)
		if not catalog then
			return nil, catalogReason
		end
		local definition, unitPrice, entryReason = entryFor(catalog, definitionId, "Buy")
		if not definition or not unitPrice then
			return nil, entryReason
		end
		if definition.Kind ~= "Stackable" then
			return nil, "InvalidItemDefinitionId"
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validPositiveWhole(amount, Service.MaximumStack) then
			return nil, "InvalidAmount"
		end
		local price, priceReason = totalPrice(unitPrice, amount)
		if not price then
			return nil, priceReason
		end

		local result: StackTransaction? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			local gold, goldReason = goldFor(data)
			local inventory, inventoryReason = inventoryFor(data)
			if not gold then
				mutationReason = goldReason
				return
			end
			if not inventory then
				mutationReason = inventoryReason
				return
			end
			local current = inventory.Stacks[definitionId] or 0
			if current ~= 0 and not validPositiveWhole(current, Service.MaximumStack) then
				mutationReason = "InvalidInventory"
				return
			end
			if gold < price then
				mutationReason = "InsufficientGold"
				return
			end
			if current > Service.MaximumStack - amount then
				mutationReason = "AmountOutOfBounds"
				return
			end
			data.Gold = gold - price
			inventory.Stacks[definitionId] = current + amount
			result = { Gold = data.Gold, DefinitionId = definitionId, Amount = amount }
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	function service.SellStack(userId: number, catalogId: string, definitionId: string, amount: number): (StackTransaction?, string?)
		local catalog, catalogReason = catalogFor(catalogId)
		if not catalog then
			return nil, catalogReason
		end
		local definition, unitPrice, entryReason = entryFor(catalog, definitionId, "Sell")
		if not definition or not unitPrice then
			return nil, entryReason
		end
		if definition.Kind ~= "Stackable" then
			return nil, "InvalidItemDefinitionId"
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validPositiveWhole(amount, Service.MaximumStack) then
			return nil, "InvalidAmount"
		end
		local price, priceReason = totalPrice(unitPrice, amount)
		if not price then
			return nil, priceReason
		end

		local result: StackTransaction? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			local gold, goldReason = goldFor(data)
			local inventory, inventoryReason = inventoryFor(data)
			if not gold then
				mutationReason = goldReason
				return
			end
			if not inventory then
				mutationReason = inventoryReason
				return
			end
			local current = inventory.Stacks[definitionId]
			if not validPositiveWhole(current, Service.MaximumStack) or amount > current then
				mutationReason = "InsufficientItems"
				return
			end
			local payout = saleValueFor(data, definitionId, price)
			if gold > Service.MaximumGold - payout then
				mutationReason = "GoldOutOfBounds"
				return
			end
			data.Gold = gold + payout
			local nextAmount = current - amount
			if nextAmount == 0 then
				inventory.Stacks[definitionId] = nil
			else
				inventory.Stacks[definitionId] = nextAmount
			end
			result = { Gold = data.Gold, DefinitionId = definitionId, Amount = amount }
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	function service.PurchaseDiscrete(userId: number, catalogId: string, definitionId: string): (DiscreteTransaction?, string?)
		local catalog, catalogReason = catalogFor(catalogId)
		if not catalog then
			return nil, catalogReason
		end
		local definition, price, entryReason = entryFor(catalog, definitionId, "Buy")
		if not definition or not price then
			return nil, entryReason
		end
		if definition.Kind ~= "Discrete" then
			return nil, "InvalidItemDefinitionId"
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local generated, instanceId = pcall(runtime.NewInstanceId)
		if not generated or not validInstanceId(instanceId) then
			return nil, "InvalidGeneratedInstanceId"
		end

		local result: DiscreteTransaction? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			local gold, goldReason = goldFor(data)
			local inventory, inventoryReason = inventoryFor(data)
			if not gold then
				mutationReason = goldReason
				return
			end
			if not inventory then
				mutationReason = inventoryReason
				return
			end
			if gold < price then
				mutationReason = "InsufficientGold"
				return
			end
			if inventory.Items[instanceId] then
				mutationReason = "InstanceIdCollision"
				return
			end
			data.Gold = gold - price
			inventory.Items[instanceId] = { DefinitionId = definitionId }
			result = { Gold = data.Gold, DefinitionId = definitionId, InstanceId = instanceId }
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	function service.SellDiscrete(userId: number, catalogId: string, instanceId: string): (DiscreteTransaction?, string?)
		local catalog, catalogReason = catalogFor(catalogId)
		if not catalog then
			return nil, catalogReason
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validInstanceId(instanceId) then
			return nil, "InvalidInstanceId"
		end

		local result: DiscreteTransaction? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			local gold, goldReason = goldFor(data)
			local inventory, inventoryReason = inventoryFor(data)
			if not gold then
				mutationReason = goldReason
				return
			end
			if not inventory then
				mutationReason = inventoryReason
				return
			end
			if type(data.Equipment) ~= "table" then
				mutationReason = "InvalidEquipment"
				return
			end
			local item = inventory.Items[instanceId]
			if type(item) ~= "table" or not validDefinitionId(item.DefinitionId) then
				mutationReason = if item then "InvalidInventory" else "ItemNotOwned"
				return
			end
			local definition, price, entryReason = entryFor(catalog, item.DefinitionId, "Sell")
			if definition and definition.Kind ~= "Discrete" then
				mutationReason = "InvalidInventory"
				return
			end
			if not definition or not price then
				mutationReason = if entryReason == "InvalidItemDefinitionId" then "InvalidInventory" else entryReason
				return
			end
			for _, equippedInstanceId in data.Equipment do
				if equippedInstanceId == instanceId then
					mutationReason = "ItemEquipped"
					return
				end
			end
			local payout = saleValueFor(data, definition.Id, price)
			if gold > Service.MaximumGold - payout then
				mutationReason = "GoldOutOfBounds"
				return
			end
			data.Gold = gold + payout
			inventory.Items[instanceId] = nil
			result = { Gold = data.Gold, DefinitionId = definition.Id, InstanceId = instanceId }
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	return table.freeze(service)
end

return table.freeze(Service)
