--!strict

local SkillIds = require("SkillIds")
local SkillDefinitions = require("SkillDefinitions")
local Skills = require("SkillsService")
local StationDefinitions = require("StationDefinitions")
local Plots = require("PlotsService")
local OfflineTrainingDefinitions = require("OfflineTrainingDefinitions")
local OfflineTraining = require("OfflineTrainingService")
local PlayerDataSchema = require("PlayerDataSchema")
local PlayerDataStore = require("PlayerDataStore")
local PlayerDataService = require("PlayerDataService")

local MeleeStation = "station_training_melee"
local DefenseStation = "station_training_defense"

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

local function curve()
	local thresholds = {}
	for level = 1, SkillDefinitions.LevelCap do
		thresholds[level] = (level - 1) * 100
	end
	return { MaximumXP = 50000, Thresholds = thresholds }
end

local function fixture(config)
	config = config or {}
	local records = {
		[7] = {
			Gold = 1000,
			SkillXP = {
				[SkillIds.Melee] = 0,
				[SkillIds.Defense] = 0,
				[SkillIds.Mining] = 0,
				[SkillIds.Smithing] = 0,
			},
			Inventory = { Stacks = {}, Items = {} },
			Equipment = {},
			Plot = { Stations = {} },
			ProgressionFlags = {},
			OfflineTraining = { FocusSkillId = "", ClaimedThroughAt = 0 },
			LastSessionAt = if config.LastSessionAt ~= nil then config.LastSessionAt else 0,
		},
	}
	local playerData = { Calls = 0, FailReason = nil, PersistCalls = 0, PersistFailReason = nil }
	function playerData.GetSnapshot(userId)
		return if records[userId] then copy(records[userId]) else nil
	end
	function playerData.Update(userId, change)
		playerData.Calls += 1
		if playerData.FailReason then
			return false, playerData.FailReason
		end
		local candidate = copy(records[userId])
		if not candidate then
			return false, "NotReady"
		end
		local ok = pcall(change, candidate)
		if not ok then
			return false, "InvalidMutation"
		end
		records[userId] = candidate
		return true, nil
	end
	function playerData.Persist(userId)
		playerData.PersistCalls += 1
		if playerData.PersistFailReason then
			return false, playerData.PersistFailReason
		end
		if not records[userId] then
			return false, "NotReady"
		end
		return true, nil
	end
	local skills = Skills.New(playerData, { Curves = { curve_standard = curve() } })
	local plots = Plots.New(playerData, skills)
	local clock = { Now = if config.Now ~= nil then config.Now else 10000 }
	local offline = OfflineTraining.New(playerData, skills, plots, function()
		return clock.Now
	end)
	return {
		Records = records,
		PlayerData = playerData,
		Skills = skills,
		Plots = plots,
		Clock = clock,
		Service = offline,
	}
end

test("the offline configuration is centralized and conservative", function()
	local configuration = OfflineTrainingDefinitions.Configuration
	assert(configuration.EfficiencyMultiplier > 0 and configuration.EfficiencyMultiplier < 1)
	assert(configuration.MaximumOfflineSeconds > 0)
	assert(configuration.MinimumElapsedSeconds >= 0 and configuration.MinimumElapsedSeconds <= configuration.MaximumOfflineSeconds)
	local f = fixture()
	local viaService = f.Service.GetConfiguration()
	equal(viaService.EfficiencyMultiplier, configuration.EfficiencyMultiplier)
	equal(viaService.MaximumOfflineSeconds, configuration.MaximumOfflineSeconds)
end)

