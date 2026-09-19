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

-- Provisional bounded Defense XP scale: clamp(Base + PerLevel * (enemyLevel - playerLevel), Min, Max).
local CONFIG = { DefenseXP = { Base = 2, PerLevel = 1, Minimum = 0, Maximum = 6 }, ProgressionSkillId = SkillIds.Melee }
local aliveResult = { Health = 92, MaxHealth = 100, Died = false }

test("New requires a valid bounded Defense XP scale", function()
	local health = fakeHealth({ alive = true })
	local skills = fakeSkills({ levels = {} })
	equal(pcall(EnemyCombat.New, health, skills, { ProgressionSkillId = SkillIds.Melee }), false)
	equal(pcall(EnemyCombat.New, health, skills, { DefenseXP = { Base = 2, PerLevel = 1, Minimum = 5, Maximum = 1 }, ProgressionSkillId = SkillIds.Melee }), false)
	assert(pcall(EnemyCombat.New, health, skills, CONFIG))
end)

test("an appropriate/underpowered player is auto-engaged: damage applied and Defense XP scaled", function()
	local health, healthCalls = fakeHealth({ alive = true, result = aliveResult })
	local skills, awards = fakeSkills({ levels = { [SkillIds.Melee] = 5, [SkillIds.Defense] = 1 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	-- matched fight: delta 0 -> appropriate -> 2 Defense XP
	local result = assert(ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 8 }))
	equal(result.Engagement, "Aggressive")
	equal(result.Damage, 8)
	equal(result.DefenseXP, 2)
	equal(result.DefenseXPAwarded, true)
	equal(#healthCalls.apply, 1)
	equal(awards[1].skillId, SkillIds.Defense)
	equal(awards[1].amount, 2)
end)

test("an overleveled player is ignored while passive (no damage, no XP)", function()
	local health, healthCalls = fakeHealth({ alive = true, result = aliveResult })
	local skills, awards = fakeSkills({ levels = { [SkillIds.Melee] = 36, [SkillIds.Defense] = 5 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	local result, reason = ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 8 })
	equal(result, nil)
	equal(reason, "NotEngaged")
	equal(#healthCalls.apply, 0)
	equal(#awards, 0)
end)

test("the same overleveled player is retaliated against after provoking the enemy, but the trivial fight awards ~0 Defense XP", function()
	local health, healthCalls = fakeHealth({ alive = true, result = aliveResult })
	local skills, awards = fakeSkills({ levels = { [SkillIds.Melee] = 36, [SkillIds.Defense] = 5 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	assert(ec.RecordProvocation("e1", 7))
	local result = assert(ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 8 }))
	equal(result.Engagement, "Provoked")
	equal(#healthCalls.apply, 1) -- retaliation lands
	equal(result.DefenseXP, 0) -- trivial: clamp(2 + (5-36), 0, 6) == 0
	equal(result.DefenseXPAwarded, false)
	equal(#awards, 0)
end)

test("provocation does not survive the enemy's death / a new RuntimeId", function()
	local health = fakeHealth({ alive = true, result = aliveResult })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 36, [SkillIds.Defense] = 5 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	ec.RecordProvocation("old", 7)
	ec.ClearEnemy("old") -- World clears the removed RuntimeId on death/respawn
	equal(select(2, ec.ResolveAttack(7, { RuntimeId = "old", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 8 })), "NotEngaged")
	-- The respawned instance has a fresh RuntimeId and inherits no provocation.
	equal(select(2, ec.ResolveAttack(7, { RuntimeId = "new", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 8 })), "NotEngaged")
end)

test("ClearPlayer drops a departed player's provocations", function()
	local health = fakeHealth({ alive = true, result = aliveResult })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 36, [SkillIds.Defense] = 5 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	ec.RecordProvocation("e1", 7)
	ec.ClearPlayer(7)
	equal(select(2, ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 8 })), "NotEngaged")
end)

test("Defense XP differs appropriately across trivial, appropriate, and dangerous difficulty", function()
	local health = fakeHealth({ alive = true, result = aliveResult })
	-- Trivial: strong player provokes a weak goblin (engaged via provocation), delta far negative -> 0.
	local trivialSkills = fakeSkills({ levels = { [SkillIds.Melee] = 20, [SkillIds.Defense] = 5 } })
	local trivialEC = EnemyCombat.New(health, trivialSkills, CONFIG)
	trivialEC.RecordProvocation("t", 7)
	local trivial = assert(trivialEC.ResolveAttack(7, { RuntimeId = "t", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 6 }))
	-- Appropriate: matched levels, auto-aggressive, delta 0.
	local appropriateSkills = fakeSkills({ levels = { [SkillIds.Melee] = 5, [SkillIds.Defense] = 5 } })
	local appropriate = assert(EnemyCombat.New(health, appropriateSkills, CONFIG).ResolveAttack(7, { RuntimeId = "a", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 6 }))
	-- Dangerous: enemy well above the player, delta large positive (capped).
	local dangerousSkills = fakeSkills({ levels = { [SkillIds.Melee] = 5, [SkillIds.Defense] = 5 } })
	local dangerous = assert(EnemyCombat.New(health, dangerousSkills, CONFIG).ResolveAttack(7, { RuntimeId = "d", DefinitionId = EnemyIds.GoblinChieftain, Level = 10, Damage = 20 }))
	equal(trivial.DefenseXP, 0)
	equal(appropriate.DefenseXP, 2)
	equal(dangerous.DefenseXP, 6) -- clamp(2 + (10-5), 0, 6) == 6
	assert(trivial.DefenseXP < appropriate.DefenseXP and appropriate.DefenseXP < dangerous.DefenseXP, "XP must increase with difficulty")
end)

test("no client-supplied field can create provocation or choose the XP amount", function()
	local health, healthCalls = fakeHealth({ alive = true, result = aliveResult })
	local skills, awards = fakeSkills({ levels = { [SkillIds.Melee] = 36, [SkillIds.Defense] = 5 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	-- An overleveled passive player: injected "Provoked"/"Engaged" flags on the state must be ignored.
	local spoofed, reason = ec.ResolveAttack(7, {
		RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 8,
		Provoked = true, Engaged = true, Aggressive = true, DefenseXP = 9999,
	})
	equal(spoofed, nil)
	equal(reason, "NotEngaged")
	equal(#healthCalls.apply, 0)
	-- Even when legitimately engaged, an injected DefenseXP field cannot inflate the reward.
	local appropriateSkills, appropriateAwards = fakeSkills({ levels = { [SkillIds.Melee] = 5, [SkillIds.Defense] = 5 } })
	local engagedEC = EnemyCombat.New(health, appropriateSkills, CONFIG)
	local result = assert(engagedEC.ResolveAttack(7, { RuntimeId = "e2", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 8, DefenseXP = 9999 }))
	equal(result.DefenseXP, 2)
	equal(appropriateAwards[1].amount, 2)
end)

-- ===== Defense Mastery: IncomingDamageReduction =====
-- The 4th New argument stands in for Mastery.GetModifiers(userId, Defense). An appropriate (delta 0)
-- player is auto-engaged, so these focus purely on how much damage actually reaches runtime health.

test("no Defense selections apply the enemy's full authoritative damage", function()
	local health, healthCalls = fakeHealth({ alive = true, result = aliveResult })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 5, [SkillIds.Defense] = 5 } })
	local ec = EnemyCombat.New(health, skills, CONFIG, function() return {} end)
	local result = assert(ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 10 }))
	equal(healthCalls.apply[1].amount, 10)
	equal(result.Damage, 10)
end)

test("IncomingDamageReduction lowers the damage applied to runtime health server-side", function()
	local health, healthCalls = fakeHealth({ alive = true, result = aliveResult })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 5, [SkillIds.Defense] = 5 } })
	local ec = EnemyCombat.New(health, skills, CONFIG, function() return { IncomingDamageReduction = 0.25 } end)
	local result = assert(ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 10 }))
	equal(healthCalls.apply[1].amount, 7.5) -- 10 * (1 - 0.25)
	equal(result.Damage, 7.5)
	-- Defense XP still scales with difficulty, not with the reduced damage.
	equal(result.DefenseXP, 2)
end)

