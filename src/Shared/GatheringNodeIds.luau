--!strict

-- Persist these IDs. Add nodes without changing existing values.
local ids = {
	IronOre = "node_iron_ore",
}

local byId: { [string]: boolean } = {
	[ids.IronOre] = true,
}

return table.freeze({
	IronOre = ids.IronOre,
	ById = table.freeze(byId),
})