test("supported Melee and Defense offline focuses can be set and persist; unsupported focuses are rejected", function()
	local f = fixture()
	local melee = assert(f.Service.SetFocus(7, SkillIds.Melee))
	equal(melee.FocusSkillId, SkillIds.Melee)
	equal(melee.StationId, MeleeStation)
	equal(melee.StationTier, 1)
	equal(f.Records[7].OfflineTraining.FocusSkillId, SkillIds.Melee)

	local defense = assert(f.Service.SetFocus(7, SkillIds.Defense))
	equal(defense.FocusSkillId, SkillIds.Defense)
	equal(f.Records[7].OfflineTraining.FocusSkillId, SkillIds.Defense)

	for _, unsupported in { SkillIds.Mining, SkillIds.Smithing, "skill_ranged", "not_a_skill" } do
		local result, reason = f.Service.SetFocus(7, unsupported)
		equal(result, nil)
		equal(reason, "UnsupportedFocusSkillId")
	end
	equal(f.Records[7].OfflineTraining.FocusSkillId, SkillIds.Defense)
end)

test("SetFocus fails closed on malformed persisted station state and preserves the prior focus", function()
	local f = fixture()
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Records[7].Plot.Stations[MeleeStation] = { Tier = 99 }
	local invalid, invalidReason = f.Service.SetFocus(7, SkillIds.Melee)
	equal(invalid, nil)
	equal(invalidReason, "InvalidStationState")
	equal(f.Records[7].OfflineTraining.FocusSkillId, SkillIds.Melee)
end)

test("SetFocus establishes a new claim baseline so historical offline time cannot be retroactively assigned", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	f.Clock.Now = 1000 + 3 * 60 * 60 -- the player returns after hours with no focus ever selected
	local focus = assert(f.Service.SetFocus(7, SkillIds.Melee))
	equal(focus.FocusSkillId, SkillIds.Melee)
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, f.Clock.Now)
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, false)
	equal(result.Reason, "ElapsedBelowThreshold")
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
end)

test("switching focus before claiming discards the prior focus's unclaimed interval", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1000 + 600 -- ten unclaimed minutes accrue under Melee
	assert(f.Service.SetFocus(7, SkillIds.Defense)) -- switch away before ever claiming them
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 1600)
	f.Clock.Now = 1600 + 300 -- only five new minutes pass under Defense
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, true)
	equal(result.FocusSkillId, SkillIds.Defense)
	equal(result.RawElapsedSeconds, 300) -- not 900; the Melee window is gone, not carried over
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	local station = StationDefinitions.ById[DefenseStation].Tiers[1]
	local expectedXP = station.XPPerSecond * OfflineTrainingDefinitions.Configuration.EfficiencyMultiplier * 300
	equal(f.Records[7].SkillXP[SkillIds.Defense], expectedXP)
end)

test("reselecting the already-active focus is idempotent and preserves legitimately accrued time", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1000 + 600
	local again = assert(f.Service.SetFocus(7, SkillIds.Melee))
	equal(again.FocusSkillId, SkillIds.Melee)
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 1000) -- unchanged: same focus, no reset
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, true)
	equal(result.RawElapsedSeconds, 600)
end)

test("SetFocus fails closed if the trusted clock appears to move backward relative to the existing claim baseline", function()
	local f = fixture({ LastSessionAt = 1000, Now = 2000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 2000)
	f.Clock.Now = 1500 -- the clock regressed relative to the existing baseline
	local result, reason = f.Service.SetFocus(7, SkillIds.Defense)
	equal(result, nil)
	equal(reason, "InvalidClock")
	equal(f.Records[7].OfflineTraining.FocusSkillId, SkillIds.Melee) -- unchanged: the whole mutation aborted
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 2000)
end)

test("a successful claim is not reported as Rewarded until it is confirmed durable, and a failed persist cannot be duplicated", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1600
	f.PlayerData.PersistFailReason = "DataStoreUnavailable"
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, false)
	equal(result.Reason, "DataStoreUnavailable")
	local expectedXP = StationDefinitions.ById[MeleeStation].Tiers[1].XPPerSecond * OfflineTrainingDefinitions.Configuration.EfficiencyMultiplier * 600
	equal(result.XPAwarded, expectedXP)
	-- The in-memory mutation still happened (so a later real persist would not lose it)...
	equal(f.Records[7].SkillXP[SkillIds.Melee], expectedXP)
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 1600)
	-- ...but the ratchet already advanced, so a repeated claim in the same live session cannot
	-- duplicate the unconfirmed award.
	f.PlayerData.PersistFailReason = nil
	local second = assert(f.Service.ClaimOfflineReward(7))
	equal(second.Rewarded, false)
	equal(second.Reason, "ElapsedBelowThreshold")
