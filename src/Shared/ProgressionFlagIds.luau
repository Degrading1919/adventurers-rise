--!strict

-- Persist these IDs. Add future progression milestones without changing existing values.
-- Values are ProgressionFlags keys; only trusted server code may set them (see
-- Server/Ascension/Service.luau's RecordBossMilestone).
local ids = {
	GoblinChieftainDefeated = "flag_boss_goblin_chieftain_defeated",
}

local byId: { [string]: boolean } = {
	[ids.GoblinChieftainDefeated] = true,
}

return table.freeze({
	GoblinChieftainDefeated = ids.GoblinChieftainDefeated,
	ById = table.freeze(byId),
})
