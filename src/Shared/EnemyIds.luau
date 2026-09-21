--!strict

-- Persist these IDs. Add future enemy types without changing existing values.
local ids = {
	Goblin = "enemy_goblin",
	GoblinChieftain = "enemy_goblin_chieftain",
	-- A second normal archetype used to prove localized, geographically distinct enemy populations:
	-- a fast, fragile pack predator that inhabits its own territory apart from the goblins.
	Wolf = "enemy_wolf",
}

local byId: { [string]: boolean } = {
	[ids.Goblin] = true,
	[ids.GoblinChieftain] = true,
	[ids.Wolf] = true,
}

return table.freeze({
	Goblin = ids.Goblin,
	GoblinChieftain = ids.GoblinChieftain,
	Wolf = ids.Wolf,
	ById = table.freeze(byId),
})