end)

test("a confirmed durable claim reports Rewarded = true and forces the trusted persistence boundary", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1600
	local before = f.PlayerData.PersistCalls
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, true)
	assert(f.PlayerData.PersistCalls > before)
end)

test("non-reward claim outcomes never force a durable write", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1600 })
	local before = f.PlayerData.PersistCalls
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Reason, "NoFocusSelected")
	equal(f.PlayerData.PersistCalls, before)
end)

test("GetFocusStation reuses the same active Plot/Training station rate, including after an upgrade", function()
	local f = fixture()
	assert(f.Service.SetFocus(7, SkillIds.Defense))
	local before = assert(f.Service.GetFocusStation(7))
	equal(before.Tier, 1)
	equal(before.XPPerSecond, StationDefinitions.ById[DefenseStation].Tiers[1].XPPerSecond)
	assert(f.Plots.UpgradeStation(7, DefenseStation))
	local after = assert(f.Service.GetFocusStation(7))
	equal(after.Tier, 2)
	equal(after.XPPerSecond, StationDefinitions.ById[DefenseStation].Tiers[2].XPPerSecond)

	local noFocus = fixture()
	local none, noneReason = noFocus.Service.GetFocusStation(7)
	equal(none, nil)
	equal(noneReason, "NoFocusSelected")
end)

test("a fresh player with no prior session receives no fabricated offline XP", function()
	local f = fixture({ LastSessionAt = 0, Now = 10000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, false)
	equal(result.Reason, "NoPriorSession")
	equal(result.XPAwarded, 0)
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	-- SetFocus still established a claim baseline at the moment it was called, even though this
	-- player has never had a real prior session to measure offline time from.
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 10000)
end)

test("no offline focus selected yields a structured non-reward result without mutation", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1700 })
	local before = copy(f.Records[7])
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, false)
	equal(result.Reason, "NoFocusSelected")
	equal(result.FocusSkillId, nil)
	equal(f.Records[7].SkillXP[SkillIds.Melee], before.SkillXP[SkillIds.Melee])
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, before.OfflineTraining.ClaimedThroughAt)
end)

test("zero elapsed and elapsed below the minimum threshold award nothing", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	local zero = assert(f.Service.ClaimOfflineReward(7))
	equal(zero.Rewarded, false)
	equal(zero.Reason, "ElapsedBelowThreshold")
	equal(zero.RawElapsedSeconds, 0)

	f.Clock.Now = 1000 + OfflineTrainingDefinitions.Configuration.MinimumElapsedSeconds - 1
	local belowThreshold = assert(f.Service.ClaimOfflineReward(7))
	equal(belowThreshold.Rewarded, false)
	equal(belowThreshold.Reason, "ElapsedBelowThreshold")
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
end)

test("a future session timestamp is rejected without awarding or mutating anything", function()
	local f = fixture({ LastSessionAt = 5000, Now = 1000 })
	-- A focus selected earlier under normal conditions, with LastSessionAt subsequently ending up
	-- ahead of the trusted clock (clock skew): set directly, since SetFocus itself would now (and
	-- correctly) refuse to run its own claim-baseline math against this same malformed timing state.
	f.Records[7].OfflineTraining.FocusSkillId = SkillIds.Melee
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, false)
	equal(result.Reason, "FutureSessionTimestamp")
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 0)
end)

