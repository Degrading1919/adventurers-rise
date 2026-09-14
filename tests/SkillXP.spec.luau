--!strict

local SkillIds = require("SkillIds")
local Definitions = require("Definitions")
local Skills = require("Service")

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

local function curve(maximumXP)
	local thresholds = {}
	for level = 1, Definitions.LevelCap do
		thresholds[level] = (level - 1) * 100
	end
	return { MaximumXP = maximumXP or 6000, Thresholds = thresholds }
end

local function fixture(data)
	local records = { [7] = data or { Gold = 25, SkillXP = {
		[SkillIds.Melee] = 0,
		[SkillIds.Defense] = 0,
		[SkillIds.Mining] = 0,
		[SkillIds.Smithing] = 0,
	} } }
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
	local service = Skills.New(playerData, { Curves = { curve_standard = curve() } })
	return { PlayerData = playerData, Records = records, Service = service }
end

test("definitions describe only the slice skills and a level cap of 60", function()
	equal(Definitions.LevelCap, 60)
	local count = 0
	for _, id in SkillIds do
		local definition = Definitions.ById[id]
		assert(definition)
		equal(definition.Id, id)
		equal(definition.CurveId, "curve_standard")
		count += 1
	end
	equal(count, 4)
end)

test("levels are derived from synthetic thresholds at exact boundaries", function()
	local f = fixture()
	local function state(xp)
		f.Records[7].SkillXP[SkillIds.Melee] = xp
		return assert(f.Service.GetState(7, SkillIds.Melee))
	end
	local first = state(0)
	equal(first.Level, 1)
	equal(first.XPAtLevel, 0)
	equal(first.XPForNextLevel, 100)
	equal(state(99).Level, 1)
	equal(state(100).Level, 2)
	equal(state(5899).Level, 59)
	local cap = state(5900)
	equal(cap.Level, 60)
	equal(cap.XPAtLevel, 5900)
	equal(cap.XPForNextLevel, nil)
	equal(state(6000).Level, 60)
	assert(state(6000).Level ~= nil)
	assert(f.Records[7].SkillXP[SkillIds.Melee] == 6000) -- No level field was introduced.
end)

test("awards update only persisted XP through PlayerData and return derived state", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Mining] = 50
	local before = copy(f.Records[7])
	local state = assert(f.Service.AwardXP(7, SkillIds.Mining, 50))
	equal(state.SkillId, SkillIds.Mining)
	equal(state.XP, 100)
	equal(state.Level, 2)
	equal(f.PlayerData.Calls, 1)
	equal(f.Records[7].SkillXP[SkillIds.Mining], 100)
	equal(f.Records[7].Gold, before.Gold)
	equal(f.Records[7].SkillXP[SkillIds.Melee], before.SkillXP[SkillIds.Melee])
	assert(f.Records[7].SkillLevel == nil)
end)

test("invalid IDs, user IDs, and XP amounts are rejected before PlayerData mutation", function()
	local f = fixture()
	for _, attempt in {
		function() return f.Service.GetState(7, "Melee") end,
		function() return f.Service.AwardXP(7, "skill_unknown", 1) end,
		function() return f.Service.AwardXP(0, SkillIds.Melee, 1) end,
		function() return f.Service.AwardXP(7, SkillIds.Melee, 0) end,
		function() return f.Service.AwardXP(7, SkillIds.Melee, -1) end,
		function() return f.Service.AwardXP(7, SkillIds.Melee, 0 / 0) end,
		function() return f.Service.AwardXP(7, SkillIds.Melee, math.huge) end,
	} do
		local state, reason = attempt()
		equal(state, nil)
		assert(reason == "InvalidSkillId" or reason == "InvalidUserId" or reason == "InvalidXPAmount")
	end
	equal(f.PlayerData.Calls, 0)
end)

test("configured XP maximum rejects excessive awards and invalid stored XP", function()
	local f = fixture()
	f.Records[7].SkillXP[SkillIds.Defense] = 6000
	local state, reason = f.Service.AwardXP(7, SkillIds.Defense, 1)
	equal(state, nil)
	equal(reason, "XPOutOfBounds")
	equal(f.Records[7].SkillXP[SkillIds.Defense], 6000)
	f.Records[7].SkillXP[SkillIds.Defense] = 6001
	local invalid, invalidReason = f.Service.GetState(7, SkillIds.Defense)
	equal(invalid, nil)
	equal(invalidReason, "XPOutOfBounds")
	local award, awardReason = f.Service.AwardXP(7, SkillIds.Defense, 1)
	equal(award, nil)
	equal(awardReason, "XPOutOfBounds")
	equal(f.Records[7].SkillXP[SkillIds.Defense], 6001)
end)

test("PlayerData availability and mutation failures preserve persistent state", function()
	local f = fixture()
	f.PlayerData.FailReason = "NotReady"
	local state, reason = f.Service.AwardXP(7, SkillIds.Smithing, 10)
	equal(state, nil)
	equal(reason, "NotReady")
	equal(f.Records[7].SkillXP[SkillIds.Smithing], 0)
	local missing, missingReason = f.Service.GetState(8, SkillIds.Smithing)
	equal(missing, nil)
	equal(missingReason, "NotReady")
end)

test("invalid curve definitions fail during server composition", function()
	local playerData = fixture().PlayerData
	local missing = curve()
	missing.Thresholds[60] = nil
	assert(not pcall(Skills.New, playerData, { Curves = { curve_standard = missing } }))
	local nonIncreasing = curve()
	nonIncreasing.Thresholds[2] = 0
	assert(not pcall(Skills.New, playerData, { Curves = { curve_standard = nonIncreasing } }))
	local tooLow = curve(5899)
	assert(not pcall(Skills.New, playerData, { Curves = { curve_standard = tooLow } }))
end)

test("service snapshots its configured thresholds", function()
	local f = fixture()
	local configured = curve()
	local service = Skills.New(f.PlayerData, { Curves = { curve_standard = configured } })
	configured.MaximumXP = 0
	configured.Thresholds[2] = 0
	local state = assert(service.AwardXP(7, SkillIds.Melee, 100))
	equal(state.Level, 2)
end)

print(("%d Skill/XP checks passed"):format(passed))
