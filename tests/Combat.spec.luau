--!strict

local EquipmentSlots = require("EquipmentSlots")
local ItemDefinitions = require("ItemDefinitions")
local Equipment = require("EquipmentService")
local SkillIds = require("SkillIds")
local SkillDefinitions = require("SkillDefinitions")
local Skills = require("SkillsService")
local Combat = require("CombatService")

local StarterSword = "weapon_sword_starter"
local UpgradedSword = "weapon_sword_upgraded"

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

local function fixture(meleeModifiers)
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
				Stacks = { item_iron_ore = 4 },
				Items = {
					starter = { DefinitionId = StarterSword },
					upgraded = { DefinitionId = UpgradedSword },
				},
			},
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
	local clock = { Now = 0 }
	local targets = {
		target_goblin = { Eligible = true, Distance = 5, AppliedDamage = nil, Calls = 0, LastRequest = nil },
	}
	local function resolveTarget(_, targetId)
		local target = targets[targetId]
		if not target then
			return nil, "TargetNotFound"
		end
		return {
			Id = targetId,
			Eligible = target.Eligible,
			Distance = target.Distance,
			ApplyDamage = function(request)
				target.Calls += 1
				target.LastRequest = copy(request)
				return target.AppliedDamage or request.Damage, nil
			end,
		}, nil
	end
	local skills = Skills.New(playerData, { Curves = { curve_standard = curve() } })
	local equipment = Equipment.New(playerData)
	local service = Combat.New(equipment, skills, resolveTarget, { MeleeXPPerSuccessfulHit = 1 }, function() return clock.Now end, meleeModifiers)
	return {
		Records = records,
		PlayerData = playerData,
		Equipment = equipment,
		Service = service,
		Clock = clock,
		Targets = targets,
	}
end

test("melee definitions are centralized and distinguish the slice swords", function()
	local starter = assert(ItemDefinitions.ById[StarterSword].Melee)
	local upgraded = assert(ItemDefinitions.ById[UpgradedSword].Melee)
	equal(ItemDefinitions.ById[StarterSword].Equipment.SlotId, EquipmentSlots.Weapon)
	equal(ItemDefinitions.ById[UpgradedSword].Equipment.SlotId, EquipmentSlots.Weapon)
	assert(starter.Damage < upgraded.Damage)
	assert(starter.AttackIntervalSeconds > upgraded.AttackIntervalSeconds)
	assert(starter.AttackRange < upgraded.AttackRange)
	equal(ItemDefinitions.ById["tool_pickaxe_basic"].Melee, nil)
end)

test("attacks require an equipped valid melee weapon", function()
	local f = fixture()
	local none, noneReason = f.Service.ResolveMeleeAttack(7, "target_goblin")
	equal(none, nil)
	equal(noneReason, "NotEquipped")
	f.Records[7].Equipment[EquipmentSlots.Weapon] = "missing"
	local invalid, invalidReason = f.Service.ResolveMeleeAttack(7, "target_goblin")
	equal(invalid, nil)
	equal(invalidReason, "InvalidEquipment")
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "starter"))
	local result = assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	equal(result.WeaponDefinitionId, StarterSword)
	equal(result.WeaponInstanceId, "starter")
end)

test("upgraded swords resolve stronger, faster, longer-range attacks from definition data", function()
	local f = fixture()
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "starter"))
	local starter = assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	f.Clock.Now += starter.AttackIntervalSeconds
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "upgraded"))
	local upgraded = assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	assert(starter.Damage < upgraded.Damage)
	assert(starter.AttackIntervalSeconds > upgraded.AttackIntervalSeconds)
	assert(starter.AttackRange < upgraded.AttackRange)
	equal(f.Targets.target_goblin.LastRequest.WeaponDefinitionId, UpgradedSword)
end)

test("cooldowns enforce the configured attack interval", function()
	local f = fixture()
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "starter"))
	local first = assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	f.Clock.Now += first.AttackIntervalSeconds - 0.01
	local blocked, blockedReason = f.Service.ResolveMeleeAttack(7, "target_goblin")
	equal(blocked, nil)
	equal(blockedReason, "AttackOnCooldown")
	equal(f.Targets.target_goblin.Calls, 1)
	equal(f.Records[7].SkillXP[SkillIds.Melee], 1)
	f.Clock.Now += 0.01
	assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	equal(f.Targets.target_goblin.Calls, 2)
	equal(f.Records[7].SkillXP[SkillIds.Melee], 2)
end)

test("invalid, ineligible, and out-of-range targets never resolve", function()
	local f = fixture()
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "starter"))
	for _, attempt in {
		function() return f.Service.ResolveMeleeAttack(0, "target_goblin") end,
		function() return f.Service.ResolveMeleeAttack(7, "") end,
		function() return f.Service.ResolveMeleeAttack(7, "target_unknown") end,
	} do
		local result, reason = attempt()
		equal(result, nil)
		assert(reason == "InvalidUserId" or reason == "InvalidTargetId" or reason == "TargetNotFound")
	end
	f.Targets.target_goblin.Eligible = false
	local ineligible, ineligibleReason = f.Service.ResolveMeleeAttack(7, "target_goblin")
	equal(ineligible, nil)
	equal(ineligibleReason, "IneligibleTarget")
	f.Targets.target_goblin.Eligible = true
	f.Targets.target_goblin.Distance = ItemDefinitions.ById[StarterSword].Melee.AttackRange + 0.01
	local distant, distantReason = f.Service.ResolveMeleeAttack(7, "target_goblin")
	equal(distant, nil)
	equal(distantReason, "TargetOutOfRange")
	equal(f.Targets.target_goblin.Calls, 0)
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
end)

