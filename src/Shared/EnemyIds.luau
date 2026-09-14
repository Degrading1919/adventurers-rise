--!strict

-- Persist these IDs. Add future enemy types without changing existing values.
local ids = {
	Goblin = "enemy_goblin",
}

local byId: { [string]: boolean } = {
	[ids.Goblin] = true,
}

return table.freeze({
	Goblin = ids.Goblin,
	ById = table.freeze(byId),
})
