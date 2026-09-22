--!strict

-- Persist these IDs. Add recipes without changing existing values.
local ids = {
	IronBar = "recipe_iron_bar",
	SwordUpgraded = "recipe_sword_upgraded",
	IronHelm = "recipe_iron_helm",
	IronBody = "recipe_iron_body",
	IronLegs = "recipe_iron_legs",
}

local byId: { [string]: boolean } = {
	[ids.IronBar] = true,
	[ids.SwordUpgraded] = true,
	[ids.IronHelm] = true,
	[ids.IronBody] = true,
	[ids.IronLegs] = true,
}

return table.freeze({
	IronBar = ids.IronBar,
	SwordUpgraded = ids.SwordUpgraded,
	IronHelm = ids.IronHelm,
	IronBody = ids.IronBody,
	IronLegs = ids.IronLegs,
	ById = table.freeze(byId),
})