test("offline training correctly awards Melee XP at the configured efficiency, strictly below active", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1600
	local station = StationDefinitions.ById[MeleeStation].Tiers[1]
	local efficiency = OfflineTrainingDefinitions.Configuration.EfficiencyMultiplier
	assert(efficiency < 1)
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, true)
	equal(result.FocusSkillId, SkillIds.Melee)
	equal(result.RawElapsedSeconds, 600)
	equal(result.CreditedElapsedSeconds, 600)
	equal(result.EfficiencyMultiplier, efficiency)
	local expectedXP = station.XPPerSecond * efficiency * 600
	equal(result.XPAwarded, expectedXP)
	assert(result.XPAwarded < station.XPPerSecond * 600) -- strictly less than what active training would give
	equal(result.SkillState.XP, expectedXP)
	equal(result.StationId, MeleeStation)
	equal(result.StationTier, 1)
	equal(f.Records[7].SkillXP[SkillIds.Melee], expectedXP)
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 1600)
end)

test("offline training correctly awards Defense XP using the upgraded active station rate", function()
	local f = fixture({ LastSessionAt = 2000, Now = 2000 })
	assert(f.Plots.UpgradeStation(7, DefenseStation))
	assert(f.Service.SetFocus(7, SkillIds.Defense))
	f.Clock.Now = 2900
	local station = StationDefinitions.ById[DefenseStation].Tiers[2]
	local efficiency = OfflineTrainingDefinitions.Configuration.EfficiencyMultiplier
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, true)
	equal(result.StationTier, 2)
	local expectedXP = station.XPPerSecond * efficiency * 900
	equal(result.XPAwarded, expectedXP)
	equal(f.Records[7].SkillXP[SkillIds.Defense], expectedXP)
end)

test("fractional XP is preserved consistently with the existing Skills model", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1061
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.RawElapsedSeconds, 61)
	local expectedXP = StationDefinitions.ById[MeleeStation].Tiers[1].XPPerSecond * OfflineTrainingDefinitions.Configuration.EfficiencyMultiplier * 61
	equal(expectedXP, 15.25)
	equal(result.XPAwarded, 15.25)
	equal(f.Records[7].SkillXP[SkillIds.Melee], 15.25)
end)

test("elapsed time above the offline cap is credited only up to the cap", function()
	local cap = OfflineTrainingDefinitions.Configuration.MaximumOfflineSeconds
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1000 + cap + 100000
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, true)
	equal(result.RawElapsedSeconds, cap + 100000)
	equal(result.CreditedElapsedSeconds, cap)
	local expectedXP = StationDefinitions.ById[MeleeStation].Tiers[1].XPPerSecond * OfflineTrainingDefinitions.Configuration.EfficiencyMultiplier * cap
	equal(result.XPAwarded, expectedXP)
	-- The claim ratchet always advances to "now", so the forfeited excess beyond the cap can
	-- never be reclaimed later.
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 1000 + cap + 100000)
end)

test("the same offline interval cannot be claimed twice, including an immediate reconnect", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1600
	local first = assert(f.Service.ClaimOfflineReward(7))
	assert(first.Rewarded)
	local xpAfterFirst = f.Records[7].SkillXP[SkillIds.Melee]

	-- Immediate reconnect / repeated claim in the same session: no time has passed since the
	-- ratchet advanced, so nothing more is awarded.
	local second = assert(f.Service.ClaimOfflineReward(7))
	equal(second.Rewarded, false)
	equal(second.Reason, "ElapsedBelowThreshold")
	equal(f.Records[7].SkillXP[SkillIds.Melee], xpAfterFirst)

	-- A little real time passes; only that new sliver is ever awarded, never the original window.
	f.Clock.Now += OfflineTrainingDefinitions.Configuration.MinimumElapsedSeconds
	local third = assert(f.Service.ClaimOfflineReward(7))
	equal(third.Rewarded, true)
	equal(third.RawElapsedSeconds, OfflineTrainingDefinitions.Configuration.MinimumElapsedSeconds)
end)

test("Skill XP cap behavior: an award that would exceed the cap is rejected without partial consumption", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1600
	f.Records[7].SkillXP[SkillIds.Melee] = 50000 -- at the configured curve's MaximumXP
	local before = copy(f.Records[7])
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, false)
	equal(result.Reason, "XPOutOfBounds")
	equal(result.XPAwarded, 0)
	equal(f.Records[7].SkillXP[SkillIds.Melee], before.SkillXP[SkillIds.Melee])
	-- Not partially consumed: the ratchet does not advance, so the interval remains available.
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, before.OfflineTraining.ClaimedThroughAt)
end)

