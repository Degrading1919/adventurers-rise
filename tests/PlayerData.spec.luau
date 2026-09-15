--!strict

local Schema = require("Schema")
local Migrations = require("Migrations")
local Store = require("Store")
local Service = require("Service")
local SkillIds = require("SkillIds")

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

-- Models callback retries, metadata, failures before commit, and lost responses.
local function fixture()
	local f = { Time = 1000, Serial = 0, Calls = 0, Failures = 0, LostResponses = 0, Records = {}, Ids = {}, Metadata = {} }
	function f:UpdateAsync(key, transform)
		self.Calls += 1
		if self.Before then self.Before(self, key) end
		if self.Failures > 0 then
			self.Failures -= 1
			error("unavailable")
		end
		local info = {
			GetUserIds = function() return Schema.Copy(self.Ids[key] or {}) end,
			GetMetadata = function() return Schema.Copy(self.Metadata[key] or {}) end,
		}
		local value, ids, metadata = transform(Schema.Copy(self.Records[key]), info)
		if self.Compete then
			local compete = self.Compete
			self.Compete = nil
			compete(self, key)
			value, ids, metadata = transform(Schema.Copy(self.Records[key]), info)
		end
		if value == nil then return nil end
		self.Records[key], self.Ids[key], self.Metadata[key] = Schema.Copy(value), ids, metadata
		if self.LostResponses > 0 then
			self.LostResponses -= 1
			error("response lost after commit")
		end
		if self.After then self.After(self, key) end
		return Schema.Copy(value)
	end
	f.Store = Store.New(f, {
		Now = function() return math.floor(f.Time) end,
		Sleep = function(seconds) f.Time += seconds end,
		NewToken = function() f.Serial += 1; return "token_" .. f.Serial end,
	})
	return f
end

local function versionOneData()
	local data = Schema.New()
	data.SchemaVersion = 1
	data.Inventory = {}
	data.MasteryRespecs = nil
	return data
end

test("fresh v3 defaults have stable IDs, independent containers, and no derived levels", function()
	local a, b = Schema.New(), Schema.New()
	assert(Schema.Validate(a))
	equal(a.SchemaVersion, 3)
	equal(a.Gold, 0)
	equal(a.LastSessionAt, 0)
	equal(a.Ascension.RankId, "ascension_adventurer")
	local count = 0
	for name, id in SkillIds do
		equal(id, "skill_" .. string.lower(name))
		equal(a.SkillXP[id], 0)
		a.MasterySelections[id].test_node = true
		equal(next(b.MasterySelections[id]), nil)
		equal(a.MasteryRespecs[id], false)
		a.MasteryRespecs[id] = true
		equal(b.MasteryRespecs[id], false)
		count += 1
	end
	equal(count, 4)
	a.Inventory.Items.test_instance = { DefinitionId = "test_definition" }
	a.Plot.Stations.test_station = { Tier = 1 }
	a.Ascension.Flags.test_flag = true
	equal(next(b.Inventory.Stacks), nil)
	equal(next(b.Inventory.Items), nil)
	equal(next(b.Plot.Stations), nil)
	equal(next(b.Ascension.Flags), nil)
	a.SkillLevels = {}
	assert(not Schema.Validate(a))
end)

test("schema rejects malformed and non-serializable saves", function()
	for _, mutate in {
		function(d) d.Gold = -1 end,
		function(d) d.SkillXP.skill_melee = 0 / 0 end,
		function(d) d.SkillXP.skill_melee = math.huge end,
		function(d) d.SkillXP.Melee = 1 end,
		function(d) d.LastSessionAt = 1.5 end,
		function(d) d.Inventory.self = d.Inventory end,
		function(d) d.Inventory.fn = function() end end,
		function(d) d.Inventory.list = { 1 } end,
		function(d) d.Inventory.invalid = string.char(255) end,
		function(d) setmetatable(d.Inventory, {}) end,
		function(d) d.MasterySelections.skill_melee.test_node = 2 end,
		function(d) d.MasteryRespecs.skill_melee = "yes" end,
		function(d) d.MasteryRespecs.skill_unknown = true end,
		function(d) d.Plot.Stations.test_station = false end,
	} do
		local data = Schema.New()
		mutate(data)
		assert(not Schema.Validate(data))
	end
end)