test("an oversized IncomingDamageReduction is clamped so a hit still applies positive damage", function()
	local health, healthCalls = fakeHealth({ alive = true, result = aliveResult })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 5, [SkillIds.Defense] = 5 } })
	local ec = EnemyCombat.New(health, skills, CONFIG, function() return { IncomingDamageReduction = 5 } end)
	local result = assert(ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 10 }))
	assert(healthCalls.apply[1].amount > 0 and healthCalls.apply[1].amount < 2, "clamped damage must stay small but strictly positive")
	assert(result.Damage > 0)
end)

test("a respec clearing IncomingDamageReduction restores full damage immediately", function()
	local reduction = 0.25
	local health, healthCalls = fakeHealth({ alive = true, result = aliveResult })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 5, [SkillIds.Defense] = 5 } })
	local ec = EnemyCombat.New(health, skills, CONFIG, function() return { IncomingDamageReduction = reduction } end)
	assert(ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 10 }))
	equal(healthCalls.apply[1].amount, 7.5)
	reduction = 0 -- respec removed the Bulwark nodes
	assert(ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 10 }))
	equal(healthCalls.apply[2].amount, 10)
end)

test("a client-supplied IncomingDamageReduction on the enemy state cannot reduce damage", function()
	local health, healthCalls = fakeHealth({ alive = true, result = aliveResult })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 5, [SkillIds.Defense] = 5 } })
	-- Provider (the only trusted source) reports no reduction; a spoofed field on the state is ignored.
	local ec = EnemyCombat.New(health, skills, CONFIG, function() return {} end)
	assert(ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 10, IncomingDamageReduction = 0.9 }))
	equal(healthCalls.apply[1].amount, 10)
