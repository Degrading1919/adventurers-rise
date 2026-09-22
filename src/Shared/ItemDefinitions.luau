--!strict

local EquipmentSlots = require(game:GetService("ReplicatedStorage").Shared.EquipmentSlots)

export type Kind = "Stackable" | "Discrete"
export type Equipment = {
	read SlotId: string,
	read EffectivenessTier: number,
}
export type Melee = {
	read Damage: number,
	read AttackIntervalSeconds: number,
	read AttackRange: number,
}
export type Mining = {
	read GatheringRateMultiplier: number,
}
export type Definition = {
	read Id: string,
	read Kind: Kind,
	read Equipment: Equipment?,
	read Melee: Melee?,
	read Mining: Mining?,
}

local function equipment(slotId: string, effectivenessTier: number): Equipment
	return table.freeze({ SlotId = slotId, EffectivenessTier = effectivenessTier })
end

local function melee(damage: number, attackIntervalSeconds: number, attackRange: number): Melee
	return table.freeze({
		Damage = damage,
		AttackIntervalSeconds = attackIntervalSeconds,
		AttackRange = attackRange,
	})
end

local function mining(gatheringRateMultiplier: number): Mining
	return table.freeze({ GatheringRateMultiplier = gatheringRateMultiplier })
end

local function definition(id: string, kind: Kind, equipmentData: Equipment?, meleeData: Melee?, miningData: Mining?): Definition
	return table.freeze({ Id = id, Kind = kind, Equipment = equipmentData, Melee = meleeData, Mining = miningData })
end

-- Persist these IDs. Tiers, melee, and mining values are provisional centralized balance data.
local definitions: { [string]: Definition } = {
	item_iron_ore = definition("item_iron_ore", "Stackable"),
	item_iron_bar = definition("item_iron_bar", "Stackable"),
	weapon_sword_starter = definition("weapon_sword_starter", "Discrete", equipment(EquipmentSlots.Weapon, 1), melee(10, 1, 8)),
	weapon_sword_upgraded = definition("weapon_sword_upgraded", "Discrete", equipment(EquipmentSlots.Weapon, 2), melee(15, 0.8, 9)),
	tool_pickaxe_basic = definition("tool_pickaxe_basic", "Discrete", equipment(EquipmentSlots.Tool, 1), nil, mining(1)),
	tool_pickaxe_upgraded = definition("tool_pickaxe_upgraded", "Discrete", equipment(EquipmentSlots.Tool, 2), nil, mining(2)),
	-- Rare Goblin Chieftain boss material; the minimum new item ID needed to demonstrate rare boss loot.
	item_chieftain_fang = definition("item_chieftain_fang", "Stackable"),
	-- Rare Bandit Warlord boss material (the ruined-tower captain's seal); the minimum new item ID for
	-- the second boss's rare drop, mirroring the Chieftain Fang.
	item_warlord_seal = definition("item_warlord_seal", "Stackable"),
}

return table.freeze({
	ById = table.freeze(definitions),
})
