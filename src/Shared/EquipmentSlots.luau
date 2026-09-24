--!strict

local slots = {
	Weapon = "slot_weapon",
	Tool = "slot_tool",
	-- Armour slots (Defense progression). Add future slots without changing existing values.
	Head = "slot_head",
	Body = "slot_body",
	Legs = "slot_legs",
}

local byId: { [string]: boolean } = {
	[slots.Weapon] = true,
	[slots.Tool] = true,
	[slots.Head] = true,
	[slots.Body] = true,
	[slots.Legs] = true,
}

return table.freeze({
	Weapon = slots.Weapon,
	Tool = slots.Tool,
	Head = slots.Head,
	Body = slots.Body,
	Legs = slots.Legs,
	-- The armour slots, in display order, so the UI/combat can iterate them without hardcoding.
	Armour = table.freeze({ slots.Head, slots.Body, slots.Legs }),
	ById = table.freeze(byId),
})
