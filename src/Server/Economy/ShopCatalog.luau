--!strict

export type Entry = {
	read ItemDefinitionId: string,
	read BuyPrice: number?,
	read SellPrice: number?,
}
export type Catalog = {
	read Id: string,
	read Entries: { [string]: Entry },
}

local function entry(itemDefinitionId: string, buyPrice: number?, sellPrice: number?): Entry
	return table.freeze({
		ItemDefinitionId = itemDefinitionId,
		BuyPrice = buyPrice,
		SellPrice = sellPrice,
	})
end

-- Prices are provisional. Selling an item listed for purchase always returns less Gold.
local hubEntries: { [string]: Entry } = {
	item_iron_ore = entry("item_iron_ore", 10, 4),
	item_iron_bar = entry("item_iron_bar", nil, 12),
	weapon_sword_upgraded = entry("weapon_sword_upgraded", 500, 200),
}
local hubCatalog: Catalog = table.freeze({
	Id = "shop_hub",
	Entries = table.freeze(hubEntries),
})

local catalogs: { [string]: Catalog } = {
	shop_hub = hubCatalog,
}

return table.freeze({
	ById = table.freeze(catalogs),
})
