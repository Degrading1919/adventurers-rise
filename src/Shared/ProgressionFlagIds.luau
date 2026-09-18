--!strict

-- Persist these IDs. Add future progression milestones without changing existing values.
-- Values are ProgressionFlags keys; only trusted server code may set them (see
-- Server/Ascension/Service.luau's RecordBossMilestone).
local ids = {
	GoblinChieftainDefeated = "flag_boss_goblin_chieftain_defeated",
	StarterKitGranted = "flag_starter_kit_granted",
}

local byId: { [string]: boolean } = {
	[ids.GoblinChieftainDefeated] = true,
	[ids.StarterKitGranted] = true,
}

return table.freeze({
	GoblinChieftainDefeated = ids.GoblinChieftainDefeated,
	StarterKitGranted = ids.StarterKitGranted,
	ById = table.freeze(byId),
})