end)

test("a non-function Defense modifier provider is rejected", function()
	local health = fakeHealth({ alive = true, result = aliveResult })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 5 } })
	equal(pcall(EnemyCombat.New, health, skills, CONFIG, 5), false)
	assert(pcall(EnemyCombat.New, health, skills, CONFIG, function() return {} end))
end)

test("a dead target is never attacked", function()
	local health, healthCalls = fakeHealth({ alive = false })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 1, [SkillIds.Defense] = 1 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	local result, reason = ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 8, Damage = 8 })
	equal(result, nil)
	equal(reason, "TargetNotAlive")
	equal(#healthCalls.apply, 0)
end)

test("a lethal hit is reported as Died", function()
	local health = fakeHealth({ alive = true, result = { Health = 0, MaxHealth = 100, Died = true } })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 5, [SkillIds.Defense] = 1 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	local result = assert(ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = EnemyIds.Goblin, Level = 5, Damage = 8 }))
	equal(result.Died, true)
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
	local health, healthCalls = fakeHealth({ alive = true, result = aliveResult })
	local skills = fakeSkills({ levels = { [SkillIds.Melee] = 1 } })
	local ec = EnemyCombat.New(health, skills, CONFIG)
	equal(select(2, ec.ResolveAttack(7, "nope")), "InvalidEnemyState")
	equal(select(2, ec.ResolveAttack(7, { DefinitionId = EnemyIds.Goblin, Level = 8, Damage = 8 })), "InvalidEnemyState") -- missing RuntimeId
	equal(select(2, ec.ResolveAttack(7, { RuntimeId = "e1", DefinitionId = "enemy_unknown", Level = 5, Damage = 5 })), "UnknownEnemy")
	equal(#healthCalls.apply, 0)
end)

print(("%d EnemyCombat checks passed"):format(passed))
