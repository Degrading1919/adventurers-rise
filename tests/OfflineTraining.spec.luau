--!strict

local SkillIds = require("SkillIds")
local SkillDefinitions = require("SkillDefinitions")
local Skills = require("SkillsService")
local StationDefinitions = require("StationDefinitions")
local Plots = require("PlotsService")
local OfflineTrainingDefinitions = require("OfflineTrainingDefinitions")
local OfflineTraining = require("OfflineTrainingService")

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
	local playerData = { Calls = 0, FailReason = nil }
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
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 0)
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
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.Rewarded, false)
	equal(result.Reason, "FutureSessionTimestamp")
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 0)
end)

test("offline training correctly awards Melee XP at the configured efficiency, strictly below active", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1600 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
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
	local f = fixture({ LastSessionAt = 2000, Now = 2900 })
	assert(f.Plots.UpgradeStation(7, DefenseStation))
	assert(f.Service.SetFocus(7, SkillIds.Defense))
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
	local f = fixture({ LastSessionAt = 1000, Now = 1061 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	local result = assert(f.Service.ClaimOfflineReward(7))
	equal(result.RawElapsedSeconds, 61)
	local expectedXP = StationDefinitions.ById[MeleeStation].Tiers[1].XPPerSecond * OfflineTrainingDefinitions.Configuration.EfficiencyMultiplier * 61
	equal(expectedXP, 15.25)
	equal(result.XPAwarded, 15.25)
	equal(f.Records[7].SkillXP[SkillIds.Melee], 15.25)
end)

test("elapsed time above the offline cap is credited only up to the cap", function()
	local cap = OfflineTrainingDefinitions.Configuration.MaximumOfflineSeconds
	local f = fixture({ LastSessionAt = 1000, Now = 1000 + cap + 100000 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
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
	local f = fixture({ LastSessionAt = 1000, Now = 1600 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
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
	local f = fixture({ LastSessionAt = 1000, Now = 1600 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
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
	local f = fixture({ LastSessionAt = 1000, Now = 1600 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
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
	local f = fixture({ LastSessionAt = 1000, Now = 1600 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.PlayerData.FailReason = "SimulatedFailure"
	local result, reason = f.Service.ClaimOfflineReward(7)
	equal(result, nil)
	equal(reason, "SimulatedFailure")
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 0)
	f.PlayerData.FailReason = nil
	local retried = assert(f.Service.ClaimOfflineReward(7))
	assert(retried.Rewarded)
end)

test("focus and claim state persist across a simulated leave and rejoin", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1600 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
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
	local f = fixture({ LastSessionAt = 1000, Now = 1600 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	f.Records[7].Plot.Stations[MeleeStation] = { Tier = 99 }
	local result, reason = f.Service.ClaimOfflineReward(7)
	equal(result, nil)
	equal(reason, "InvalidStationState")
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	equal(f.Records[7].OfflineTraining.ClaimedThroughAt, 0)
end)

test("returned results are copy-isolated from persisted state", function()
	local f = fixture({ LastSessionAt = 1000, Now = 1600 })
	assert(f.Service.SetFocus(7, SkillIds.Melee))
	local result = assert(f.Service.ClaimOfflineReward(7))
	result.XPAwarded = 999999
	result.SkillState.XP = 999999
	local station = assert(f.Service.GetFocusStation(7))
	station.XPPerSecond = 999999
	assert(f.Records[7].SkillXP[SkillIds.Melee] ~= 999999)
	equal(StationDefinitions.ById[MeleeStation].Tiers[1].XPPerSecond, 1)
end)

print(("%d OfflineTraining checks passed"):format(passed))
