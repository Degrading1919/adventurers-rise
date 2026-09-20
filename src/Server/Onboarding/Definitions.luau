--!strict

-- Data-driven definition of the shortened vertical-slice onboarding chain: the ordered steps a fresh
-- player is guided through, their presentation text, how each step's completion is proven, and an
-- optional world target the client may highlight. Ordering and text live here so they can be tuned
-- without touching the Service's authoritative evaluation or the client Controller.
--
-- Completion is NEVER decided by the client. Each step's Check names an authoritative fact:
--   * SkillLevel -- a durable, monotonic skill level (Melee/Defense to Level 2);
--   * Rank       -- the persisted Ascension rank (Adept);
--   * Flag       -- a persisted one-time ProgressionFlag (reused GoblinChieftainDefeated for the boss,
--                   and the Onboarding* flags for historical action milestones that transient state
--                   cannot safely reconstruct);
--   * Acquire    -- either the durable "upgraded weapon acquired" flag OR currently owning the item,
--                   so a player who crafted OR bought it is credited and never regresses on a later sell.

local Shared = game:GetService("ReplicatedStorage").Shared
local SkillIds = require(Shared.SkillIds)
local EnemyIds = require(Shared.EnemyIds)
local AscensionIds = require(Shared.AscensionIds)
local ProgressionFlagIds = require(Shared.ProgressionFlagIds)

-- World CollectionService tags (owned by Server/World/Service.luau) the client uses to highlight the
-- current objective's relevant nearby object. Presentation hints only -- they carry no authority.
local TAG_TRAINING_STATION = "AR_TrainingStation"
local TAG_ENEMY = "AR_Enemy"
local TAG_GATHERING_NODE = "AR_GatheringNode"
local TAG_FORGE = "AR_Forge"

-- Provisional, replaceable balance for the onboarding chain (same "small config data" category as the
-- other *Definitions). Levels/threshold/reward are tunable without code changes elsewhere.
local Definitions = {
	MeleeTargetLevel = 2,
	DefenseTargetLevel = 2,
	GoldMilestoneGold = 100,
	TrainingRewardGold = 50,
	-- Item IDs the Service reconciles against (mirrors Shared/ItemDefinitions ids; centralized here so
	-- the onboarding material/equipment references live in one place).
	UpgradedWeaponDefinitionId = "weapon_sword_upgraded",
	IronOreDefinitionId = "item_iron_ore",
	IronBarDefinitionId = "item_iron_bar",
}

local stepIds: { [string]: string } = {
	StarterFocus = "onboarding_starter_focus",
	TrainMelee = "onboarding_train_melee",
	TrainDefense = "onboarding_train_defense",
	FightGoblins = "onboarding_fight_goblins",
	EarnGold = "onboarding_earn_gold",
	MineOre = "onboarding_mine_ore",
	SmeltBar = "onboarding_smelt_bar",
	AcquireUpgrade = "onboarding_acquire_upgrade",
	DefeatChieftain = "onboarding_defeat_chieftain",
	AscendAdept = "onboarding_ascend_adept",
}
Definitions.StepIds = table.freeze(stepIds)

local S = stepIds
local Flags = ProgressionFlagIds

