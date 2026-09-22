--!strict

-- Persist these IDs. Add nodes without changing existing values.
local ids = {
	IronOre = "node_iron_ore",
	Coal = "node_coal",
}

local byId: { [string]: boolean } = {
	[ids.IronOre] = true,
	[ids.Coal] = true,
}

return table.freeze({
	IronOre = ids.IronOre,
	Coal = ids.Coal,
	ById = table.freeze(byId),
})
