--!strict

local slots = {
	Weapon = "slot_weapon",
	Tool = "slot_tool",
}

local byId: { [string]: boolean } = {
	[slots.Weapon] = true,
	[slots.Tool] = true,
}

return table.freeze({
	Weapon = slots.Weapon,
	Tool = slots.Tool,
	ById = table.freeze(byId),
})
