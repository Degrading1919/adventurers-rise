--!strict

export type Kind = "Stackable" | "Discrete"
export type Definition = {
	read Id: string,
	read Kind: Kind,
}

local function definition(id: string, kind: Kind): Definition
	return table.freeze({ Id = id, Kind = kind })
end

-- Persist these IDs. Classification is the only item data in this foundation.
local definitions: { [string]: Definition } = {
	item_iron_ore = definition("item_iron_ore", "Stackable"),
	item_iron_bar = definition("item_iron_bar", "Stackable"),
	weapon_sword_starter = definition("weapon_sword_starter", "Discrete"),
	weapon_sword_upgraded = definition("weapon_sword_upgraded", "Discrete"),
	tool_pickaxe_basic = definition("tool_pickaxe_basic", "Discrete"),
	tool_pickaxe_upgraded = definition("tool_pickaxe_upgraded", "Discrete"),
}

return table.freeze({
	ById = table.freeze(definitions),
})