test("only meaningful applied damage receives Melee XP and preserves unrelated PlayerData", function()
	local f = fixture()
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "starter"))
	local before = copy(f.Records[7])
	f.Targets.target_goblin.AppliedDamage = 0
	local missed, missedReason = f.Service.ResolveMeleeAttack(7, "target_goblin")
	equal(missed, nil)
	equal(missedReason, "NoMeaningfulDamage")
	equal(f.Records[7].SkillXP[SkillIds.Melee], 0)
	f.Targets.target_goblin.AppliedDamage = nil
	local hit = assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	equal(hit.Damage, ItemDefinitions.ById[StarterSword].Melee.Damage)
	equal(hit.AppliedDamage, hit.Damage)
	equal(hit.MeleeXP, 1)
	equal(hit.XPGranted, true)
	equal(f.Records[7].SkillXP[SkillIds.Melee], 1)
	equal(f.Records[7].Gold, before.Gold)
	equal(f.Records[7].Inventory.Stacks.item_iron_ore, before.Inventory.Stacks.item_iron_ore)
	equal(next(f.Records[7].Plot.Stations), nil)
	equal(f.Records[7].ProgressionFlags.flag_intro_complete, true)
end)

-- ===== Melee Mastery: MeleeDamageBonus + MeleeAttackIntervalReduction =====
-- The fixture injects a modifier provider standing in for Mastery.GetModifiers(userId, Melee). Clean
-- binary fractions are used so the applied totals are exact; that Mastery sums node values into these
-- totals is covered separately in Mastery.spec.

local StarterMelee = ItemDefinitions.ById[StarterSword].Melee

test("no Melee selections preserve the exact base attack", function()
	local f = fixture(function() return {} end)
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "starter"))
	local hit = assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	equal(hit.Damage, StarterMelee.Damage)
	equal(hit.AppliedDamage, StarterMelee.Damage)
	equal(hit.AttackIntervalSeconds, StarterMelee.AttackIntervalSeconds)
end)

test("MeleeDamageBonus scales resolved and applied damage by exactly the provided total", function()
	local f = fixture(function() return { MeleeDamageBonus = 0.5 } end)
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "starter"))
	local hit = assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	equal(hit.Damage, StarterMelee.Damage * 1.5)
	equal(hit.AppliedDamage, StarterMelee.Damage * 1.5)
	equal(f.Targets.target_goblin.LastRequest.Damage, StarterMelee.Damage * 1.5)
end)

test("MeleeAttackIntervalReduction shortens the interval and the enforced cooldown", function()
	local f = fixture(function() return { MeleeAttackIntervalReduction = 0.25 } end)
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "starter"))
	local hit = assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	local expected = StarterMelee.AttackIntervalSeconds * 0.75
	equal(hit.AttackIntervalSeconds, expected)
	-- The cooldown now clears at the reduced interval, not the base one.
	f.Clock.Now += expected - 0.01
	equal(select(2, f.Service.ResolveMeleeAttack(7, "target_goblin")), "AttackOnCooldown")
	f.Clock.Now += 0.01
	assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
end)

test("only the provided numeric totals apply; spoofed/unknown values are ignored", function()
	-- A non-number reduction and an unrelated key must contribute nothing, and the damage total is
	-- applied exactly once (no re-derivation or double counting on top of Mastery.GetModifiers).
	local f = fixture(function() return { MeleeDamageBonus = 0.5, MeleeAttackIntervalReduction = "0.9", Junk = 100 } end)
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "starter"))
	local hit = assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	equal(hit.Damage, StarterMelee.Damage * 1.5)
	equal(hit.AttackIntervalSeconds, StarterMelee.AttackIntervalSeconds) -- string reduction ignored
end)

test("an oversized interval reduction is clamped so the interval stays strictly positive", function()
	local f = fixture(function() return { MeleeAttackIntervalReduction = 5 } end)
	assert(f.Equipment.Equip(7, EquipmentSlots.Weapon, "starter"))
	local hit = assert(f.Service.ResolveMeleeAttack(7, "target_goblin"))
	assert(hit.AttackIntervalSeconds > 0, "interval must remain strictly positive")
	assert(hit.AttackIntervalSeconds < StarterMelee.AttackIntervalSeconds, "interval must be reduced")
	assert(math.abs(hit.AttackIntervalSeconds - StarterMelee.AttackIntervalSeconds * 0.1) < 1e-9, "clamped to a 0.9 reduction")
end)

test("a non-function Melee modifier provider is rejected", function()
	local ok = pcall(Combat.New, { GetEquippedItem = function() end }, { AwardXP = function() end }, function() end, { MeleeXPPerSuccessfulHit = 1 }, function() return 0 end, 5)
	equal(ok, false)
end)

print(("%d Combat checks passed"):format(passed))