test("migrations run sequentially without mutating stored input", function()
	local raw = versionOneData()
	local migrated = assert(Migrations.Run(raw, 3, {
		[1] = function(d) d.Gold = 12; d.SchemaVersion = 2; return d end,
		[2] = function(d) equal(d.Gold, 12); d.Gold += 3; d.SchemaVersion = 3; return d end,
	}))
	equal(migrated.Gold, 15)
	equal(migrated.SchemaVersion, 3)
	equal(raw.Gold, 0)
	equal(raw.SchemaVersion, 1)
end)

test("missing, invalid, unversioned, and future migrations fail closed", function()
	local target = Schema.Version + 1
	local _, reason = Migrations.Run(Schema.New(), target, {})
	equal(reason, "MissingMigration")
	for _, step in {
		function() error("bad migration") end,
		function(d) return d end,
		function(d) d.SchemaVersion = target + 1; return d end,
	} do
		local _, failure = Migrations.Run(Schema.New(), target, { [Schema.Version] = step })
		equal(failure, "InvalidMigration")
	end
	local _, missing = Migrations.ToCurrent({ Gold = 20 })
	equal(missing, "InvalidVersion")
	local data = Schema.New()
	data.SchemaVersion = Schema.Version + 1
	local _, future = Migrations.ToCurrent(data)
	equal(future, "FutureVersion")
end)

