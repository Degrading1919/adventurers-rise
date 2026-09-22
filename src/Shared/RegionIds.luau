--!strict

-- Persist these IDs. Region I of Adventurer's Rise ("The Marchlands") and its neighborhood zones.
-- Add regions/zones without changing existing values. Display names live in RegionDefinitions; these
-- are the stable identifiers used by data, saves, and the runtime zone-detection.

local Region = {
	Marchlands = "region_marchlands",
}

local Zone = {
	Town = "zone_havenbrook",
	Meadow = "zone_green_meadows",
	Forest = "zone_whispering_woods",
	Hills = "zone_ironrock_hollow",
	Ruins = "zone_ashen_ruins",
	Warren = "zone_goblin_warren",
}

local regionById: { [string]: boolean } = {}
for _, id in (Region :: { [string]: string }) do
	regionById[id] = true
end
local zoneById: { [string]: boolean } = {}
for _, id in (Zone :: { [string]: string }) do
	zoneById[id] = true
end

return table.freeze({
	Region = table.freeze(Region),
	Zone = table.freeze(Zone),
	RegionById = table.freeze(regionById),
	ZoneById = table.freeze(zoneById),
})
