--!strict

local EnemyIds = require("EnemyIds")
local EquipmentSlots = require("EquipmentSlots")
local ItemDefinitions = require("ItemDefinitions")
local SkillIds = require("SkillIds")
local ProgressionFlagIds = require("ProgressionFlagIds")
local AscensionIds = require("AscensionIds")
local EnemyDefinitions = require("EnemyDefinitions")
local Enemies = require("EnemiesService")
local SkillDefinitions = require("SkillDefinitions")
local Skills = require("SkillsService")
local Equipment = require("EquipmentService")
local Combat = require("CombatService")
local Inventory = require("InventoryService")
local Economy = require("EconomyService")
local Ascension = require("AscensionService")
local BossDefinitions = require("BossDefinitions")
local Bosses = require("BossService")

local Chieftain = EnemyIds.GoblinChieftain
local CommonItem = "item_iron_bar"
local RareItem = "item_chieftain_fang"
local ChieftainGold = EnemyDefinitions.ById[Chieftain].Scaling.BaseGoldReward

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

local function fixture(config)
	config = config or {}
	local records = {}
	local function ensureRecord(userId)
		if not records[userId] then
			records[userId] = {
				Gold = 0,
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
				Ascension = { RankId = AscensionIds.Adventurer, Flags = {} },
				Plot = { Stations = {} },
				ProgressionFlags = {},
				MasterySelections = {},
			}
		end
		return records[userId]
	end
	for _, userId in config.UserIds or {} do
		ensureRecord(userId)
	end

	local playerData = { Calls = 0, FailUsers = {} }
	function playerData.GetSnapshot(userId)
		local record = records[userId]
		return if record then copy(record) else nil
	end
	function playerData.Update(userId, change)
		playerData.Calls += 1
		if playerData.FailUsers[userId] then
			return false, playerData.FailUsers[userId]
		end
		local record = records[userId]
		if not record then
			return false, "NotReady"
		end
		local candidate = copy(record)
		local ok = pcall(change, candidate)
		if not ok then
			return false, "InvalidMutation"
		end
		records[userId] = candidate
		return true, nil
	end

	local idIndex, levelIndex = 0, 0
	local ids = config.RuntimeIds or {}
	local levels = config.Levels or {}
	local enemies = Enemies.New({
		NewRuntimeId = function()
			idIndex += 1
			return ids[idIndex]
		end,
		RollInteger = function(_, _)
			levelIndex += 1
			return levels[levelIndex]
		end,
	})

	local equipment = Equipment.New(playerData)
	local skills = Skills.New(playerData, { Curves = { curve_standard = curve() } })
	local clock = { Now = 0 }
	local combat = Combat.New(
		equipment,
		skills,
		enemies.CreateCombatTargetResolver(function(_, _)
			return 1, nil
		end),
		{ MeleeXPPerSuccessfulHit = 1 },
		function()
			return clock.Now
		end
	)
	local economy = Economy.New(playerData, { NewInstanceId = function() return "unused" end })
	local inventory = Inventory.New(playerData, { NewInstanceId = function() return "unused" end })
	local ascension = Ascension.New(playerData, skills)

	local rollIndex = 0
	local rolls = config.Rolls or {}
	local boss = Bosses.New(playerData, enemies, economy, inventory, ascension, {
		Roll01 = function()
			rollIndex += 1
			return rolls[rollIndex] or 1
		end,
	})

	return {
		Records = records,
		EnsureRecord = ensureRecord,
		PlayerData = playerData,
		Enemies = enemies,
		Equipment = equipment,
		Skills = skills,
		Combat = combat,
		Clock = clock,
		Economy = economy,
		Inventory = inventory,
		Ascension = ascension,
		Service = boss,
	}
end

