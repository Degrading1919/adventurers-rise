--!strict

-- Persist these IDs. Add recipes without changing existing values.
local ids = {
	IronBar = "recipe_iron_bar",
	SwordUpgraded = "recipe_sword_upgraded",
	IronHelm = "recipe_iron_helm",
	IronBody = "recipe_iron_body",
	IronLegs = "recipe_iron_legs",
	SteelBar = "recipe_steel_bar",
	SwordSteel = "recipe_sword_steel",
	SteelHelm = "recipe_steel_helm",
	SteelBody = "recipe_steel_body",
	SteelLegs = "recipe_steel_legs",
}

local byId: { [string]: boolean } = {
	[ids.IronBar] = true,
	[ids.SwordUpgraded] = true,
	[ids.IronHelm] = true,
	[ids.IronBody] = true,
	[ids.IronLegs] = true,
	[ids.SteelBar] = true,
	[ids.SwordSteel] = true,
	[ids.SteelHelm] = true,
	[ids.SteelBody] = true,
	[ids.SteelLegs] = true,
}

return table.freeze({
	IronBar = ids.IronBar,
	SwordUpgraded = ids.SwordUpgraded,
	IronHelm = ids.IronHelm,
	IronBody = ids.IronBody,
	IronLegs = ids.IronLegs,
	SteelBar = ids.SteelBar,
	SwordSteel = ids.SwordSteel,
	SteelHelm = ids.SteelHelm,
	SteelBody = ids.SteelBody,
	SteelLegs = ids.SteelLegs,
	ById = table.freeze(byId),
})
