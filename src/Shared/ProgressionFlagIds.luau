--!strict

-- Persist these IDs. Add future progression milestones without changing existing values.
-- Values are ProgressionFlags keys; only trusted server code may set them (see
-- Server/Ascension/Service.luau's RecordBossMilestone and Server/Onboarding/Service.luau).
--
-- The Onboarding* flags are the one-time HISTORICAL onboarding milestones that cannot be safely
-- reconstructed from current transient state (a defeated Goblin leaves no durable trace; ore/bars can
-- be consumed; Gold can be spent; a bought/crafted sword can be sold). Steps whose completion IS
-- provable from an existing permanent fact -- Melee/Defense level, Adept rank, and the shared boss
-- kill (GoblinChieftainDefeated, reused) -- deliberately have no dedicated flag.
local ids: { [string]: string } = {
	GoblinChieftainDefeated = "flag_boss_goblin_chieftain_defeated",
	StarterKitGranted = "flag_starter_kit_granted",
	OnboardingStarterFocusAcknowledged = "flag_onboarding_starter_focus_acknowledged",
	OnboardingTrainingRewardGranted = "flag_onboarding_training_reward_granted",
	OnboardingFirstGoblinDefeated = "flag_onboarding_first_goblin_defeated",
	OnboardingGoldMilestoneReached = "flag_onboarding_gold_milestone_reached",
	OnboardingFirstOreGathered = "flag_onboarding_first_ore_gathered",
	OnboardingFirstBarSmithed = "flag_onboarding_first_bar_smithed",
	OnboardingUpgradedWeaponAcquired = "flag_onboarding_upgraded_weapon_acquired",
}

local byId: { [string]: boolean } = {}
for _, id in ids do
	byId[id] = true
end

local ProgressionFlagIds: { [string]: any } = table.clone(ids)
ProgressionFlagIds.ById = table.freeze(byId)

return table.freeze(ProgressionFlagIds)
