--!strict

local EquipmentSlots = require(game:GetService("ReplicatedStorage").Shared.EquipmentSlots)

export type Kind = "Stackable" | "Discrete"
export type Equipment = {
	read SlotId: string,
	read EffectivenessTier: number,
}
export type Definition = {
	read Id: string,
	read Kind: Kind,
	read Equipment: Equipment?,
}

local function equipment(slotId: string, effectivenessTier: number): Equipment
	return table.freeze({ SlotId = slotId, EffectivenessTier = effectivenessTier })
end

local function definition(id: string, kind: Kind, equipmentData: Equipment?): Definition
	return table.freeze({ Id = id, Kind = kind, Equipment = equipmentData })
end

-- Persist these IDs. Tiers are provisional normalized effectiveness data, not final balance values.
local definitions: { [string]: Definition } = {
	item_iron_ore = definition("item_iron_ore", "Stackable"),
	item_iron_bar = definition("item_iron_bar", "Stackable"),
	weapon_sword_starter = definition("weapon_sword_starter", "Discrete", equipment(EquipmentSlots.Weapon, 1)),
	weapon_sword_upgraded = definition("weapon_sword_upgraded", "Discrete", equipment(EquipmentSlots.Weapon, 2)),
	tool_pickaxe_basic = definition("tool_pickaxe_basic", "Discrete", equipment(EquipmentSlots.Tool, 1)),
	tool_pickaxe_upgraded = definition("tool_pickaxe_upgraded", "Discrete", equipment(EquipmentSlots.Tool, 2)),
}

return table.freeze({
	ById = table.freeze(definitions),
})
