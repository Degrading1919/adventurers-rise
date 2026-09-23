--!strict

-- Data-driven first-visit discovery rewards, keyed by the stable zone id. Discovering a wilderness zone
-- for the first time records its one-time ProgressionFlag and grants a Gold reward that scales with how
-- far/dangerous the zone is, so exploration pays out and the world has reasons to push outward. The town
-- (spawn) is home base, deliberately not a discovery. Display names live in RegionDefinitions.
--
-- Content, not code: add a zone's discovery reward here (+ its ProgressionFlag) without touching the
-- Discovery service, which is generic over this table.

local Shared = game:GetService("ReplicatedStorage").Shared
local RegionIds = require(Shared.RegionIds)
local ProgressionFlagIds = require(Shared.ProgressionFlagIds)

export type Definition = {
	read ZoneId: string,
	read FlagId: string,
	read RewardGold: number,
}

local DiscoveryDefinitions = {}

local function positiveWhole(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function definition(zoneId: string, flagId: string, rewardGold: number): Definition
	return table.freeze({ ZoneId = zoneId, FlagId = flagId, RewardGold = rewardGold })
end

-- Rewards rise monotonically with a zone's danger (its RegionDefinitions RecommendedLevel: Ironrock 1 <
-- Whispering Woods 2 < Green Meadows 3 < Ashen Ruins 6 < Goblin Warren 8), so braving a harder, deeper
-- zone pays more than a safe mining hollow -- and finding the Warlord's lair (Warren) is a real prize.
-- Provisional, replaceable balance data.
local ZoneId = RegionIds.Zone
local definitions: { [string]: Definition } = {
	[ZoneId.Hills] = definition(ZoneId.Hills, ProgressionFlagIds.DiscoveredHills, 25),
	[ZoneId.Forest] = definition(ZoneId.Forest, ProgressionFlagIds.DiscoveredForest, 40),
	[ZoneId.Meadow] = definition(ZoneId.Meadow, ProgressionFlagIds.DiscoveredMeadow, 55),
	[ZoneId.Ruins] = definition(ZoneId.Ruins, ProgressionFlagIds.DiscoveredRuins, 90),
	[ZoneId.Warren] = definition(ZoneId.Warren, ProgressionFlagIds.DiscoveredWarren, 150),
}

function DiscoveryDefinitions.Validate(candidateDefinitions: any): (boolean, string?)
	if type(candidateDefinitions) ~= "table" then
		return false, "Discovery definitions must be a table"
	end
	local seenFlags: { [string]: boolean } = {}
	for zoneId, entry in candidateDefinitions do
		if type(zoneId) ~= "string" or RegionIds.ZoneById[zoneId] ~= true or type(entry) ~= "table" or entry.ZoneId ~= zoneId then
			return false, "Discovery zone ids must be stable and known"
		end
		if entry.ZoneId == ZoneId.Town then
			return false, "The town is home base, not a discovery"
		end
		if type(entry.FlagId) ~= "string" or ProgressionFlagIds.ById[entry.FlagId] ~= true or seenFlags[entry.FlagId] then
			return false, "Discovery flags must be distinct known progression flags"
		end
		seenFlags[entry.FlagId] = true
		if not positiveWhole(entry.RewardGold) then
			return false, "Discovery rewards must be positive whole Gold amounts"
		end
	end
	return true, nil
end

return table.freeze({
	ById = table.freeze(definitions),
	Validate = DiscoveryDefinitions.Validate,
})