-- Direct, non-Combat attack through the exact adapter Combat uses, for precise damage control.
local function rawAttack(f, attackerUserId, runtimeId, damage)
	local resolveTarget = f.Enemies.CreateCombatTargetResolver(function(_, _)
		return 0, nil
	end)
	local target = assert(resolveTarget(attackerUserId, runtimeId))
	return target.ApplyDamage({ TargetId = runtimeId, Damage = damage })
end

test("the Goblin Chieftain boss reward definition is stable, data-driven, and has one Gold authority", function()
	local valid = BossDefinitions.Validate(BossDefinitions.ById)
	equal(valid, true)
	local definition = BossDefinitions.ById[Chieftain]
	equal(definition.EnemyDefinitionId, Chieftain)
	equal(definition.Eligibility.MinimumContributionFraction, 0.05)
	-- No Gold field exists in Boss loot data at all -- the Enemy definition/death record is the
	-- single authority for Chieftain Gold.
	equal(definition.Loot.Common.GoldAmount, nil)
	equal(definition.Loot.Common.ItemDefinitionId, CommonItem)
	equal(definition.Loot.Common.Amount, 1)
	equal(definition.Loot.Rare.ItemDefinitionId, RareItem)
	equal(definition.Loot.Rare.Amount, 1)
	equal(definition.Loot.Rare.Chance, 0.15)
	equal(definition.MilestoneId, ProgressionFlagIds.GoblinChieftainDefeated)
	equal(ItemDefinitions.ById[CommonItem].Kind, "Stackable")
	equal(ItemDefinitions.ById[RareItem].Kind, "Stackable")
	equal(EnemyDefinitions.ById[Chieftain].Boss.IsBoss, true)
	assert(ChieftainGold > 0)
end)

test("Boss definitions reject a reference to a normal enemy or unknown ID that isn't marked as a boss", function()
	local template = BossDefinitions.ById[Chieftain]
	local candidateForGoblin = {
		[EnemyIds.Goblin] = {
			EnemyDefinitionId = EnemyIds.Goblin,
			Eligibility = template.Eligibility,
			Loot = template.Loot,
			MilestoneId = template.MilestoneId,
		},
	}
	local goblinValid, goblinReason = BossDefinitions.Validate(candidateForGoblin)
	equal(goblinValid, false)
	assert(type(goblinReason) == "string")
	equal(EnemyDefinitions.ById[EnemyIds.Goblin].Boss, nil)

	local candidateForUnknown = {
		enemy_unknown = {
			EnemyDefinitionId = "enemy_unknown",
			Eligibility = template.Eligibility,
			Loot = template.Loot,
			MilestoneId = template.MilestoneId,
		},
	}
	local unknownValid, unknownReason = BossDefinitions.Validate(candidateForUnknown)
	equal(unknownValid, false)
	assert(type(unknownReason) == "string")
end)

test("multiple players contribute independently and only actual applied damage counts", function()
	local f = fixture({ RuntimeIds = { "chieftain-1" }, Levels = { 10 }, UserIds = { 101, 102, 103, 104 } })
	assert(f.Enemies.Create(Chieftain))
	local first = assert(rawAttack(f, 101, "chieftain-1", 12))
	equal(first, 12)
	local second = assert(rawAttack(f, 102, "chieftain-1", 8))
	equal(second, 8)
	local contributionBefore = assert(f.Enemies.GetContribution("chieftain-1"))
	equal(contributionBefore[101], 12)
	equal(contributionBefore[102], 8)
	equal(contributionBefore[103], nil)

	-- A rejected request never counts.
	local rejected, rejectedReason = rawAttack(f, 103, "chieftain-1", 0)
	equal(rejected, nil)
	equal(rejectedReason, "InvalidDamageRequest")
	equal(assert(f.Enemies.GetContribution("chieftain-1"))[103], nil)

	-- Finish it off, then confirm post-death damage against the same runtime never counts either.
	assert(rawAttack(f, 103, "chieftain-1", 999999))
	local afterDeath, afterDeathReason = rawAttack(f, 104, "chieftain-1", 50)
	equal(afterDeath, nil)
	equal(afterDeathReason, "EnemyDead")
	equal(assert(f.Enemies.GetContribution("chieftain-1"))[104], nil)
end)

