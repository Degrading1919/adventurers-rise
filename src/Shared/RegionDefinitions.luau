--!strict

-- Data-driven region/zone definitions for the open world. A ZONE is a flat-world neighborhood centred
-- at (CenterX, CenterZ) with a Radius; zones carry a difficulty Tier, a Safe flag, an ambient key
-- (drives per-region audio/lighting mood), a one-line Blurb, and a RecommendedLevel hint used for the
-- region-entry banner and soft-gating presentation. This is pure shared data: the client reads it for
-- the banner/ambient, the scene-builder places biomes/populations to match it, and the pure ZoneAt()
-- resolver classifies a world position into a zone (unit-testable, no Roblox instances).
--
-- Geography note: all zones live on the flat walkable surface (y=0). Region I is "The Marchlands" --
-- a grounded medieval frontier radiating from the safe town, with difficulty rising outward.

local RegionIds = require(script.Parent.RegionIds)

local RegionId = RegionIds.Region
local ZoneId = RegionIds.Zone

export type Zone = {
	read Id: string,
	read RegionId: string,
	read DisplayName: string,
	read CenterX: number,
	read CenterZ: number,
	read Radius: number,
	read Tier: number,
	read Safe: boolean,
	read Ambient: string,
	read RecommendedLevel: number,
	read Blurb: string,
}
export type Region = {
	read Id: string,
	read DisplayName: string,
	read Subtitle: string,
}

local function zone(id: string, regionId: string, name: string, cx: number, cz: number, radius: number, tier: number, safe: boolean, ambient: string, recommendedLevel: number, blurb: string): Zone
	return table.freeze({
		Id = id, RegionId = regionId, DisplayName = name,
		CenterX = cx, CenterZ = cz, Radius = radius,
		Tier = tier, Safe = safe, Ambient = ambient, RecommendedLevel = recommendedLevel, Blurb = blurb,
	})
end

local regions: { [string]: Region } = {
	[RegionId.Marchlands] = table.freeze({
		Id = RegionId.Marchlands,
		DisplayName = "The Marchlands",
		Subtitle = "A grounded frontier of farms, woods, and old ruins.",
	}),
}

-- Ordered so ZoneAt's nearest-center tiebreak is deterministic; all belong to The Marchlands.
local zones: { Zone } = {
	zone(ZoneId.Town, RegionId.Marchlands, "Havenbrook", 0, 0, 150, 1, true, "town", 1, "A safe frontier town: train, forge, and trade."),
	zone(ZoneId.Meadow, RegionId.Marchlands, "Green Meadows", 260, 0, 210, 2, false, "meadow", 3, "Goblins roam the eastern farmland."),
	zone(ZoneId.Forest, RegionId.Marchlands, "Whispering Woods", 0, 260, 210, 2, false, "forest", 3, "Wolves hunt the northern woods."),
	zone(ZoneId.Hills, RegionId.Marchlands, "Ironrock Hollow", 0, -270, 210, 3, false, "hills", 6, "Iron veins and hardier foes lie to the south."),
	zone(ZoneId.Ruins, RegionId.Marchlands, "Ashen Ruins", -270, 0, 210, 3, false, "ruins", 6, "Bandits haunt the crumbling western frontier."),
	zone(ZoneId.Warren, RegionId.Marchlands, "Goblin Warren", 330, 0, 95, 4, false, "warren", 8, "The Goblin Chieftain's deep lair."),
}
local zoneById: { [string]: Zone } = {}
for _, z in zones do
	zoneById[z.Id] = z
end

local Definitions = {}

Definitions.Regions = table.freeze(regions)
Definitions.Zones = table.freeze(zones)
Definitions.ZoneById = table.freeze(zoneById)

-- Pure classification: the flat-distance-nearest zone whose radius contains (x, z); nil in open
-- wilderness between zones. Deterministic tiebreak = nearest centre (handles overlapping radii, e.g.
-- the town overlapping the meadow). No Roblox instances -- fully unit-testable.
function Definitions.ZoneAt(x: number, z: number): Zone?
	local best: Zone? = nil
	local bestDist: number? = nil
	for _, zoneDef in zones do
		local dx, dz = x - zoneDef.CenterX, z - zoneDef.CenterZ
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist <= zoneDef.Radius and (bestDist == nil or dist < bestDist) then
			best = zoneDef
			bestDist = dist
		end
	end
	return best
end

function Definitions.Validate(): (boolean, string?)
	for _, z in zones do
		if not RegionIds.ZoneById[z.Id] then
			return false, "Zone id must be stable: " .. tostring(z.Id)
		end
		if not RegionIds.RegionById[z.RegionId] or regions[z.RegionId] == nil then
			return false, "Zone must belong to a known region: " .. tostring(z.Id)
		end
		if type(z.DisplayName) ~= "string" or z.DisplayName == "" then
			return false, "Zone requires a display name: " .. tostring(z.Id)
		end
		if type(z.Radius) ~= "number" or z.Radius <= 0 or z.Radius ~= z.Radius then
			return false, "Zone requires a positive radius: " .. tostring(z.Id)
		end
		if type(z.Tier) ~= "number" or z.Tier < 1 or z.Tier % 1 ~= 0 then
			return false, "Zone tier must be a positive whole number: " .. tostring(z.Id)
		end
	end
	return true, nil
end

return table.freeze(Definitions)
