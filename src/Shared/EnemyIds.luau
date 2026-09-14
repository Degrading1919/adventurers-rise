--!strict

-- Persist these IDs. Add future enemy types without changing existing values.
local ids = {
	Goblin = "enemy_goblin",
	GoblinChieftain = "enemy_goblin_chieftain",
}

local byId: { [string]: boolean } = {
	[ids.Goblin] = true,
	[ids.GoblinChieftain] = true,
}

return table.freeze({
	Goblin = ids.Goblin,
	GoblinChieftain = ids.GoblinChieftain,
	ById = table.freeze(byId),
})