test("overkill damage does not inflate contribution beyond what was actually applied", function()
	local f = fixture({ RuntimeIds = { "chieftain-2" }, Levels = { 10 }, UserIds = { 201, 202 } })
	assert(f.Enemies.Create(Chieftain))
	assert(rawAttack(f, 201, "chieftain-2", 395))
	local overkill = assert(rawAttack(f, 202, "chieftain-2", 9999))
	equal(overkill, 5)
	local contribution = assert(f.Enemies.GetContribution("chieftain-2"))
	equal(contribution[201], 395)
	equal(contribution[202], 5)
end)

test("contribution is isolated between separate boss runtime instances", function()
	local f = fixture({ RuntimeIds = { "chieftain-3a", "chieftain-3b" }, Levels = { 10, 10 }, UserIds = { 301 } })
	assert(f.Enemies.Create(Chieftain))
	assert(f.Enemies.Create(Chieftain))
	assert(rawAttack(f, 301, "chieftain-3a", 40))
	assert(rawAttack(f, 301, "chieftain-3b", 60))
	equal(assert(f.Enemies.GetContribution("chieftain-3a"))[301], 40)
	equal(assert(f.Enemies.GetContribution("chieftain-3b"))[301], 60)
end)

test("normal Goblin combat and contribution stay unaffected by boss tracking", function()
	local f = fixture({ RuntimeIds = { "goblin-1" }, Levels = { 3 }, UserIds = { 501 } })
	local goblin = assert(f.Enemies.Create(EnemyIds.Goblin))
	equal(goblin.RuntimeId, "goblin-1")
	assert(f.Equipment.Equip(501, EquipmentSlots.Weapon, "starter"))
	local attack = assert(f.Combat.ResolveMeleeAttack(501, "goblin-1"))
	equal(attack.AppliedDamage, 10)
	equal(next(assert(f.Enemies.GetContribution("goblin-1"))), nil)
	local notABoss, notABossReason = f.Service.GetParticipationSummary("goblin-1")
	equal(notABoss, nil)
	equal(notABossReason, "NotABossEncounter")
end)

test("participation eligibility follows the centralized rule, not the killing blow, and the summary is read-only", function()
	local f = fixture({ RuntimeIds = { "chieftain-4" }, Levels = { 10 }, UserIds = { 401, 402, 403 } })
	assert(f.Enemies.Create(Chieftain))
	assert(rawAttack(f, 401, "chieftain-4", 25))
	assert(rawAttack(f, 403, "chieftain-4", 365))
	local killingBlow = assert(rawAttack(f, 402, "chieftain-4", 10))
	equal(killingBlow, 10)
	equal(assert(f.Enemies.GetSnapshot("chieftain-4")).Alive, false)

	local summary = assert(f.Service.GetParticipationSummary("chieftain-4"))
	equal(summary.RuntimeId, "chieftain-4")
	equal(summary.DefinitionId, Chieftain)
	equal(#summary.Entries, 3)
	equal(summary.Entries[1].UserId, 401)
	equal(summary.Entries[1].Contribution, 25)
	equal(summary.Entries[1].Eligible, true)
	equal(summary.Entries[2].UserId, 402)
	equal(summary.Entries[2].Contribution, 10)
	equal(summary.Entries[2].Eligible, false)
	equal(summary.Entries[3].UserId, 403)
	equal(summary.Entries[3].Contribution, 365)
	equal(summary.Entries[3].Eligible, true)

	-- The summary above must not have consumed the death; resolution still succeeds afterward.
	local callsBefore = f.PlayerData.Calls
	local result = assert(f.Service.ResolveBossDeath("chieftain-4"))
	equal(#result.Participants, 3)
	equal(result.Participants[1].UserId, 401)
	equal(result.Participants[1].Eligible, true)
	equal(result.Participants[1].RewardGranted, true)
	equal(result.Participants[2].UserId, 402)
	equal(result.Participants[2].Eligible, false)
	equal(result.Participants[2].RewardGranted, false)
	equal(result.Participants[3].UserId, 403)
	equal(result.Participants[3].Eligible, true)
	equal(result.Participants[3].RewardGranted, true)

	-- Ineligible participant 402 (the killer) never even had a PlayerData mutation attempted, and
	-- receives no Gold, common item, rare item, or milestone.
	equal(f.PlayerData.Calls, callsBefore + 2)
	equal(f.Records[402].Gold, 0)
	equal(f.Records[402].Inventory.Stacks[CommonItem], nil)
	equal(f.Records[402].Inventory.Stacks[RareItem], nil)
	equal(f.Records[402].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated], nil)

	-- Both eligible participants receive the guaranteed Iron Bar and the Enemy-sourced Gold.
	equal(f.Records[401].Gold, ChieftainGold)
	equal(f.Records[401].Inventory.Stacks[CommonItem], 1)
	equal(f.Records[401].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated], true)
	equal(f.Records[403].Gold, ChieftainGold)
	equal(f.Records[403].Inventory.Stacks[CommonItem], 1)
	equal(f.Records[403].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated], true)
