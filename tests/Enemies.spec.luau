--!strict

local EnemyIds = require("EnemyIds")
local Definitions = require("EnemyDefinitions")
local Enemies = require("EnemiesService")
local EquipmentSlots = require("EquipmentSlots")
local Equipment = require("EquipmentService")
local SkillIds = require("SkillIds")
local SkillDefinitions = require("SkillDefinitions")
local Skills = require("SkillsService")
local Combat = require("CombatService")

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

local function enemyFixture(ids, levels)
	local idIndex, levelIndex = 0, 0
	return Enemies.New({
		NewRuntimeId = function()
			idIndex += 1
			return ids[idIndex]
		end,
		RollInteger = function(_, _)
			levelIndex += 1
			return levels[levelIndex]
		end,
	})
end

local function curve()
	local thresholds = {}
	for level = 1, SkillDefinitions.LevelCap do
		thresholds[level] = (level - 1) * 100
	end
	return { MaximumXP = 6000, Thresholds = thresholds }
end

test("Goblin uses a stable definition with valid configurable data", function()
	local valid = Definitions.Validate(Definitions.ById)
	equal(valid, true)
	equal(EnemyIds.ById[EnemyIds.Goblin], true)
	local goblin = Definitions.ById[EnemyIds.Goblin]
	equal(goblin.Id, EnemyIds.Goblin)
	equal(goblin.LevelRange.Minimum, 3)
	equal(goblin.LevelRange.Maximum, 8)
	assert(goblin.Aggression.MinimumEnemyLevelDelta < 0)
end)

test("level rolls stay within the configured Goblin bounds and derive reusable stats", function()
	local service = enemyFixture({ "enemy-one", "enemy-two" }, { 3, 8 })
	local lower = assert(service.Create(EnemyIds.Goblin))
	local upper = assert(service.Create(EnemyIds.Goblin))
	equal(lower.Level, 3)
	equal(upper.Level, 8)
	equal(lower.MaxHealth, 30)
	equal(upper.MaxHealth, 60)
	equal(lower.Damage, 4)
	equal(upper.Damage, 9)
	equal(lower.GoldReward, 3)
	equal(upper.GoldReward, 8)
	local invalid, invalidReason = service.GetDerivedStats(EnemyIds.Goblin, 2)
	equal(invalid, nil)
	equal(invalidReason, "InvalidEnemyLevel")
end)

test("runtime enemies create, query, remove, and isolate their snapshots", function()
	local service = enemyFixture({ "enemy-one", "enemy-two" }, { 3, 4 })
	local first = assert(service.Create(EnemyIds.Goblin))
	local second = assert(service.Create(EnemyIds.Goblin))
	local copyFirst = assert(service.GetSnapshot(first.RuntimeId))
	copyFirst.Health = 0
	equal(assert(service.GetSnapshot(first.RuntimeId)).Health, first.MaxHealth)
	equal(assert(service.GetSnapshot(second.RuntimeId)).RuntimeId, second.RuntimeId)
	local removed = assert(service.Remove(first.RuntimeId))
	equal(removed.RuntimeId, first.RuntimeId)
	local missing, missingReason = service.GetSnapshot(first.RuntimeId)
	equal(missing, nil)
	equal(missingReason, "EnemyNotFound")
	equal(assert(service.GetSnapshot(second.RuntimeId)).Alive, true)
end)

test("damage clamps to health and emits one structured death transition", function()
	local service = enemyFixture({ "enemy-one" }, { 3 })
	local enemy = assert(service.Create(EnemyIds.Goblin))
	local first = assert(service.ApplyDamage(enemy.RuntimeId, 7))
	equal(first.AppliedDamage, 7)
	equal(first.Enemy.Health, 23)
	equal(first.Death, nil)
	local final = assert(service.ApplyDamage(enemy.RuntimeId, 999))
	equal(final.AppliedDamage, 23)
	equal(final.Enemy.Health, 0)
	equal(final.Enemy.Alive, false)
	equal(final.Death.RuntimeId, enemy.RuntimeId)
	equal(final.Death.DefinitionId, EnemyIds.Goblin)
	equal(final.Death.Level, 3)
	equal(final.Death.GoldReward, enemy.GoldReward)
	local noHandoff, noHandoffReason = service.ConsumeDeath(enemy.RuntimeId)
	equal(noHandoff, nil)
	equal(noHandoffReason, "DeathNotAvailable")
	local repeated, repeatedReason = service.ApplyDamage(enemy.RuntimeId, 1)
	equal(repeated, nil)
	equal(repeatedReason, "EnemyDead")
end)

