--!strict

local PlotSockets = require("PlotSockets")
local SkillIds = require("SkillIds")
local SkillDefinitions = require("SkillDefinitions")
local Skills = require("SkillsService")
local StationDefinitions = require("StationDefinitions")
local Plots = require("PlotsService")

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
	return { MaximumXP = 6000, Thresholds = thresholds }
end

local function fixture()
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
			ProgressionFlags = { flag_intro_complete = true },
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
		change(candidate)
		records[userId] = candidate
		return true, nil
	end
	local skills = Skills.New(playerData, { Curves = { curve_standard = curve() } })
	return { PlayerData = playerData, Records = records, Service = Plots.New(playerData, skills) }
end

test("fixed sockets and station definitions use stable IDs", function()
	local expectedSockets = {
		PlotSockets.Melee,
		PlotSockets.Defense,
		PlotSockets.Ranged,
		PlotSockets.Magic,
		PlotSockets.Forge,
		PlotSockets.Fletching,
		PlotSockets.Arcana,
	}
	local count = 0
	for _, socketId in expectedSockets do
		equal(PlotSockets.ById[socketId], true)
		count += 1
	end
	equal(count, 7)
	equal(StationDefinitions.ById[MeleeStation].SocketId, PlotSockets.Melee)
	equal(StationDefinitions.ById[MeleeStation].SkillId, SkillIds.Melee)
	equal(StationDefinitions.ById[DefenseStation].SocketId, PlotSockets.Defense)
	equal(StationDefinitions.ById[DefenseStation].SkillId, SkillIds.Defense)
end)

test("absent saved states resolve to tier one station defaults", function()
	local f = fixture()
	local melee = assert(f.Service.GetStation(7, MeleeStation))
	equal(melee.Tier, 1)
	equal(melee.XPPerSecond, 1)
	equal(melee.NextUpgradeCostGold, 100)
	local defense = assert(f.Service.GetStation(7, DefenseStation))
	equal(defense.Tier, 1)
	equal(defense.XPPerSecond, 1)
	equal(defense.NextUpgradeCostGold, 125)
	equal(next(f.Records[7].Plot.Stations), nil)
	local unowned, unownedReason = f.Service.GetStation(8, MeleeStation)
	equal(unowned, nil)
	equal(unownedReason, "NotReady")
end)

test("upgrades atomically debit Gold and preserve unrelated PlayerData", function()
	local f = fixture()
	local melee = assert(f.Service.UpgradeStation(7, MeleeStation))
	equal(melee.Tier, 2)
	equal(melee.XPPerSecond, 2)
	equal(f.Records[7].Gold, 900)
	equal(f.Records[7].Plot.Stations[MeleeStation].Tier, 2)
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	equal(f.Records[7].ProgressionFlags.flag_intro_complete, true)
	local defense = assert(f.Service.UpgradeStation(7, DefenseStation))
	equal(defense.Tier, 2)
	equal(f.Records[7].Gold, 775)
	equal(f.Records[7].Plot.Stations[DefenseStation].Tier, 2)
end)

test("invalid and maximum upgrades do not mutate Gold or station state", function()
	local f = fixture()
	for _, attempt in {
		function() return f.Service.UpgradeStation(0, MeleeStation) end,
		function() return f.Service.UpgradeStation(7, "station_unknown") end,
	} do
		local state, reason = attempt()
		equal(state, nil)
		assert(reason == "InvalidUserId" or reason == "InvalidStationId")
	end
	f.Records[7].Gold = 99
	local insufficient, insufficientReason = f.Service.UpgradeStation(7, MeleeStation)
	equal(insufficient, nil)
	equal(insufficientReason, "InsufficientGold")
	equal(f.Records[7].Gold, 99)
	equal(f.Records[7].Plot.Stations[MeleeStation], nil)
	f.Records[7].Gold = 1000
	assert(f.Service.UpgradeStation(7, MeleeStation))
	local maximum, maximumReason = f.Service.UpgradeStation(7, MeleeStation)
	equal(maximum, nil)
	equal(maximumReason, "MaximumTier")
	equal(f.Records[7].Gold, 900)
	equal(f.Records[7].Plot.Stations[MeleeStation].Tier, 2)
end)

test("invalid saved station state and PlayerData failures fail closed", function()
	local f = fixture()
	f.Records[7].Plot.Stations[MeleeStation] = { Tier = 99 }
	local invalid, invalidReason = f.Service.GetStation(7, MeleeStation)
	equal(invalid, nil)
	equal(invalidReason, "InvalidStationState")
	local noUpgrade, noUpgradeReason = f.Service.UpgradeStation(7, MeleeStation)
	equal(noUpgrade, nil)
	equal(noUpgradeReason, "InvalidStationState")
	f.Records[7].Plot.Stations[MeleeStation] = nil
	f.PlayerData.FailReason = "NotReady"
	local unavailable, unavailableReason = f.Service.UpgradeStation(7, MeleeStation)
	equal(unavailable, nil)
	equal(unavailableReason, "NotReady")
	equal(f.Records[7].Gold, 1000)
end)

test("rate-based training awards the configured station skill XP", function()
	local f = fixture()
	local melee = assert(f.Service.AwardTrainingForElapsed(7, MeleeStation, 3))
	equal(melee.SkillId, SkillIds.Melee)
	equal(melee.XP, 3)
	equal(f.Records[7].SkillXP[SkillIds.Melee], 3)
	assert(f.Service.UpgradeStation(7, DefenseStation))
	local defense = assert(f.Service.AwardTrainingForElapsed(7, DefenseStation, 3))
	equal(defense.SkillId, SkillIds.Defense)
	equal(defense.XP, 6)
	equal(f.Records[7].SkillXP[SkillIds.Defense], 6)
	equal(f.Records[7].Gold, 875)
end)

test("training rejects invalid elapsed time and unavailable station state", function()
	local f = fixture()
	for _, attempt in {
		function() return f.Service.AwardTrainingForElapsed(0, MeleeStation, 1) end,
		function() return f.Service.AwardTrainingForElapsed(7, "station_unknown", 1) end,
		function() return f.Service.AwardTrainingForElapsed(7, MeleeStation, 0) end,
		function() return f.Service.AwardTrainingForElapsed(7, MeleeStation, -1) end,
		function() return f.Service.AwardTrainingForElapsed(7, MeleeStation, 0 / 0) end,
		function() return f.Service.AwardTrainingForElapsed(7, MeleeStation, Plots.MaximumElapsedSeconds + 1) end,
	} do
		local state, reason = attempt()
		equal(state, nil)
		assert(reason == "InvalidUserId" or reason == "InvalidStationId" or reason == "InvalidElapsedSeconds")
	end
	f.Records[7].Plot.Stations[DefenseStation] = { Tier = 99 }
	local invalid, invalidReason = f.Service.AwardTrainingForElapsed(7, DefenseStation, 1)
	equal(invalid, nil)
	equal(invalidReason, "InvalidStationState")
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	equal(f.Records[7].SkillXP[SkillIds.Defense], 0)
end)

print(("%d Plot/Training checks passed"):format(passed))
