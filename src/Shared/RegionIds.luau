--!strict

-- Persist these IDs. Region I of Adventurer's Rise ("The Borderlands", per docs/DESIGN_SOURCE_OF_TRUTH
-- and V1_SCOPE) and its neighborhood zones. Add regions/zones without changing existing values. Display
-- names live in RegionDefinitions; these are the stable identifiers used by data and runtime zone-detection.
-- (The region id was reconciled from an unauthorized "region_marchlands" drift back to canon; the region
-- id is not a persisted save key, and the persisted zone/discovery ids are unchanged. See mission/DECISIONS.)

local Region = {
	Borderlands = "region_borderlands",
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
