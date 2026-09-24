--!strict

-- Persist these IDs. Add future Ascension ranks without changing existing values.
-- Adventurer must stay "ascension_adventurer": PlayerData.Schema.New() hardcodes it as the
-- default starting rank for fresh saves.
local ids = {
	Adventurer = "ascension_adventurer",
	Adept = "ascension_adept",
	Vanguard = "ascension_vanguard",
}

local byId: { [string]: boolean } = {
	[ids.Adventurer] = true,
	[ids.Adept] = true,
	[ids.Vanguard] = true,
}

return table.freeze({
	Adventurer = ids.Adventurer,
	Adept = ids.Adept,
	Vanguard = ids.Vanguard,
	ById = table.freeze(byId),
})