end)

test("the trusted Combat path attributes real applied boss damage to the attacking user", function()
	local f = fixture({ RuntimeIds = { "chieftain-6" }, Levels = { 10 }, UserIds = { 601, 602 } })
	assert(f.Enemies.Create(Chieftain))
	assert(f.Equipment.Equip(601, EquipmentSlots.Weapon, "starter"))
	assert(f.Equipment.Equip(602, EquipmentSlots.Weapon, "upgraded"))
	local first = assert(f.Combat.ResolveMeleeAttack(601, "chieftain-6"))
	equal(first.AppliedDamage, 10)
	f.Clock.Now += first.AttackIntervalSeconds
	local second = assert(f.Combat.ResolveMeleeAttack(602, "chieftain-6"))
	equal(second.AppliedDamage, 15)
	f.Clock.Now += first.AttackIntervalSeconds
	local third = assert(f.Combat.ResolveMeleeAttack(601, "chieftain-6"))
	equal(third.AppliedDamage, 10)

	local contribution = assert(f.Enemies.GetContribution("chieftain-6"))
	equal(contribution[601], 20)
	equal(contribution[602], 15)
end)

test("an eligible participant with no rare roll still receives the guaranteed reward and milestone", function()
	local f = fixture({ RuntimeIds = { "chieftain-7" }, Levels = { 10 }, UserIds = { 701 } })
	assert(f.Enemies.Create(Chieftain))
	assert(rawAttack(f, 701, "chieftain-7", 999999))
	local result = assert(f.Service.ResolveBossDeath("chieftain-7"))
	local participant = result.Participants[1]
	equal(participant.UserId, 701)
	equal(participant.RewardGranted, true)
	equal(participant.CommonGoldAmount, ChieftainGold)
	equal(participant.CommonItemDefinitionId, CommonItem)
	equal(participant.CommonItemAmount, 1)
	equal(participant.RareGranted, false)
	equal(participant.RareItemDefinitionId, nil)
	equal(participant.MilestoneRecorded, true)
	equal(f.Records[701].Gold, ChieftainGold)
	equal(f.Records[701].Inventory.Stacks[CommonItem], 1)
	equal(f.Records[701].Inventory.Stacks[RareItem], nil)
	equal(f.Records[701].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated], true)
end)

