--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local EquipmentSlots = require(Shared.EquipmentSlots)
local ItemDefinitions = require(Shared.ItemDefinitions)

export type EquippedItem = {
	SlotId: string,
	InstanceId: string,
	DefinitionId: string,
	EffectivenessTier: number,
}
export type Snapshot = { [string]: EquippedItem }
export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}

local MaximumUserId = 9007199254740991
local Service = {}

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= MaximumUserId
end

local function validInstanceId(instanceId: any): boolean
	return type(instanceId) == "string" and instanceId ~= ""
end

local function validSlotId(slotId: any): boolean
	return type(slotId) == "string" and EquipmentSlots.ById[slotId] == true
end

function Service.New(playerData: PlayerData)
	assert(type(playerData) == "table", "Equipment requires a PlayerData service")

	local service = {}

	local function itemFor(data: any, slotId: string, instanceId: string): (EquippedItem?, string?)
		local inventory = data.Inventory
		if type(inventory) ~= "table" or type(inventory.Items) ~= "table" then
			return nil, "InvalidInventory"
		end
		local item = inventory.Items[instanceId]
		if type(item) ~= "table" or not validInstanceId(item.DefinitionId) then
			return nil, "InvalidEquipment"
		end
		local definition = ItemDefinitions.ById[item.DefinitionId]
		if not definition or definition.Kind ~= "Discrete" or not definition.Equipment then
			return nil, "InvalidEquipment"
		end
		if definition.Equipment.SlotId ~= slotId then
			return nil, "InvalidEquipment"
		end
		return {
			SlotId = slotId,
			InstanceId = instanceId,
			DefinitionId = definition.Id,
			EffectivenessTier = definition.Equipment.EffectivenessTier,
		}, nil
	end

	local function equipmentFor(data: any): ({ [string]: string }?, string?)
		if type(data.Equipment) ~= "table" then
			return nil, "InvalidEquipment"
		end
		return data.Equipment, nil
	end

	function service.GetSnapshot(userId: number): (Snapshot?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local equipment, reason = equipmentFor(data)
		if not equipment then
			return nil, reason
		end
		local result: Snapshot = {}
		for slotId, instanceId in equipment do
			if not validSlotId(slotId) or not validInstanceId(instanceId) then
				return nil, "InvalidEquipment"
			end
			local equippedItem, itemReason = itemFor(data, slotId, instanceId)
			if not equippedItem then
				return nil, itemReason
			end
			result[slotId] = equippedItem
		end
		return result, nil
	end

	function service.GetEquippedItem(userId: number, slotId: string): (EquippedItem?, string?)
		if not validSlotId(slotId) then
			return nil, "InvalidSlotId"
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local equipment, reason = equipmentFor(data)
		if not equipment then
			return nil, reason
		end
		local instanceId = equipment[slotId]
		if instanceId == nil then
			return nil, "NotEquipped"
		end
		if not validInstanceId(instanceId) then
			return nil, "InvalidEquipment"
		end
		return itemFor(data, slotId, instanceId)
	end

	function service.Equip(userId: number, slotId: string, instanceId: string): (EquippedItem?, string?)
		if not validSlotId(slotId) then
			return nil, "InvalidSlotId"
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validInstanceId(instanceId) then
			return nil, "InvalidInstanceId"
		end

		local result: EquippedItem? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			local equipment, equipmentReason = equipmentFor(data)
			if not equipment then
				mutationReason = equipmentReason
				return
			end
			for existingSlotId, existingInstanceId in equipment do
				if existingSlotId ~= slotId and existingInstanceId == instanceId then
					mutationReason = "ItemAlreadyEquipped"
					return
				end
			end
			local equippedItem, itemReason = itemFor(data, slotId, instanceId)
			if not equippedItem then
				local inventory = data.Inventory
				if itemReason == "InvalidEquipment" and type(inventory) == "table" and type(inventory.Items) == "table" and inventory.Items[instanceId] == nil then
					mutationReason = "ItemNotOwned"
				else
					mutationReason = itemReason
				end
				return
			end
			equipment[slotId] = instanceId
			result = equippedItem
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	function service.Unequip(userId: number, slotId: string): (EquippedItem?, string?)
		if not validSlotId(slotId) then
			return nil, "InvalidSlotId"
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end

		local result: EquippedItem? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			local equipment, equipmentReason = equipmentFor(data)
			if not equipment then
				mutationReason = equipmentReason
				return
			end
			local instanceId = equipment[slotId]
			if instanceId == nil then
				mutationReason = "NotEquipped"
				return
			end
			if not validInstanceId(instanceId) then
				mutationReason = "InvalidEquipment"
				return
			end
			local equippedItem, itemReason = itemFor(data, slotId, instanceId)
			if not equippedItem then
				mutationReason = itemReason
				return
			end
			equipment[slotId] = nil
			result = equippedItem
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	return table.freeze(service)
end

return table.freeze(Service)