test("offline training never grants Gold, items, equipment, or unrelated progression", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1600
	local before = copy(f.Records[7])
	assert(f.Service.ClaimOfflineReward(7))
	equal(f.Records[7].Gold, before.Gold)
	equal(next(f.Records[7].Inventory.Stacks), nil)
	equal(next(f.Records[7].Inventory.Items), nil)
	equal(next(f.Records[7].Equipment), nil)
	equal(f.Records[7].SkillXP[SkillIds.Defense], before.SkillXP[SkillIds.Defense])
	equal(f.Records[7].SkillXP[SkillIds.Mining], before.SkillXP[SkillIds.Mining])
end)

test("a failed PlayerData mutation does not consume elapsed time or award anything", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1600
	f.PlayerData.FailReason = "SimulatedFailure"
	local result, reason = f.Service.ClaimOfflineReward(7)
	equal(result, nil)
	equal(reason, "SimulatedFailure")
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 1000)
	f.PlayerData.FailReason = nil
	local retried = assert(f.Service.ClaimOfflineReward(7))
	assert(retried.Rewarded)
end)

test("focus and claim state persist across a simulated leave and rejoin", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1600
	assert(f.Service.ClaimOfflineReward(7))

	-- A brand-new Skills/Plots/OfflineTraining composition bound to the same persisted records
	-- simulates rejoining a fresh session against the same save.
	local skills2 = Skills.New(f.PlayerData, { Curves = { curve_standard = curve() } })
	local plots2 = Plots.New(f.PlayerData, skills2)
	local clock2 = { Now = 1600 + 600 }
	local offline2 = OfflineTraining.New(f.PlayerData, skills2, plots2, function()
		return clock2.Now
	end)
	equal(offline2.GetFocus(7), SkillIds.Melee)
	local result = assert(offline2.ClaimOfflineReward(7))
	equal(result.Rewarded, true)
	equal(result.RawElapsedSeconds, 600) -- measured from the persisted ClaimedThroughAt, not refabricated
end)

test("malformed persisted OfflineTraining state fails closed", function()
	local missing = fixture({ LastSessionAt = 1000, Now = 1600 })
	missing.Records[7].OfflineTraining = nil
	for _, attempt in {
		function() return missing.Service.GetFocus(7) end,
		function() return missing.Service.SetFocus(7, SkillIds.Melee) end,
		function() return missing.Service.ClaimOfflineReward(7) end,
	} do
		local result, reason = attempt()
		equal(result, nil)
		equal(reason, "InvalidOfflineTrainingState")
	end

	local badType = fixture({ LastSessionAt = 1000, Now = 1600 })
	badType.Records[7].OfflineTraining.ClaimedThroughAt = "not_a_number"
	local badResult, badReason = badType.Service.ClaimOfflineReward(7)
	equal(badResult, nil)
	equal(badReason, "InvalidOfflineTrainingState")

	local corruptedFocus = fixture({ LastSessionAt = 1000, Now = 1600 })
	corruptedFocus.Records[7].OfflineTraining.FocusSkillId = SkillIds.Mining
	local corruptedResult, corruptedReason = corruptedFocus.Service.ClaimOfflineReward(7)
	equal(corruptedResult, nil)
	equal(corruptedReason, "UnsupportedFocusSkillId")
	equal(corruptedFocus.Records[7].SkillXP[SkillIds.Mining], 0)
end)

test("malformed persisted station/plot state fails closed rather than awarding offline XP", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1600
	f.Records[7].Plot.Stations[MeleeStation] = { Tier = 99 }
	local result, reason = f.Service.ClaimOfflineReward(7)
	equal(result, nil)
	equal(reason, "InvalidStationState")
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 1000)
end)

