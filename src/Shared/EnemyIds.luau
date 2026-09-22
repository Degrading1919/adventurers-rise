--!strict

-- Persist these IDs. Add future enemy types without changing existing values.
local ids = {
	Goblin = "enemy_goblin",
	GoblinChieftain = "enemy_goblin_chieftain",
	-- A second normal archetype used to prove localized, geographically distinct enemy populations:
	-- a fast, fragile pack predator that inhabits its own territory apart from the goblins.
	Wolf = "enemy_wolf",
	-- Region I mid-tier threats populating the rocky south and the ruined west:
	-- Hobgoblin (a bigger, tougher goblinoid) and Bandit (a human rogue of the ruins).
	Hobgoblin = "enemy_hobgoblin",
	Bandit = "enemy_bandit",
	-- Region I's second shared boss: the Bandit Warlord who holds the ruined watchtower.
	BanditWarlord = "enemy_bandit_warlord",
}

local byId: { [string]: boolean } = {
	[ids.Goblin] = true,
	[ids.GoblinChieftain] = true,
	[ids.Wolf] = true,
	[ids.Hobgoblin] = true,
	[ids.Bandit] = true,
	[ids.BanditWarlord] = true,
}

return table.freeze({
	Goblin = ids.Goblin,
	GoblinChieftain = ids.GoblinChieftain,
	Wolf = ids.Wolf,
	Hobgoblin = ids.Hobgoblin,
	Bandit = ids.Bandit,
	BanditWarlord = ids.BanditWarlord,
	ById = table.freeze(byId),
})
