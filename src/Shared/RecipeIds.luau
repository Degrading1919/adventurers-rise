--!strict

-- Persist these IDs. Add recipes without changing existing values.
local ids = {
	IronBar = "recipe_iron_bar",
	SwordUpgraded = "recipe_sword_upgraded",
}

local byId: { [string]: boolean } = {
	[ids.IronBar] = true,
	[ids.SwordUpgraded] = true,
}

return table.freeze({
	IronBar = ids.IronBar,
	SwordUpgraded = ids.SwordUpgraded,
	ById = table.freeze(byId),
})