-- Ordered onboarding steps. `Check` is the authoritative completion descriptor; `Progress` (optional)
-- drives a compact "x / y" readout; `Target` (optional) names a world tag the client may highlight.
local ordered = {
	{
		Id = S.StarterFocus,
		Title = "Choose your starter focus",
		Hint = "Sword is your starting combat focus for the slice — confirm it to begin.",
		Check = { Kind = "Flag", FlagId = Flags.OnboardingStarterFocusAcknowledged },
	},
	{
		Id = S.TrainMelee,
		Title = "Train Melee to Level 2",
		Hint = "Stand on the Melee Training station and press Train.",
		Check = { Kind = "SkillLevel", SkillId = SkillIds.Melee, Level = Definitions.MeleeTargetLevel },
		Progress = { Kind = "SkillLevel", SkillId = SkillIds.Melee, Level = Definitions.MeleeTargetLevel },
		Target = { Tag = TAG_TRAINING_STATION },
	},
	{
		Id = S.TrainDefense,
		Title = "Train Defense to Level 2",
		Hint = "Stand on the Defense Training station and press Train.",
		Check = { Kind = "SkillLevel", SkillId = SkillIds.Defense, Level = Definitions.DefenseTargetLevel },
		Progress = { Kind = "SkillLevel", SkillId = SkillIds.Defense, Level = Definitions.DefenseTargetLevel },
		Target = { Tag = TAG_TRAINING_STATION },
	},
	{
		Id = S.FightGoblins,
		Title = "Defeat a Goblin",
		Hint = "Find a Goblin and hold Attack until it falls.",
		Check = { Kind = "Flag", FlagId = Flags.OnboardingFirstGoblinDefeated },
		Target = { Tag = TAG_ENEMY, MatchAttribute = "EnemyDefinitionId", MatchValue = EnemyIds.Goblin },
	},
	{
		Id = S.EarnGold,
		Title = ("Earn %d Gold"):format(Definitions.GoldMilestoneGold),
		Hint = "Defeat Goblins to earn Gold for your first upgrade.",
		Check = { Kind = "Flag", FlagId = Flags.OnboardingGoldMilestoneReached },
		Progress = { Kind = "Gold", Threshold = Definitions.GoldMilestoneGold },
		Target = { Tag = TAG_ENEMY, MatchAttribute = "EnemyDefinitionId", MatchValue = EnemyIds.Goblin },
	},
	{
		Id = S.MineOre,
		Title = "Mine Iron Ore",
		Hint = "Equip a pickaxe and mine the Iron Ore node.",
		Check = { Kind = "Flag", FlagId = Flags.OnboardingFirstOreGathered },
		Target = { Tag = TAG_GATHERING_NODE },
	},
	{
		Id = S.SmeltBar,
		Title = "Smelt an Iron Bar",
		Hint = "Take your ore to the Forge and craft an Iron Bar.",
		Check = { Kind = "Flag", FlagId = Flags.OnboardingFirstBarSmithed },
		Target = { Tag = TAG_FORGE },
	},
	{
		Id = S.AcquireUpgrade,
		Title = "Get an Upgraded Sword",
		Hint = "Craft one at the Forge or buy it from the Shop — either works.",
		Check = { Kind = "Acquire", FlagId = Flags.OnboardingUpgradedWeaponAcquired, DefinitionId = Definitions.UpgradedWeaponDefinitionId },
		Target = { Tag = TAG_FORGE },
	},
	{
		Id = S.DefeatChieftain,
		Title = "Defeat the Goblin Chieftain",
		Hint = "Take on the Chieftain — equip your best sword first.",
		Check = { Kind = "Flag", FlagId = Flags.GoblinChieftainDefeated },
		Target = { Tag = TAG_ENEMY, MatchAttribute = "EnemyDefinitionId", MatchValue = EnemyIds.GoblinChieftain },
	},
	{
		Id = S.AscendAdept,
		Title = "Ascend to Adept",
		Hint = "Open Ascend and complete the requirements to Ascend.",
		Check = { Kind = "Rank", RankId = AscensionIds.Adept },
	},
}
Definitions.Ordered = table.freeze(ordered)

-- SkillIds has no ById; build a quick lookup for validation only.
local skillLookup: { [string]: boolean } = {}
for _, id in SkillIds do
	if type(id) == "string" then
		skillLookup[id] = true
	end
end

local function validCheck(check: any): boolean
	if type(check) ~= "table" then
		return false
	end
	if check.Kind == "Flag" then
		return type(check.FlagId) == "string" and Flags.ById[check.FlagId] == true
	elseif check.Kind == "SkillLevel" then
		return skillLookup[check.SkillId] == true and type(check.Level) == "number" and check.Level >= 1 and check.Level % 1 == 0
	elseif check.Kind == "Acquire" then
		return type(check.FlagId) == "string" and Flags.ById[check.FlagId] == true and type(check.DefinitionId) == "string" and check.DefinitionId ~= ""
	elseif check.Kind == "Rank" then
		return type(check.RankId) == "string" and AscensionIds.ById[check.RankId] == true
	end
	return false
end

local function validProgress(progress: any): boolean
	if progress == nil then
		return true
	end
	if type(progress) ~= "table" then
		return false
	end
	if progress.Kind == "SkillLevel" then
		return skillLookup[progress.SkillId] == true and type(progress.Level) == "number" and progress.Level >= 1
	elseif progress.Kind == "Gold" then
		return type(progress.Threshold) == "number" and progress.Threshold > 0
	end
	return false
end

local function validTarget(target: any): boolean
	if target == nil then
		return true
	end
	if type(target) ~= "table" or type(target.Tag) ~= "string" or target.Tag == "" then
		return false
	end
	if target.MatchAttribute ~= nil or target.MatchValue ~= nil then
		return type(target.MatchAttribute) == "string" and target.MatchAttribute ~= "" and type(target.MatchValue) == "string" and target.MatchValue ~= ""
	end
	return true
end

-- Structural self-check so a malformed edit fails loudly at construction rather than at runtime.
function Definitions.Validate(candidate: any): (boolean, string?)
	if type(candidate) ~= "table" then
		return false, "Onboarding steps must be a table"
	end
	local seen: { [string]: boolean } = {}
	local knownStep: { [string]: boolean } = {}
	for _, stepId in stepIds do
		knownStep[stepId] = true
	end
	for _, step in candidate do
		if type(step) ~= "table" or type(step.Id) ~= "string" or not knownStep[step.Id] then
			return false, "Onboarding step IDs must be stable and known"
		end
		if seen[step.Id] then
			return false, "Onboarding step IDs must be unique"
		end
		seen[step.Id] = true
		if type(step.Title) ~= "string" or step.Title == "" or type(step.Hint) ~= "string" or step.Hint == "" then
			return false, "Onboarding steps require presentation text"
		end
		if not validCheck(step.Check) then
			return false, "Onboarding step Check must reference a valid authoritative fact"
		end
		if not validProgress(step.Progress) then
			return false, "Onboarding step Progress is malformed"
		end
		if not validTarget(step.Target) then
			return false, "Onboarding step Target is malformed"
		end
	end
	return true, nil
end

return table.freeze(Definitions)
