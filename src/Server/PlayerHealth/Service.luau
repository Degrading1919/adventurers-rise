--!strict

-- Server-owned runtime player health for the vertical slice. This is ephemeral combat state, never
-- persisted: it resets to full on (re)spawn and is cleared on disconnect, so death never touches
-- PlayerData (Gold, items, XP, progression are untouched). It is the single authority for how much
-- health a player has; the client only displays it and enemy attacks only apply through ApplyDamage.

export type State = {
	Health: number,
	MaxHealth: number,
}
export type DamageResult = {
	Health: number,
	MaxHealth: number,
	AppliedDamage: number,
	Died: boolean,
}
export type Configuration = {
	MaxHealth: number,
}

local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

function Service.New(configuration: Configuration)
	assert(type(configuration) == "table" and finitePositive(configuration.MaxHealth), "PlayerHealth requires a positive MaxHealth")
	local maxHealth = configuration.MaxHealth

	-- userId -> current health. A missing entry means "not yet damaged this life" and reads as full,
	-- so a freshly spawned player is always at maximum without needing an explicit initialisation call.
	local health: { [number]: number } = {}
	local service = {}

	local function currentHealth(userId: number): number
		local value = health[userId]
		if value == nil then
			return maxHealth
		end
		return value
	end

	function service.Reset(userId: number): (State?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		health[userId] = maxHealth
		return { Health = maxHealth, MaxHealth = maxHealth }, nil
	end

	function service.Clear(userId: number)
		health[userId] = nil
	end

	function service.GetState(userId: number): (State?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		return { Health = currentHealth(userId), MaxHealth = maxHealth }, nil
	end

	function service.IsAlive(userId: number): boolean
		if not validUserId(userId) then
			return false
		end
		return currentHealth(userId) > 0
	end

	-- Applies incoming damage to runtime health. Fails closed on a dead or invalid target rather than
	-- fabricating a hit. Reports whether this hit was lethal so the caller can trigger the death flow.
	function service.ApplyDamage(userId: number, amount: number): (DamageResult?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not finitePositive(amount) then
			return nil, "InvalidDamage"
		end
		local current = currentHealth(userId)
		if current <= 0 then
			return nil, "AlreadyDead"
		end
		local applied = math.min(amount, current)
		current -= applied
		if current < 0 then
			current = 0
		end
		health[userId] = current
		return { Health = current, MaxHealth = maxHealth, AppliedDamage = applied, Died = current <= 0 }, nil
	end

	return table.freeze(service)
end

return table.freeze(Service)