test("returned results are copy-isolated from persisted state", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Clock.Now = 1600
	local result = assert(f.Service.ClaimOfflineReward(7))
	result.XPAwarded = 999999
	result.SkillState.XP = 999999
	local station = assert(f.Service.GetFocusStation(7))
	station.XPPerSecond = 999999
	assert(f.Records[7].SkillXP[SkillIds.Melee] ~= 999999)
	equal(StationDefinitions.ById[MeleeStation].Tiers[1].XPPerSecond, 1)
end)

-- Integration harness wired against the real PlayerData Store/Service (not the plain-table mock
-- above) so persistence and crash-recovery tests exercise the actual trusted transaction path.
local function newBackend()
	local f = { Time = 1000, Serial = 0, Records = {}, Failures = 0 }
	function f:UpdateAsync(key, transform)
		if self.Failures > 0 then
			self.Failures -= 1
			error("unavailable")
		end
		local info = { GetUserIds = function() return {} end, GetMetadata = function() return {} end }
		local value = transform(PlayerDataSchema.Copy(self.Records[key]), info)
		if value == nil then
			return nil
		end
		self.Records[key] = PlayerDataSchema.Copy(value)
		return PlayerDataSchema.Copy(value)
	end
	local backend = PlayerDataStore.New(f, {
		Now = function() return math.floor(f.Time) end,
		Sleep = function(seconds) f.Time += seconds end,
		NewToken = function() f.Serial += 1; return "token_" .. f.Serial end,
	})
	return f, backend
end

local function newServerProcess(backend, f)
	local function spawn(fn, ...)
		local thread = coroutine.create(fn)
		local ok, err = coroutine.resume(thread, ...)
		assert(ok, err)
		-- Anything that yields (the periodic autosave loop) is deliberately never resumed again:
		-- this fixture only needs synchronous join/update/persist behavior, and an abandoned,
		-- forever-parked autosave coroutine is exactly what models a crashed server process.
	end
	local function signal()
		local handlers = {}
		return {
			Connect = function(_, handler) table.insert(handlers, handler) end,
			Fire = function(_, ...) for _, handler in handlers do spawn(handler, ...) end end,
		}
	end
	local players = { List = {}, PlayerAdded = signal(), PlayerRemoving = signal() }
	function players:GetPlayers() return self.List end
	local runtime = {
		Players = players,
		Spawn = spawn,
		Wait = coroutine.yield,
		Clock = function() return f.Time end,
		Now = function() return math.floor(f.Time) end,
		BindToClose = function() end,
		Warn = function() end,
	}
	local service = PlayerDataService.New(backend, runtime)
	return service, players
end

local function fakePlayer(id)
	local p = { UserId = id, Kicked = false }
	function p:Kick() self.Kicked = true end
	return p
end

