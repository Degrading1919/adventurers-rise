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
export type Armor = {
	-- Fraction of incoming damage this piece mitigates (0..1). Pieces stack additively; the
	-- server clamps the equipped total inside the existing IncomingDamageReduction ceiling.
	read DamageReduction: number,
}
export type Definition = {
	read Id: string,
	read Kind: Kind,
	read Equipment: Equipment?,
	read Melee: Melee?,
	read Mining: Mining?,
	read Armor: Armor?,
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

local function armor(damageReduction: number): Armor
	return table.freeze({ DamageReduction = damageReduction })
end

local function definition(
	id: string,
	kind: Kind,
	equipmentData: Equipment?,
	meleeData: Melee?,
	miningData: Mining?,
	armorData: Armor?
): Definition
	return table.freeze({
		Id = id,
		Kind = kind,
		Equipment = equipmentData,
		Melee = meleeData,
		Mining = miningData,
		Armor = armorData,
	})
end

-- Persist these IDs. Tiers, melee, and mining values are provisional centralized balance data.
local definitions: { [string]: Definition } = {
	item_iron_ore = definition("item_iron_ore", "Stackable"),
	item_iron_bar = definition("item_iron_bar", "Stackable"),
	-- Second resource + second smelted metal: Coal is gathered from its own node and combined with an
	-- Iron Bar to smelt a Steel Bar, the tier-2 crafting material behind the steel weapon+armour tier.
	item_coal = definition("item_coal", "Stackable"),
	item_steel_bar = definition("item_steel_bar", "Stackable"),
	-- Raw gem: the rare byproduct of mining with the Mining "Prospecting" mastery. Sold to the shop for
	-- Gold, so Prospecting is a distinct payoff (Gold) versus Extraction (more ore for crafting).
	item_raw_gem = definition("item_raw_gem", "Stackable"),
	weapon_sword_starter = definition("weapon_sword_starter", "Discrete", equipment(EquipmentSlots.Weapon, 1), melee(10, 1, 8)),
	weapon_sword_upgraded = definition("weapon_sword_upgraded", "Discrete", equipment(EquipmentSlots.Weapon, 2), melee(15, 0.8, 9)),
	-- Tier-2 steel sword: the top of the current weapon ladder (starter -> upgraded iron -> steel).
	weapon_sword_steel = definition("weapon_sword_steel", "Discrete", equipment(EquipmentSlots.Weapon, 3), melee(22, 0.75, 9)),
	tool_pickaxe_basic = definition("tool_pickaxe_basic", "Discrete", equipment(EquipmentSlots.Tool, 1), nil, mining(1)),
	tool_pickaxe_upgraded = definition("tool_pickaxe_upgraded", "Discrete", equipment(EquipmentSlots.Tool, 2), nil, mining(2)),
	-- Iron armour set (first armour tier). Head/Body/Legs each mitigate a slice of incoming damage;
	-- the full set totals 0.16 (well under the server's IncomingDamageReduction ceiling), so armour
	-- meaningfully eases harder zones without trivialising combat. Craftable from Iron Bars (Smithing).
	armor_iron_helm = definition("armor_iron_helm", "Discrete", equipment(EquipmentSlots.Head, 1), nil, nil, armor(0.04)),
	armor_iron_body = definition("armor_iron_body", "Discrete", equipment(EquipmentSlots.Body, 1), nil, nil, armor(0.07)),
	armor_iron_legs = definition("armor_iron_legs", "Discrete", equipment(EquipmentSlots.Legs, 1), nil, nil, armor(0.05)),
	-- Tier-2 steel armour set: out-protects iron (full set 0.24 vs iron's 0.16) so the player survives
	-- noticeably longer in the harder, deeper zones (a soft easing, not a hard gate). Crafted from Steel
	-- Bars (Iron Bar + Coal), so it sits behind the second resource.
	armor_steel_helm = definition("armor_steel_helm", "Discrete", equipment(EquipmentSlots.Head, 2), nil, nil, armor(0.06)),
	armor_steel_body = definition("armor_steel_body", "Discrete", equipment(EquipmentSlots.Body, 2), nil, nil, armor(0.10)),
	armor_steel_legs = definition("armor_steel_legs", "Discrete", equipment(EquipmentSlots.Legs, 2), nil, nil, armor(0.08)),
	-- Rare Goblin Chieftain boss material; the minimum new item ID needed to demonstrate rare boss loot.
	item_chieftain_fang = definition("item_chieftain_fang", "Stackable"),
	-- Rare Bandit Warlord boss material (the ruined-tower captain's seal); the minimum new item ID for
	-- the second boss's rare drop, mirroring the Chieftain Fang.
	item_warlord_seal = definition("item_warlord_seal", "Stackable"),
}

return table.freeze({
	ById = table.freeze(definitions),
})
