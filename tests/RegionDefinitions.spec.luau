--!strict

-- Deterministic tests for the pure region/zone data + the ZoneAt classifier (no Roblox instances).

local RegionDefinitions = require("RegionDefinitions")
local RegionIds = require("RegionIds")

local passed = 0
local function test(name, run)
	local ok, message = pcall(run)
	assert(ok, name .. ": " .. tostring(message))
	passed += 1
	print("PASS " .. name)
end
local function equal(actual, expected)
	assert(actual == expected, ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
end

test("the region/zone definitions validate", function()
	local ok, reason = RegionDefinitions.Validate()
	assert(ok, tostring(reason))
end)

test("ZoneAt classifies each zone centre to its own zone", function()
	equal(RegionDefinitions.ZoneAt(0, 0).Id, RegionIds.Zone.Town)
	equal(RegionDefinitions.ZoneAt(260, 0).Id, RegionIds.Zone.Meadow)
	equal(RegionDefinitions.ZoneAt(0, 260).Id, RegionIds.Zone.Forest)
	equal(RegionDefinitions.ZoneAt(0, -270).Id, RegionIds.Zone.Hills)
	equal(RegionDefinitions.ZoneAt(-270, 0).Id, RegionIds.Zone.Ruins)
	equal(RegionDefinitions.ZoneAt(330, 0).Id, RegionIds.Zone.Warren)
end)

test("overlapping radii resolve to the nearest centre (town vs meadow)", function()
	-- (100,0) is inside both the town (r150) and the meadow (centre 260, r210); nearest centre = town.
	equal(RegionDefinitions.ZoneAt(100, 0).Id, RegionIds.Zone.Town)
	-- Deep east near the warren centre resolves to the warren, not the enclosing meadow.
	equal(RegionDefinitions.ZoneAt(330, 0).Id, RegionIds.Zone.Warren)
end)

test("open wilderness between zones is unclassified (nil)", function()
	equal(RegionDefinitions.ZoneAt(600, 600), nil)
	equal(RegionDefinitions.ZoneAt(-500, 400), nil)
end)

test("the town is safe and the wild zones are not", function()
	equal(RegionDefinitions.ZoneById[RegionIds.Zone.Town].Safe, true)
	equal(RegionDefinitions.ZoneById[RegionIds.Zone.Meadow].Safe, false)
	equal(RegionDefinitions.ZoneById[RegionIds.Zone.Warren].Safe, false)
end)

test("difficulty tier rises outward from the town", function()
	local town = RegionDefinitions.ZoneById[RegionIds.Zone.Town].Tier
	local meadow = RegionDefinitions.ZoneById[RegionIds.Zone.Meadow].Tier
	local warren = RegionDefinitions.ZoneById[RegionIds.Zone.Warren].Tier
	assert(town < meadow and meadow < warren, "tiers must increase outward")
end)

print(("%d RegionDefinitions checks passed"):format(passed))
