--!strict

-- Persist these IDs. Add future Ascension ranks without changing existing values.
-- Adventurer must stay "ascension_adventurer": PlayerData.Schema.New() hardcodes it as the
-- default starting rank for fresh saves.
local ids = {
	Adventurer = "ascension_adventurer",
	Adept = "ascension_adept",
}

local byId: { [string]: boolean } = {
	[ids.Adventurer] = true,
	[ids.Adept] = true,
}

return table.freeze({
	Adventurer = ids.Adventurer,
	Adept = ids.Adept,
	ById = table.freeze(byId),
})
