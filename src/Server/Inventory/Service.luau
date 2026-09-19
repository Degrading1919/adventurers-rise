--!strict

local ItemDefinitions = require(game:GetService("ReplicatedStorage").Shared.ItemDefinitions)

export type DiscreteItem = {
	InstanceId: string,
	DefinitionId: string,
}
export type Snapshot = {
	Stacks: { [string]: number },
	Items: { [string]: { DefinitionId: string } },
}
export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type Runtime = {
	NewInstanceId: () -> string,
}

local Service = { MaximumStack = 9007199254740991 }

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= Service.MaximumStack
end

local function validAmount(amount: any): boolean
	return type(amount) == "number" and amount > 0 and amount <= Service.MaximumStack and amount % 1 == 0
end

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = copy(child)
	end
	return result
end

function Service.New(playerData: PlayerData, runtime: Runtime)
	assert(type(playerData) == "table", "Inventory requires a PlayerData service")
	assert(type(runtime) == "table" and type(runtime.NewInstanceId) == "function", "Inventory requires an instance ID generator")

	local service = {}

	local function definitionFor(definitionId: any, kind: ItemDefinitions.Kind?): (ItemDefinitions.Definition?, string?)
		if type(definitionId) ~= "string" then
			return nil, "InvalidItemDefinitionId"
		end
		local definition = ItemDefinitions.ById[definitionId]
		if not definition or (kind and definition.Kind ~= kind) then
			return nil, "InvalidItemDefinitionId"
		end
		return definition, nil
	end

	local function inventoryFor(userId: number): (Snapshot?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		local inventory = data.Inventory
		if type(inventory) ~= "table" or type(inventory.Stacks) ~= "table" or type(inventory.Items) ~= "table" then
			return nil, "InvalidInventory"
		end
		return inventory, nil
	end

	function service.GetSnapshot(userId: number): (Snapshot?, string?)
		local inventory, reason = inventoryFor(userId)
		return if inventory then copy(inventory) else nil, reason
	end

	-- Reads a stackable count from a caller's own transactional `data` snapshot (0 when absent), so an
	-- in-transaction system (e.g. batch Crafting computing an affordable quantity) reads the same data
	-- it is about to mutate. Inventory remains the owner of its structure.
	function service.GetStackFromData(data: any, definitionId: string): (number?, string?)
		local _, definitionReason = definitionFor(definitionId, "Stackable")
		if definitionReason then
			return nil, definitionReason
		end
		local inventory = data.Inventory
		if type(inventory) ~= "table" or type(inventory.Stacks) ~= "table" then
			return nil, "InvalidInventory"
		end
		local amount = inventory.Stacks[definitionId] or 0
		if amount ~= 0 and not validAmount(amount) then
			return nil, "InvalidInventory"
		end
		return amount, nil
	end

	function service.GetStackCount(userId: number, definitionId: string): (number?, string?)
		local _, definitionReason = definitionFor(definitionId, "Stackable")
		if definitionReason then
			return nil, definitionReason
		end
		local inventory, reason = inventoryFor(userId)
		if not inventory then
			return nil, reason
		end
		local amount = inventory.Stacks[definitionId] or 0
		if not validAmount(amount) and amount ~= 0 then
			return nil, "InvalidInventory"
		end
		return amount, nil
	end

	function service.GetDiscreteItem(userId: number, instanceId: string): (DiscreteItem?, string?)
		if type(instanceId) ~= "string" or instanceId == "" then
			return nil, "InvalidInstanceId"
		end
		local inventory, reason = inventoryFor(userId)
		if not inventory then
			return nil, reason
		end
		local item = inventory.Items[instanceId]
		if type(item) ~= "table" or type(item.DefinitionId) ~= "string" or item.DefinitionId == "" then
			return nil, if item then "InvalidInventory" else "ItemNotOwned"
		end
		local definitionId = item.DefinitionId :: string
		local _, definitionReason = definitionFor(definitionId, "Discrete")
		if definitionReason then
			return nil, "InvalidInventory"
		end
		return { InstanceId = instanceId, DefinitionId = definitionId }, nil
	end

	-- Trusted server compositions may use this inside one PlayerData.Update transaction.
	function service.AddStackToData(data: any, definitionId: string, amount: number): (number?, string?)
		local _, definitionReason = definitionFor(definitionId, "Stackable")
		if definitionReason then
			return nil, definitionReason
		end
		if not validAmount(amount) then
			return nil, "InvalidAmount"
		end
		local inventory = data.Inventory
		if type(inventory) ~= "table" or type(inventory.Stacks) ~= "table" then
			return nil, "InvalidInventory"
		end
		local current = inventory.Stacks[definitionId] or 0
		if current ~= 0 and not validAmount(current) then
			return nil, "InvalidInventory"
		end
		local nextAmount = current + amount
		if not validAmount(nextAmount) then
			return nil, "AmountOutOfBounds"
		end
		inventory.Stacks[definitionId] = nextAmount
		return nextAmount, nil
	end

	-- Trusted server compositions may use this inside one PlayerData.Update transaction.
	function service.RemoveStackFromData(data: any, definitionId: string, amount: number): (number?, string?)
		local _, definitionReason = definitionFor(definitionId, "Stackable")
		if definitionReason then
			return nil, definitionReason
		end
		if not validAmount(amount) then
			return nil, "InvalidAmount"
		end
		local inventory = data.Inventory
		if type(inventory) ~= "table" or type(inventory.Stacks) ~= "table" then
			return nil, "InvalidInventory"
		end
		local current = inventory.Stacks[definitionId]
		if not validAmount(current) or amount > current then
			return nil, "InsufficientItems"
		end
		local nextAmount = current - amount
		if nextAmount == 0 then
			inventory.Stacks[definitionId] = nil
		else
			inventory.Stacks[definitionId] = nextAmount
		end
		return nextAmount, nil
	end

	function service.AddStack(userId: number, definitionId: string, amount: number): (number?, string?)
		local _, definitionReason = definitionFor(definitionId, "Stackable")
		if definitionReason then
			return nil, definitionReason
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validAmount(amount) then
			return nil, "InvalidAmount"
		end
		local result: number? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			result, mutationReason = service.AddStackToData(data, definitionId, amount)
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	function service.RemoveStack(userId: number, definitionId: string, amount: number): (number?, string?)
		local _, definitionReason = definitionFor(definitionId, "Stackable")
		if definitionReason then
			return nil, definitionReason
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validAmount(amount) then
			return nil, "InvalidAmount"
		end
		local result: number? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			result, mutationReason = service.RemoveStackFromData(data, definitionId, amount)
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	-- Trusted server compositions may use this inside one PlayerData.Update transaction.
	-- The sole source of discrete instance IDs: always Inventory's own runtime, never a caller-supplied value.
	function service.AddDiscreteItemToData(data: any, definitionId: string): (DiscreteItem?, string?)
		local _, definitionReason = definitionFor(definitionId, "Discrete")
		if definitionReason then
			return nil, definitionReason
		end
		local inventory = data.Inventory
		if type(inventory) ~= "table" or type(inventory.Items) ~= "table" then
			return nil, "InvalidInventory"
		end
		local generated, instanceId = pcall(runtime.NewInstanceId)
		if not generated or type(instanceId) ~= "string" or instanceId == "" then
			return nil, "InvalidGeneratedInstanceId"
		end
		if inventory.Items[instanceId] then
			return nil, "InstanceIdCollision"
		end
		inventory.Items[instanceId] = { DefinitionId = definitionId }
		return { InstanceId = instanceId, DefinitionId = definitionId }, nil
	end

	function service.AddDiscreteItem(userId: number, definitionId: string): (DiscreteItem?, string?)
		local _, definitionReason = definitionFor(definitionId, "Discrete")
		if definitionReason then
			return nil, definitionReason
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local result: DiscreteItem? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			result, mutationReason = service.AddDiscreteItemToData(data, definitionId)
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	function service.RemoveDiscreteItem(userId: number, instanceId: string): (DiscreteItem?, string?)
		if type(instanceId) ~= "string" or instanceId == "" then
			return nil, "InvalidInstanceId"
		end
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local result: DiscreteItem? = nil
		local mutationReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			local inventory = data.Inventory
			local equipment = data.Equipment
			if type(inventory) ~= "table" or type(inventory.Items) ~= "table" then
				mutationReason = "InvalidInventory"
				return
			end
			if type(equipment) ~= "table" then
				mutationReason = "InvalidEquipment"
				return
			end
			local item = inventory.Items[instanceId]
			if type(item) ~= "table" or type(item.DefinitionId) ~= "string" or item.DefinitionId == "" then
				mutationReason = if item then "InvalidInventory" else "ItemNotOwned"
				return
			end
			local definitionId = item.DefinitionId :: string
			local _, definitionReason = definitionFor(definitionId, "Discrete")
			if definitionReason then
				mutationReason = "InvalidInventory"
				return
			end
			for _, equippedInstanceId in equipment do
				if equippedInstanceId == instanceId then
					mutationReason = "ItemEquipped"
					return
				end
			end
			inventory.Items[instanceId] = nil
			result = { InstanceId = instanceId, DefinitionId = definitionId }
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		return result, mutationReason
	end

	return table.freeze(service)
end

return table.freeze(Service)
