--!strict

local EnemyCombat = require("EnemyCombatService")
local EnemyDefinitions = require("EnemyDefinitions")
local EnemyIds = require("EnemyIds")
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

-- Sanity: the real definitions supply the aggression deltas this system reads.
equal(EnemyDefinitions.ById[EnemyIds.Goblin].Aggression.MinimumEnemyLevelDelta, -2)
equal(EnemyDefinitions.ById[EnemyIds.GoblinChieftain].Aggression.MinimumEnemyLevelDelta, -8)

local function fakeHealth(config)
	local calls = { apply = {}, reset = {} }
	local service = {
		IsAlive = function(_userId)
			return config.alive ~= false
		end,
		ApplyDamage = function(userId, amount)
			table.insert(calls.apply, { userId = userId, amount = amount })
			if config.result then
				return config.result, nil
			end
			return nil, config.reason or "Failed"
		end,
		Reset = function(userId)
			table.insert(calls.reset, userId)
			return { Health = 100, MaxHealth = 100 }, nil
		end,
	}
	return service, calls
end

local function fakeSkills(config)
	local awards = {}
	local service = {
		GetState = function(_userId, skillId)
			local level = config.levels[skillId]
			if level == nil then
				return nil, "SkillMissing"
			end
			return { Level = level }, nil
		end,
		AwardXP = function(userId, skillId, amount)
			table.insert(awards, { userId = userId, skillId = skillId, amount = amount })
			if config.failXP then
				return nil, "XPFailed"
			end
			return { Level = 1 }, nil
		end,
	}
	return service, awards
end

local CONFIG = { DefenseXPPerHit = 2, ProgressionSkillId = SkillIds.Melee }

test("an aggressive enemy applies its authoritative Damage and awards Defense XP", function()
	local health, healthCalls = fakeHealth({ alive = true, result = { Health = 92, MaxHealth = 100, Died = false } })
	local skills, awards = fakeSkills({ levels = { [SkillIds.Melee] = 1, [SkillIds.Defense] = 1 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	local result = assert(ec.ResolveAttack(7, { DefinitionId = EnemyIds.Goblin, Level = 8, Damage = 8 }))
	equal(result.Damage, 8)
	equal(result.Health, 92)
	equal(result.Died, false)
	equal(result.DefenseXP, 2)
	equal(result.DefenseXPAwarded, true)
	equal(#healthCalls.apply, 1)
	equal(healthCalls.apply[1].amount, 8)
	equal(#awards, 1)
	equal(awards[1].skillId, SkillIds.Defense)
	equal(awards[1].amount, 2)
end)

test("a much stronger player is not aggroed: no damage, no Defense XP", function()
	local health, healthCalls = fakeHealth({ alive = true, result = { Health = 92, MaxHealth = 100, Died = false } })
	local skills, awards = fakeSkills({ levels = { [SkillIds.Melee] = 20, [SkillIds.Defense] = 1 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	local result, reason = ec.ResolveAttack(7, { DefinitionId = EnemyIds.Goblin, Level = 3, Damage = 6 })
	equal(result, nil)
	equal(reason, "NotAggressive")
	equal(#healthCalls.apply, 0)
	equal(#awards, 0)
end)

test("a dead target is never attacked", function()
	local health, healthCalls = fakeHealth({ alive = false })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 1, [SkillIds.Defense] = 1 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	local result, reason = ec.ResolveAttack(7, { DefinitionId = EnemyIds.Goblin, Level = 8, Damage = 8 })
	equal(result, nil)
	equal(reason, "TargetNotAlive")
	equal(#healthCalls.apply, 0)
end)

test("the Chieftain is dangerous even to a strong player and uses its higher Damage", function()
	local health, healthCalls = fakeHealth({ alive = true, result = { Health = 80, MaxHealth = 100, Died = false } })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 8, [SkillIds.Defense] = 5 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	-- delta -8: 10 - 8 = 2 >= -8 -> aggressive despite the strong player.
	local result = assert(ec.ResolveAttack(7, { DefinitionId = EnemyIds.GoblinChieftain, Level = 10, Damage = 20 }))
	equal(result.Damage, 20)
	equal(healthCalls.apply[1].amount, 20)
end)

test("a lethal hit is reported as Died", function()
	local health = fakeHealth({ alive = true, result = { Health = 0, MaxHealth = 100, Died = true } })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 1, [SkillIds.Defense] = 1 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	local result = assert(ec.ResolveAttack(7, { DefinitionId = EnemyIds.Goblin, Level = 8, Damage = 8 }))
	equal(result.Died, true)
end)

test("a Defense XP failure does not undo the landed hit", function()
	local health, healthCalls = fakeHealth({ alive = true, result = { Health = 92, MaxHealth = 100, Died = false } })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 1, [SkillIds.Defense] = 1 }, failXP = true })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	local result = assert(ec.ResolveAttack(7, { DefinitionId = EnemyIds.Goblin, Level = 8, Damage = 8 }))
	equal(result.DefenseXPAwarded, false)
	equal(#healthCalls.apply, 1) -- damage still applied
end)

test("OnSpawn resets runtime health", function()
	local health, healthCalls = fakeHealth({ alive = true })
	local skills = fakeSkills({ levels = {} })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	ec.OnSpawn(7)
	equal(#healthCalls.reset, 1)
	equal(healthCalls.reset[1], 7)
end)

test("malformed enemy state fails closed", function()
	local health, healthCalls = fakeHealth({ alive = true, result = { Health = 90, MaxHealth = 100, Died = false } })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 1 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	equal(select(2, ec.ResolveAttack(7, "nope")), "InvalidEnemyState")
	equal(select(2, ec.ResolveAttack(7, { DefinitionId = EnemyIds.Goblin, Level = 8, Damage = 0 })), "InvalidEnemyState")
	equal(select(2, ec.ResolveAttack(7, { DefinitionId = "enemy_unknown", Level = 5, Damage = 5 })), "UnknownEnemy")
	equal(#healthCalls.apply, 0)
end)

print(("%d EnemyCombat checks passed"):format(passed))