test("a durably-persisted offline claim survives a discarded live session; the reclaimed interval cannot be awarded twice", function()
	local f, backend = newBackend()

	-- Session A: selects a focus, has it durably confirmed, then the process is abandoned (crash) --
	-- never Released, never told PlayerRemoving. The durable record still carries an open lease.
	local serviceA, playersA = newServerProcess(backend, f)
	serviceA.Start()
	playersA.PlayerAdded:Fire(fakePlayer(7))
	local skillsA = Skills.New(serviceA, { Curves = { curve_standard = curve() } })
	local plotsA = Plots.New(serviceA, skillsA)
	local offlineA = OfflineTraining.New(serviceA, skillsA, plotsA, function() return f.Time end)
	assert(offlineA.SetFocus(7, SkillIds.Melee))
	assert(serviceA.Persist(7))
	equal(f.Records.player_7.Data.LastSessionAt, 1000)
	equal(f.Records.player_7.Data.OfflineTraining.FocusSkillId, SkillIds.Melee)

	f.Time += 1800 -- thirty minutes of real offline time pass while nothing is connected

	-- Session B: a fresh server process reloads the same durable record once the crashed lease
	-- has expired, without relying on any autosave or normal Release from session A.
	local serviceB, playersB = newServerProcess(backend, f)
	serviceB.Start()
	playersB.PlayerAdded:Fire(fakePlayer(7))
	assert(serviceB.GetSnapshot(7), "the expired crashed lease must not block a fresh load")
	local skillsB = Skills.New(serviceB, { Curves = { curve_standard = curve() } })
	local plotsB = Plots.New(serviceB, skillsB)
	local offlineB = OfflineTraining.New(serviceB, skillsB, plotsB, function() return f.Time end)

	equal(offlineB.GetFocus(7), SkillIds.Melee) -- the durably-confirmed focus survived the crash
	local claim = assert(offlineB.ClaimOfflineReward(7))
	assert(claim.Rewarded)
	equal(claim.RawElapsedSeconds, 1800)
	local expectedXP = StationDefinitions.ById[MeleeStation].Tiers[1].XPPerSecond * OfflineTrainingDefinitions.Configuration.EfficiencyMultiplier * 1800
	equal(claim.XPAwarded, expectedXP)
	equal(serviceB.GetSnapshot(7).SkillXP[SkillIds.Melee], expectedXP)
	equal(f.Records.player_7.Data.SkillXP[SkillIds.Melee], expectedXP) -- the award itself is durable
	equal(f.Records.player_7.Data.OfflineTraining.ClaimedThroughAt, f.Time)

	-- Reclaiming immediately in the same (still live) session B cannot award the original interval
	-- a second time: the ratchet the claim itself persisted already excludes it.
	local secondClaim = assert(offlineB.ClaimOfflineReward(7))
	equal(secondClaim.Rewarded, false)
	equal(secondClaim.Reason, "ElapsedBelowThreshold")
	equal(serviceB.GetSnapshot(7).SkillXP[SkillIds.Melee], expectedXP)
end)

test("a forced-save failure during a claim fails closed without losing or duplicating the in-memory award", function()
	local f, backend = newBackend()
	local service, players = newServerProcess(backend, f)
	service.Start()
	players.PlayerAdded:Fire(fakePlayer(7))
	local skills = Skills.New(service, { Curves = { curve_standard = curve() } })
	local plots = Plots.New(service, skills)
	local offline = OfflineTraining.New(service, skills, plots, function() return f.Time end)
	assert(offline.SetFocus(7, SkillIds.Melee))
	assert(service.Persist(7))
	f.Time += 90 -- comfortably above the claim threshold, comfortably below the session lease
	local claimedAt = f.Time -- captured before the retry sleeps below nudge the clock further

	f.Failures = PlayerDataStore.Attempts
	local claim = assert(offline.ClaimOfflineReward(7))
	equal(claim.Rewarded, false)
	equal(claim.Reason, "DataStoreUnavailable")
	local expectedXP = StationDefinitions.ById[MeleeStation].Tiers[1].XPPerSecond * OfflineTrainingDefinitions.Configuration.EfficiencyMultiplier * 90
	equal(claim.XPAwarded, expectedXP)
	equal(service.GetSnapshot(7).SkillXP[SkillIds.Melee], expectedXP) -- not lost in memory
	equal(service.GetSnapshot(7).OfflineTraining.ClaimedThroughAt, claimedAt)

	-- The same live session cannot duplicate the award while it waits to be confirmed durable.
	local retryClaim = assert(offline.ClaimOfflineReward(7))
	equal(retryClaim.Rewarded, false)
	equal(retryClaim.Reason, "ElapsedBelowThreshold")

	-- Once the DataStore recovers, the very same in-memory state (award and ratchet together)
	-- still reaches durable storage -- the failed forced persist silently dropped nothing.
	f.Failures = 0
	assert(service.Persist(7))
	equal(f.Records.player_7.Data.SkillXP[SkillIds.Melee], expectedXP)
	equal(f.Records.player_7.Data.OfflineTraining.ClaimedThroughAt, service.GetSnapshot(7).OfflineTraining.ClaimedThroughAt)
end)

print(("%d OfflineTraining checks passed"):format(passed))
