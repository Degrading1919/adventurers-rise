--!strict

-- Stable, centralized request IDs for the vertical-slice client/server request surface. Services
-- never see these directly; only Composition's dispatch table and (eventually) the transport layer
-- reference them, so no literal request-name strings are scattered through gameplay code.
local ids: { [string]: string } = {
	StateGet = "state_get",
	EquipmentEquip = "equipment_equip",
	EquipmentUnequip = "equipment_unequip",
	EconomyPurchaseStack = "economy_purchase_stack",
	EconomySellStack = "economy_sell_stack",
	EconomyPurchaseDiscrete = "economy_purchase_discrete",
	EconomySellDiscrete = "economy_sell_discrete",
	PlotUpgradeStation = "plot_upgrade_station",
	OfflineTrainingSetFocus = "offline_training_set_focus",
	MasterySelectNode = "mastery_select_node",
	MasteryRespec = "mastery_respec",
	CraftingCraft = "crafting_craft",
	AscensionAscend = "ascension_ascend",
	CombatMeleeAttack = "combat_melee_attack",
	GatheringBegin = "gathering_begin",
	GatheringEnd = "gathering_end",
	TrainingBegin = "training_begin",
	TrainingEnd = "training_end",
	OnboardingAcknowledgeStarterFocus = "onboarding_acknowledge_starter_focus",
	-- Client asks the server to check whether the player has physically entered a new discoverable zone;
	-- the server resolves the real position and grants a one-time first-visit reward if so.
	RegionDiscoverCurrentZone = "region_discover_current_zone",
}

local byId: { [string]: boolean } = {}
for _, id in ids do
	byId[id] = true
end

local RequestIds: { [string]: any } = table.clone(ids)
RequestIds.ById = table.freeze(byId)

return table.freeze(RequestIds)
