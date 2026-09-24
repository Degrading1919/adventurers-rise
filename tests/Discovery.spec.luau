--!strict

local RegionIds = require("RegionIds")
local DiscoveryDefinitions = require("DiscoveryDefinitions")
local Discovery = require("DiscoveryService")

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

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

-- Fake PlayerData + Economy + zone resolver. The zone the player "stands in" is driven by `zones`.
local function fixture()
	local records = {
		[7] = { Gold = 25, ProgressionFlags = {} },
	}
	local zones: { [number]: string? } = {}
	local playerData = {}
	function playerData.GetSnapshot(userId)
		return if records[userId] then copy(records[userId]) else nil
	end
	function playerData.Update(userId, change)
		local candidate = copy(records[userId])
		if not candidate then
			return false, "NotReady"
		end
		local ok, reason = pcall(change, candidate)
		if not ok then
			return false, tostring(reason)
		end
		records[userId] = candidate
		return true, nil
	end
	local economy = {}
	function economy.CreditGoldToData(data, amount)
		if type(amount) ~= "number" or amount <= 0 then
			return nil, "InvalidAmount"
		end
		data.Gold = (data.Gold or 0) + amount
		return data.Gold, nil
	end
	local function zoneResolver(userId)
		local zoneId = zones[userId]
		if zoneId == nil then
			return nil, "NotInAZone"
		end
		return zoneId, nil
	end
	local service = Discovery.New(playerData, economy, zoneResolver)
	return { Records = records, Zones = zones, Service = service }
end

test("discovery definitions are stable, exclude the town, and carry positive rewards", function()
	local valid = DiscoveryDefinitions.Validate(DiscoveryDefinitions.ById)
	equal(valid, true)
	equal(DiscoveryDefinitions.ById[RegionIds.Zone.Town], nil)
	local meadow = DiscoveryDefinitions.ById[RegionIds.Zone.Meadow]
	equal(meadow.ZoneId, RegionIds.Zone.Meadow)
	assert(meadow.RewardGold > 0, "meadow reward must be positive")
end)

test("a first visit grants the zone's reward once and records its flag; re-entry grants nothing", function()
	local f = fixture()
	f.Zones[7] = RegionIds.Zone.Meadow
	local first = assert(f.Service.DiscoverCurrentZone(7))
	equal(first.NewlyDiscovered, true)
	equal(first.RewardGold, DiscoveryDefinitions.ById[RegionIds.Zone.Meadow].RewardGold)
	equal(f.Records[7].Gold, 25 + first.RewardGold)
	equal(f.Records[7].ProgressionFlags[DiscoveryDefinitions.ById[RegionIds.Zone.Meadow].FlagId], true)

	local second = assert(f.Service.DiscoverCurrentZone(7))
	equal(second.NewlyDiscovered, false)
	equal(f.Records[7].Gold, 25 + first.RewardGold) -- no second reward
end)

test("the town is home base, not a discovery -- no flag, no reward", function()
	local f = fixture()
	f.Zones[7] = RegionIds.Zone.Town
	local result = assert(f.Service.DiscoverCurrentZone(7))
	equal(result.NewlyDiscovered, false)
	equal(f.Records[7].Gold, 25)
end)

test("open wilderness is not a discovery and surfaces the resolver's reason", function()
	local f = fixture()
	f.Zones[7] = nil
	local result, reason = f.Service.DiscoverCurrentZone(7)
	equal(result, nil)
	equal(reason, "NotInAZone")
	equal(f.Records[7].Gold, 25)
end)

test("different zones grant their own rewards, and GetDiscovered reflects the accumulated set", function()
	local f = fixture()
	f.Zones[7] = RegionIds.Zone.Meadow
	assert(f.Service.DiscoverCurrentZone(7))
	f.Zones[7] = RegionIds.Zone.Warren
	local warren = assert(f.Service.DiscoverCurrentZone(7))
	equal(warren.NewlyDiscovered, true)
	equal(warren.RewardGold, DiscoveryDefinitions.ById[RegionIds.Zone.Warren].RewardGold)

	local discovered = assert(f.Service.GetDiscovered(7))
	equal(discovered[RegionIds.Zone.Meadow], true)
	equal(discovered[RegionIds.Zone.Warren], true)
	equal(discovered[RegionIds.Zone.Ruins], nil)
end)

print(("%d Discovery checks passed"):format(passed))