test("real v1 to current migration creates explicit inventory containers and Mastery respec history", function()
	local raw = versionOneData()
	raw.Gold = 50
	local migrated = assert(Migrations.ToCurrent(raw))
	equal(migrated.SchemaVersion, 3)
	equal(migrated.Gold, 50)
	equal(next(migrated.Inventory.Stacks), nil)
	equal(next(migrated.Inventory.Items), nil)
	-- The v2 -> v3 migration must produce exactly the four skill IDs that existed when schema v3
	-- was created, as literal historical constants -- never derived from the live SkillIds module
	-- (which would silently change this migration's output whenever a skill is added later).
	equal(migrated.MasteryRespecs.skill_melee, false)
	equal(migrated.MasteryRespecs.skill_defense, false)
	equal(migrated.MasteryRespecs.skill_mining, false)
	equal(migrated.MasteryRespecs.skill_smithing, false)
	local historicalKeyCount = 0
	for _ in migrated.MasteryRespecs do
		historicalKeyCount += 1
	end
	equal(historicalKeyCount, 4)
	equal(raw.SchemaVersion, 1)
	equal(next(raw.Inventory), nil)
	equal(raw.MasteryRespecs, nil)
	local f = fixture()
	f.Records.player_7 = { Data = raw }
	local session = assert(f.Store.Load(7))
	equal(session.Data.SchemaVersion, 3)
	equal(f.Records.player_7.Data.SchemaVersion, 3)
	assert(Schema.Validate(f.Records.player_7.Data))
end)

test("ambiguous non-empty v1 inventory is never discarded during migration", function()
	local raw = versionOneData()
	raw.Inventory.legacy_item = { DefinitionId = "unknown" }
	local migrated, reason = Migrations.ToCurrent(raw)
	equal(migrated, nil)
	equal(reason, "InvalidMigration")
	local f = fixture()
	f.Records.player_7 = { Data = raw }
	equal(f.Store.Load(7), nil)
	equal(f.Records.player_7.Data.Inventory.legacy_item.DefinitionId, "unknown")
end)

test("new load, checkpoint, release, and rejoin preserve all requested state", function()
	local f = fixture()
	local session = assert(f.Store.Load(7))
	local data = session.Data
	data.Gold = 50
	data.SkillXP.skill_mining = 12.5
	data.Ascension = { RankId = "ascension_adept", Flags = { test_flag = true } }
	data.Inventory.Items.test_instance = { DefinitionId = "test_definition" }
	data.Equipment.test_slot = "test_item"
	data.Plot.Stations.test_station = { Tier = 1 }
	data.ProgressionFlags.test_flag = true
	data.MasterySelections.skill_melee.test_node = true
	f.Time += 20
	assert(f.Store.Save(session))
	equal(session.Data.LastSessionAt, 1020)
	f.Time += 10
	assert(f.Store.Release(session))
	equal(f.Records.player_7.Session, nil)
	local loaded = assert(f.Store.Load(7)).Data
	equal(loaded.Gold, 50)
	equal(loaded.SkillXP.skill_mining, 12.5)
	equal(loaded.Ascension.RankId, "ascension_adept")
	assert(loaded.Ascension.Flags.test_flag)
	equal(loaded.Inventory.Items.test_instance.DefinitionId, "test_definition")
	equal(loaded.Equipment.test_slot, "test_item")
	equal(loaded.Plot.Stations.test_station.Tier, 1)
	assert(loaded.ProgressionFlags.test_flag and loaded.MasterySelections.skill_melee.test_node)
	equal(loaded.LastSessionAt, 1030)
end)

test("metadata and user ID associations survive updates", function()
	local f = fixture()
	f.Metadata.player_7, f.Ids.player_7 = { audit = "keep" }, { 8 }
	local session = assert(f.Store.Load(7))
	assert(f.Store.Release(session))
	equal(f.Metadata.player_7.audit, "keep")
	equal(#f.Ids.player_7, 2)
	assert(table.find(f.Ids.player_7, 7) and table.find(f.Ids.player_7, 8))
end)

test("maximum supported data nesting survives the transport envelope", function()
	local f = fixture()
	local session = assert(f.Store.Load(7))
	session.Data.Plot.Stations.test_station = {}
	local current = session.Data.Plot.Stations.test_station
	for _ = 4, Schema.MaxDepth do
		current.child = {}
		current = current.child
	end
	current.value = true
	assert(Schema.Validate(session.Data))
	assert(f.Store.Release(session))
	assert(f.Store.Load(7))
	current.child = {}
	assert(not Schema.Validate(session.Data))
end)

test("failed loads never create defaults or authorize a session", function()
	local f = fixture()
	f.Failures = 3
	local session, reason = f.Store.Load(7)
	equal(session, nil)
	equal(reason, "DataStoreUnavailable")
	equal(f.Calls, 3)
	equal(f.Records.player_7, nil)
	equal(f.Store.Load(-1), nil)
end)

test("malformed and newer stored records are untouched", function()
	for _, raw in { {}, { SchemaVersion = 1 }, Schema.New() } do
		local f = fixture()
		if raw.Gold then raw.SchemaVersion = Schema.Version + 1 end
		f.Records.player_7 = { Data = raw }
		local before = f.Records.player_7
		equal(f.Store.Load(7), nil)
		equal(f.Records.player_7, before)
	end
end)

test("active session locks reject a second owner; expired owners cannot overwrite", function()
	local f = fixture()
	local first = assert(f.Store.Load(7))
	local _, reason = f.Store.Load(7)
	equal(reason, "SessionLocked")
	f.Time = first.ExpiresAt
	local second = assert(f.Store.Load(7))
	first.Data.Gold = 999
	local ok, lost = f.Store.Save(first)
	assert(not ok)
	equal(lost, "SessionLost")
	equal(f.Records.player_7.Session.Token, second.Token)
	equal(f.Records.player_7.Data.Gold, 0)
end)

test("callback retry respects the competing lock, not its discarded candidate", function()
	local f = fixture()
	f.Compete = function(self, key)
		self.Records[key] = { Data = Schema.New(), Session = { Token = "other", ExpiresAt = 2000 } }
	end
	local session, reason = f.Store.Load(7)
	equal(session, nil)
	equal(reason, "SessionLocked")
	equal(f.Records.player_7.Session.Token, "other")
end)

test("load and final release tolerate lost success responses", function()
	local f = fixture()
	f.LostResponses = 1
	local session = assert(f.Store.Load(7))
	session.Data.Gold = 42
	f.LostResponses = 1
	assert(f.Store.Release(session))
	equal(f.Records.player_7.Data.Gold, 42)
	equal(f.Records.player_7.Session, nil)
	assert(session.Closed)
end)

test("release retry cannot overwrite a player who has already rejoined", function()
	local f = fixture()
	local first = assert(f.Store.Load(7))
	f.LostResponses = 1
	f.Before = function(self, key)
		if self.Records[key].Session == nil then
			self.Before = nil
			local second = assert(self.Store.Load(7))
			second.Data.Gold = 100
			assert(self.Store.Save(second))
		end
	end
	local ok, reason = f.Store.Release(first)
	assert(not ok)
	equal(reason, "SessionLost")
	equal(f.Records.player_7.Data.Gold, 100)
end)

test("save failure retains dirty data and a valid lease for a later retry", function()
	local f = fixture()
	local session = assert(f.Store.Load(7))
	session.Data.Gold = 42
	f.Failures = 3
	local ok, reason = f.Store.Save(session)
	assert(not ok and not session.Closed)
	equal(reason, "DataStoreUnavailable")
	equal(session.Data.Gold, 42)
	equal(session.Data.LastSessionAt, 0)
	equal(f.Records.player_7.Data.Gold, 0)
	assert(f.Store.Save(session))
	equal(f.Records.player_7.Data.Gold, 42)
end)

test("busy saves serialize and server edits made during a save survive", function()
	local f = fixture()
	local session = assert(f.Store.Load(7))
	f.Before = function(self)
		self.Before = nil
		local ok, reason = self.Store.Release(session)
		assert(not ok)
		equal(reason, "SessionBusy")
		session.Data.Gold = 88
	end
	assert(f.Store.Save(session))
	equal(f.Records.player_7.Data.Gold, 0)
	equal(session.Data.Gold, 88)
	assert(f.Store.Release(session))
	equal(f.Records.player_7.Data.Gold, 88)
end)

test("slow responses cannot expose an expired session", function()
	local f = fixture()
	f.After = function(self) self.Time += Store.LeaseSeconds end
	local session, reason = f.Store.Load(7)
	equal(session, nil)
	equal(reason, "SessionLost")
	f.After = nil
	local loaded = assert(f.Store.Load(7))
	f.After = function(self) self.Time += Store.LeaseSeconds end
	local ok, lost = f.Store.Save(loaded)
	assert(not ok and loaded.Closed)
	equal(lost, "SessionLost")
end)

-- Deterministic cooperative scheduler for real join/leave/autosave/shutdown code.
local function lifecycle()
	local f = fixture()
	local queue, warnings = {}, {}
	local elapsed = 0
	local function spawn(fn, ...)
		local thread = coroutine.create(fn)
		local ok, delay = coroutine.resume(thread, ...)
		assert(ok, delay)
		if coroutine.status(thread) ~= "dead" then
			table.insert(queue, { Thread = thread, At = elapsed + delay })
		end
	end
	local function advance(seconds)
		local target = elapsed + seconds
		while true do
			table.sort(queue, function(a, b) return a.At < b.At end)
			if #queue == 0 or queue[1].At > target then break end
			local entry = table.remove(queue, 1)
			f.Time += entry.At - elapsed
			elapsed = entry.At
			local ok, delay = coroutine.resume(entry.Thread)
			assert(ok, delay)
			if coroutine.status(entry.Thread) ~= "dead" then
				table.insert(queue, { Thread = entry.Thread, At = elapsed + delay })
			end
		end
		f.Time += target - elapsed
		elapsed = target
	end
	local function signal()
		local handlers = {}
		return {
			Connect = function(_, handler) table.insert(handlers, handler) end,
			Fire = function(_, ...) for _, handler in handlers do spawn(handler, ...) end end,
		}
	end
	local players = { PlayerAdded = signal(), PlayerRemoving = signal(), List = {} }
	function players:GetPlayers() return self.List end
	local shutdown
	local service = Service.New(f.Store, {
		Players = players, Spawn = spawn, Wait = coroutine.yield,
		Clock = function() return elapsed end, Now = function() return math.floor(f.Time) end,
		BindToClose = function(callback) shutdown = callback end,
		Warn = function(message) table.insert(warnings, message) end,
	})
	local function player(id)
		local p = { UserId = id, Kicked = false }
		function p:Kick() self.Kicked = true end
		return p
	end
	return { Data = f, Players = players, Service = service, Player = player, Advance = advance,
		Shutdown = function() spawn(shutdown) end, Warnings = warnings }
end

test("service loads existing and joining players, gates access, and isolates mutations", function()
	local f = lifecycle()
	f.Players.List = { f.Player(7) }
	equal(f.Service.GetSnapshot(7), nil)
	f.Service.Start()
	assert(f.Service.GetSnapshot(7))
	local snapshot = f.Service.GetSnapshot(7)
	snapshot.Gold = 900
	equal(f.Service.GetSnapshot(7).Gold, 0)
	local retained
	assert(f.Service.Update(7, function(data) data.Gold = 20; retained = data end))
	retained.Gold = 300
	equal(f.Service.GetSnapshot(7).Gold, 20)
	assert(not f.Service.Update(7, function(data) data.Gold = -1 end))
	assert(not f.Service.Update(7, function(data) data.LastSessionAt = 1 end))
	assert(not f.Service.Update(7, function() coroutine.yield(1) end))
	assert(not f.Service.Update(7, function() error("bad mutation") end))
	equal(f.Service.GetSnapshot(7).Gold, 20)
	f.Players.PlayerAdded:Fire(f.Player(8))
	assert(f.Service.GetSnapshot(8))
	assert(not pcall(f.Service.Start))
end)

test("failed service loads kick without a usable default profile", function()
	local f = lifecycle()
	f.Data.Failures = 3
	f.Service.Start()
	local p = f.Player(7)
	f.Players.PlayerAdded:Fire(p)
	assert(p.Kicked)
	equal(f.Service.GetSnapshot(7), nil)
	assert(not f.Service.Update(7, function() error("must not run") end))
	equal(f.Data.Records.player_7, nil)
end)

test("leave during load releases the acquired session without exposing it", function()
	local f = lifecycle()
	f.Data.Before = function(self) self.Before = nil; coroutine.yield(1) end
	f.Service.Start()
	local p = f.Player(7)
	f.Players.PlayerAdded:Fire(p)
	f.Players.PlayerRemoving:Fire(p)
	equal(f.Service.GetSnapshot(7), nil)
	f.Advance(1)
	equal(f.Service.GetSnapshot(7), nil)
	equal(f.Data.Records.player_7.Session, nil)
end)

test("leave waits for an in-flight autosave and persists the final server edit", function()
	local f = lifecycle()
	f.Service.Start()
	local p = f.Player(7)
	f.Players.PlayerAdded:Fire(p)
	f.Data.Before = function(self) self.Before = nil; coroutine.yield(2) end
	f.Advance(60)
	assert(f.Service.Update(7, function(data) data.Gold = 99 end))
	f.Players.PlayerRemoving:Fire(p)
	equal(f.Service.GetSnapshot(7), nil)
	f.Advance(3)
	equal(f.Data.Records.player_7.Data.Gold, 99)
	equal(f.Data.Records.player_7.Session, nil)
end)

test("autosave renews leases; loss of ownership gates access and kicks", function()
	local f = lifecycle()
	f.Service.Start()
	local p = f.Player(7)
	f.Players.PlayerAdded:Fire(p)
	local expiry = f.Data.Records.player_7.Session.ExpiresAt
	f.Advance(60)
	assert(f.Data.Records.player_7.Session.ExpiresAt > expiry)
	f.Data.Records.player_7.Session.Token = "other"
	f.Advance(60)
	assert(p.Kicked)
	equal(f.Service.GetSnapshot(7), nil)
end)

test("shutdown handles loaded and loading players and rejects new joins", function()
	local f = lifecycle()
	f.Service.Start()
	f.Players.PlayerAdded:Fire(f.Player(7))
	f.Data.Before = function(self) self.Before = nil; coroutine.yield(1) end
	f.Players.PlayerAdded:Fire(f.Player(8))
	f.Shutdown()
	equal(f.Service.GetSnapshot(7), nil)
	local late = f.Player(9)
	f.Players.PlayerAdded:Fire(late)
	assert(late.Kicked)
	f.Advance(2)
	equal(f.Data.Records.player_7.Session, nil)
	equal(f.Data.Records.player_8.Session, nil)
	equal(#f.Warnings, 0)
end)

test("shutdown waits are bounded when a DataStore request stalls", function()
	local f = lifecycle()
	f.Service.Start()
	f.Data.Before = function() coroutine.yield(100) end
	f.Players.PlayerAdded:Fire(f.Player(7))
	f.Shutdown()
	f.Advance(26)
	assert(string.find(f.Warnings[#f.Warnings], "Shutdown deadline", 1, true))
end)

print(("%d PlayerData checks passed"):format(passed))
