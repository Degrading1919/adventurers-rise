--!strict

-- Server-authoritative, duplicate-safe first-time starter kit. On the first ready session for a
-- player, one atomic PlayerData transaction grants the starter sword and basic pickaxe and sets a
-- persistent progression flag; the flag is checked inside that same transaction, so a rejoin (or a
-- concurrent second call) never grants a second kit. Equipping is a separate, idempotent step that
-- only fills an EMPTY weapon/tool slot, so it never overwrites an upgrade the player has since
-- equipped. The client cannot request this grant; it is triggered by the server's ready lifecycle.

local Shared = game:GetService("ReplicatedStorage").Shared
local EquipmentSlots = require(Shared.EquipmentSlots)
local ProgressionFlagIds = require(Shared.ProgressionFlagIds)

export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type Inventory = {
	read GetSnapshot: (number) -> (any?, string?),
	read AddDiscreteItemToData: (any, string) -> (any?, string?),
}
export type Equipment = {
	read GetEquippedItem: (number, string) -> (any?, string?),
	read Equip: (number, string, string) -> (any?, string?),
}
export type Summary = {
	Granted: boolean,
	Equipped: { [string]: boolean },
	Reason: string?,
}

-- Provisional starter kit contents. Stable item and slot IDs, never display names. Ordered so the
-- weapon is granted/equipped before the tool.
local STARTER_ITEMS: { { DefinitionId: string, SlotId: string } } = {
	{ DefinitionId = "weapon_sword_starter", SlotId = EquipmentSlots.Weapon },
	{ DefinitionId = "tool_pickaxe_basic", SlotId = EquipmentSlots.Tool },
}
local FLAG_ID = ProgressionFlagIds.StarterKitGranted

local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

function Service.New(playerData: PlayerData, inventory: Inventory, equipment: Equipment)
	assert(type(playerData) == "table" and type(playerData.GetSnapshot) == "function" and type(playerData.Update) == "function", "StarterKit requires PlayerData")
	assert(type(inventory) == "table" and type(inventory.GetSnapshot) == "function" and type(inventory.AddDiscreteItemToData) == "function", "StarterKit requires Inventory")
	assert(type(equipment) == "table" and type(equipment.GetEquippedItem) == "function" and type(equipment.Equip) == "function", "StarterKit requires Equipment")

	local service = {}

	local function ownedInstanceId(userId: number, definitionId: string): string?
		local snapshot = inventory.GetSnapshot(userId)
		if type(snapshot) ~= "table" or type(snapshot.Items) ~= "table" then
			return nil
		end
		for instanceId, item in snapshot.Items do
			if type(item) == "table" and item.DefinitionId == definitionId and type(instanceId) == "string" then
				return instanceId
			end
		end
		return nil
	end

	-- Idempotent: only equips into an empty slot, so it re-arms a starter item after an interrupted
	-- first grant but never displaces an upgrade the player equipped later.
	local function ensureEquipped(userId: number, slotId: string, definitionId: string): boolean
		local equipped = equipment.GetEquippedItem(userId, slotId)
		if type(equipped) == "table" then
			return equipped.DefinitionId == definitionId
		end
		local instanceId = ownedInstanceId(userId, definitionId)
		if not instanceId then
			return false
		end
		local result = equipment.Equip(userId, slotId, instanceId)
		return type(result) == "table"
	end

	function service.EnsureForUser(userId: number): (Summary?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end

		local granted = false
		local mutationReason: string? = nil
		local function abort(reason: string)
			mutationReason = reason
			error(reason, 0)
		end
		-- One atomic grant transaction. The flag is read and written inside it, so the grant happens
		-- at most once across any number of rejoins or concurrent calls.
		local ok, updateReason = playerData.Update(userId, function(data)
			local flags = data.ProgressionFlags
			if type(flags) ~= "table" then
				abort("InvalidProgressionFlags")
			end
			if flags[FLAG_ID] == true then
				return
			end
			for _, entry in STARTER_ITEMS do
				local item, addReason = inventory.AddDiscreteItemToData(data, entry.DefinitionId)
				if not item then
					abort(addReason or "StarterGrantFailed")
				end
			end
			flags[FLAG_ID] = true
			granted = true
		end)
		if not ok then
			return nil, mutationReason or updateReason or "PlayerDataUpdateFailed"
		end

		-- Equip step runs whether or not this call performed the grant, so an interrupted earlier
		-- grant still ends up equipped on the next ready session.
		local equippedSummary: { [string]: boolean } = {}
		for _, entry in STARTER_ITEMS do
			equippedSummary[entry.SlotId] = ensureEquipped(userId, entry.SlotId, entry.DefinitionId)
		end

		return { Granted = granted, Equipped = equippedSummary, Reason = nil }, nil
	end

	return table.freeze(service)
end

return table.freeze(Service)