test("each eligible participant rolls independently for the rare reward alongside the guaranteed reward", function()
	local f = fixture({ RuntimeIds = { "chieftain-8" }, Levels = { 10 }, UserIds = { 801, 802 }, Rolls = { 0.05, 0.99 } })
	assert(f.Enemies.Create(Chieftain))
	assert(rawAttack(f, 801, "chieftain-8", 200))
	assert(rawAttack(f, 802, "chieftain-8", 999999))
	local result = assert(f.Service.ResolveBossDeath("chieftain-8"))
	equal(result.Participants[1].UserId, 801)
	equal(result.Participants[1].RareGranted, true)
	equal(result.Participants[1].RareItemDefinitionId, RareItem)
	equal(result.Participants[1].RareItemAmount, 1) -- presentation companion, mirrors the granted amount
	equal(result.Participants[2].UserId, 802)
	equal(result.Participants[2].RareGranted, false)
	equal(result.Participants[2].RareItemDefinitionId, nil)
	equal(result.Participants[2].RareItemAmount, nil)

	-- The guaranteed Iron Bar and Gold go to both participants regardless of their rare outcome.
	equal(f.Records[801].Gold, ChieftainGold)
	equal(f.Records[801].Inventory.Stacks[CommonItem], 1)
	equal(f.Records[801].Inventory.Stacks[RareItem], 1)
	equal(f.Records[802].Gold, ChieftainGold)
	equal(f.Records[802].Inventory.Stacks[CommonItem], 1)
	equal(f.Records[802].Inventory.Stacks[RareItem], nil)
end)

test("a failed mutation rolls back one participant's entire reward without affecting another", function()
	local f = fixture({ RuntimeIds = { "chieftain-9" }, Levels = { 10 }, UserIds = { 901, 902 } })
	assert(f.Enemies.Create(Chieftain))
	assert(rawAttack(f, 901, "chieftain-9", 200))
	assert(rawAttack(f, 902, "chieftain-9", 999999))
	f.PlayerData.FailUsers[901] = "SimulatedMutationFailure"

	local result = assert(f.Service.ResolveBossDeath("chieftain-9"))
	local first = result.Participants[1]
	equal(first.UserId, 901)
	equal(first.Eligible, true)
	equal(first.RewardGranted, false)
	equal(first.FailureReason, "SimulatedMutationFailure")
	-- Nothing partially applied for the failed participant: Gold + common item + rare item +
	-- milestone all failed to commit together.
	equal(f.Records[901].Gold, 0)
	equal(f.Records[901].Inventory.Stacks[CommonItem], nil)
	equal(f.Records[901].Inventory.Stacks[RareItem], nil)
	equal(f.Records[901].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated], nil)

	-- The other eligible participant is untouched by the first participant's failure.
	local second = result.Participants[2]
	equal(second.UserId, 902)
	equal(second.RewardGranted, true)
	equal(f.Records[902].Gold, ChieftainGold)
	equal(f.Records[902].Inventory.Stacks[CommonItem], 1)
	equal(f.Records[902].ProgressionFlags[ProgressionFlagIds.GoblinChieftainDefeated], true)
end)

test("resolving the same boss death twice fails closed and never duplicates a reward", function()
	local f = fixture({ RuntimeIds = { "chieftain-10" }, Levels = { 10 }, UserIds = { 1001 } })
	assert(f.Enemies.Create(Chieftain))
	assert(rawAttack(f, 1001, "chieftain-10", 999999))
	local first = assert(f.Service.ResolveBossDeath("chieftain-10"))
	equal(first.Participants[1].RewardGranted, true)
	equal(f.Records[1001].Gold, ChieftainGold)
	equal(f.Records[1001].Inventory.Stacks[CommonItem], 1)

	local second, secondReason = f.Service.ResolveBossDeath("chieftain-10")
	equal(second, nil)
	equal(secondReason, "DeathNotAvailable")
	equal(f.Records[1001].Gold, ChieftainGold)
	equal(f.Records[1001].Inventory.Stacks[CommonItem], 1)
end)

print(("%d Bosses checks passed"):format(passed))