test("invalid definitions, runtime IDs, rolls, and damage fail without state changes", function()
	local service = enemyFixture({ "enemy-one" }, { 3 })
	local invalidDefinition, invalidDefinitionReason = service.Create("enemy_unknown")
	equal(invalidDefinition, nil)
	equal(invalidDefinitionReason, "InvalidEnemyId")
	for _, attempt in {
		function() return service.GetSnapshot("") end,
		function() return service.Remove("enemy_unknown") end,
		function() return service.ApplyDamage("enemy_unknown", 1) end,
	} do
		local value, reason = attempt()
		equal(value, nil)
		assert(reason == "InvalidRuntimeId" or reason == "EnemyNotFound")
	end
	local enemy = assert(service.Create(EnemyIds.Goblin))
	local invalidDamage, invalidDamageReason = service.ApplyDamage(enemy.RuntimeId, 0)
	equal(invalidDamage, nil)
	equal(invalidDamageReason, "InvalidDamage")
	equal(assert(service.GetSnapshot(enemy.RuntimeId)).Health, enemy.MaxHealth)
	local invalidRollService = enemyFixture({ "enemy-invalid" }, { 9 })
	local invalidRoll, invalidRollReason = invalidRollService.Create(EnemyIds.Goblin)
	equal(invalidRoll, nil)
	equal(invalidRollReason, "InvalidLevelRoll")
end)

test("separate enemy runtime instances never share health or death state", function()
	local service = enemyFixture({ "enemy-one", "enemy-two" }, { 3, 3 })
	local first = assert(service.Create(EnemyIds.Goblin))
	local second = assert(service.Create(EnemyIds.Goblin))
	assert(service.ApplyDamage(first.RuntimeId, first.MaxHealth))
	equal(assert(service.GetSnapshot(first.RuntimeId)).Alive, false)
	local unaffected = assert(service.GetSnapshot(second.RuntimeId))
	equal(unaffected.Alive, true)
	equal(unaffected.Health, unaffected.MaxHealth)
end)

test("the target adapter applies Combat damage and exposes each death once", function()
	local records = {
		[7] = {
			Gold = 25,
			SkillXP = {
				[SkillIds.Melee] = 0,
				[SkillIds.Defense] = 0,
				[SkillIds.Mining] = 0,
				[SkillIds.Smithing] = 0,
			},
			Inventory = {
				Stacks = {},
				Items = {
					starter = { DefinitionId = "weapon_sword_starter" },
					upgraded = { DefinitionId = "weapon_sword_upgraded" },
				},
			},
			Equipment = { [EquipmentSlots.Weapon] = "starter" },
			Plot = { Stations = {} },
		},
	}
	local playerData = {}
	function playerData.GetSnapshot(userId)
		return if records[userId] then copy(records[userId]) else nil
	end
	function playerData.Update(userId, change)
		local candidate = copy(records[userId])
		if not candidate then
			return false, "NotReady"
		end
		change(candidate)
		records[userId] = candidate
		return true, nil
	end
	local enemies = enemyFixture({ "enemy-nonlethal", "enemy-combat" }, { 3, 3 })
	local nonlethal = assert(enemies.Create(EnemyIds.Goblin))
	local enemy = assert(enemies.Create(EnemyIds.Goblin))
	local equipment = Equipment.New(playerData)
	local skills = Skills.New(playerData, { Curves = { curve_standard = curve() } })
	local clock = { Now = 0 }
	local combat = Combat.New(equipment, skills, enemies.CreateCombatTargetResolver(function(_, target)
		assert(target.RuntimeId == nonlethal.RuntimeId or target.RuntimeId == enemy.RuntimeId)
		return 5, nil
	end), { MeleeXPPerSuccessfulHit = 1 }, function() return clock.Now end)
	local result = assert(combat.ResolveMeleeAttack(7, nonlethal.RuntimeId))
	equal(result.TargetId, nonlethal.RuntimeId)
	equal(result.Damage, 10)
	equal(result.AppliedDamage, 10)
	equal(assert(enemies.GetSnapshot(nonlethal.RuntimeId)).Health, nonlethal.MaxHealth - 10)
	local noDeath, noDeathReason = enemies.ConsumeDeath(nonlethal.RuntimeId)
	equal(noDeath, nil)
	equal(noDeathReason, "DeathNotAvailable")
	clock.Now += result.AttackIntervalSeconds
	assert(equipment.Equip(7, EquipmentSlots.Weapon, "upgraded"))
	local first = assert(combat.ResolveMeleeAttack(7, enemy.RuntimeId))
	clock.Now += first.AttackIntervalSeconds
	local final = assert(combat.ResolveMeleeAttack(7, enemy.RuntimeId))
	equal(final.TargetId, enemy.RuntimeId)
	equal(final.AppliedDamage, 15)
	equal(assert(enemies.GetSnapshot(enemy.RuntimeId)).Alive, false)
	local death = assert(enemies.ConsumeDeath(enemy.RuntimeId))
	equal(death.RuntimeId, enemy.RuntimeId)
	equal(death.DefinitionId, EnemyIds.Goblin)
	equal(death.Level, enemy.Level)
	equal(death.FinalDamage, 15)
	equal(death.GoldReward, enemy.GoldReward)
	local consumed, consumedReason = enemies.ConsumeDeath(enemy.RuntimeId)
	equal(consumed, nil)
	equal(consumedReason, "DeathNotAvailable")
	equal(records[7].SkillXP[SkillIds.Melee], 3)
end)

print(("%d Enemy checks passed"):format(passed))
