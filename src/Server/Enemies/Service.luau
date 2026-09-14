--!strict

local Definitions = require(script.Parent.Definitions)

export type Stats = {
	MaxHealth: number,
	Damage: number,
	GoldReward: number,
}
export type State = {
	RuntimeId: string,
	DefinitionId: string,
	Level: number,
	MaxHealth: number,
	Health: number,
	Damage: number,
	GoldReward: number,
	Alive: boolean,
}
export type Death = {
	RuntimeId: string,
	DefinitionId: string,
	Level: number,
	FinalDamage: number,
	GoldReward: number,
}
export type DamageResult = {
	Enemy: State,
	AppliedDamage: number,
	Death: Death?,
}
export type Runtime = {
	NewRuntimeId: () -> string,
	RollInteger: (number, number) -> number,
}
export type DistanceProvider = (number, State) -> (number?, string?)
export type CombatTarget = {
	Id: string,
	Eligible: boolean,
	Distance: number,
	ApplyDamage: (any) -> (number?, string?),
}
-- Boss contribution: attacking user ID -> total applied damage against one boss runtime instance.
export type Contribution = { [number]: number }

local MaximumSafeWhole = 9007199254740991
local Service = {}

local function validStableId(value: any): boolean
	return type(value) == "string" and value ~= ""
end

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= MaximumSafeWhole
end

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

local function finiteNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and math.abs(value) < math.huge
end

local function validLevel(value: any, levels: Definitions.LevelRange): boolean
	return type(value) == "number" and value % 1 == 0 and value >= levels.Minimum and value <= levels.Maximum
end

local function copyState(state: State): State
	return {
		RuntimeId = state.RuntimeId,
		DefinitionId = state.DefinitionId,
		Level = state.Level,
		MaxHealth = state.MaxHealth,
		Health = state.Health,
		Damage = state.Damage,
		GoldReward = state.GoldReward,
		Alive = state.Alive,
	}
end

local function copyDeath(death: Death): Death
	return {
		RuntimeId = death.RuntimeId,
		DefinitionId = death.DefinitionId,
		Level = death.Level,
		FinalDamage = death.FinalDamage,
		GoldReward = death.GoldReward,
	}
end

local function derive(definition: Definitions.Definition, level: number): (Stats?, string?)
	local offset = level - definition.LevelRange.Minimum
	local maxHealth = definition.Scaling.BaseHealth + definition.Scaling.HealthPerLevel * offset
	local damage = definition.Scaling.BaseDamage + definition.Scaling.DamagePerLevel * offset
	local goldReward = definition.Scaling.BaseGoldReward + definition.Scaling.GoldRewardPerLevel * offset
	if not finitePositive(maxHealth) or maxHealth > MaximumSafeWhole or not finitePositive(damage) or damage > MaximumSafeWhole or not finiteNonNegative(goldReward) or goldReward > MaximumSafeWhole then
		return nil, "InvalidDerivedStats"
	end
	return { MaxHealth = maxHealth, Damage = damage, GoldReward = goldReward }, nil
end

function Service.New(runtime: Runtime)
	assert(type(runtime) == "table" and type(runtime.NewRuntimeId) == "function" and type(runtime.RollInteger) == "function", "Enemies requires runtime ID and level roll sources")
	local valid, reason = Definitions.Validate(Definitions.ById)
	assert(valid, reason)

	local enemies: { [string]: State } = {}
	local pendingDeaths: { [string]: Death } = {}
	-- Only populated for boss-flagged definitions (Definitions.ById[...].Boss ~= nil); normal
	-- enemies never accumulate contribution.
	local contributions: { [string]: Contribution } = {}
	local service = {}

	local function definitionFor(definitionId: any): (Definitions.Definition?, string?)
		if not validStableId(definitionId) then
			return nil, "InvalidEnemyId"
		end
		local definition = Definitions.ById[definitionId]
		if not definition then
			return nil, "InvalidEnemyId"
		end
		return definition, nil
	end

	function service.GetDerivedStats(definitionId: string, level: number): (Stats?, string?)
		local definition, reason = definitionFor(definitionId)
		if not definition then
			return nil, reason
		end
		if not validLevel(level, definition.LevelRange) then
			return nil, "InvalidEnemyLevel"
		end
		return derive(definition, level)
	end

	function service.Create(definitionId: string): (State?, string?)
		local definition, reason = definitionFor(definitionId)
		if not definition then
			return nil, reason
		end
		local level = runtime.RollInteger(definition.LevelRange.Minimum, definition.LevelRange.Maximum)
		if not validLevel(level, definition.LevelRange) then
			return nil, "InvalidLevelRoll"
		end
		local stats, statsReason = derive(definition, level)
		if not stats then
			return nil, statsReason
		end
		local runtimeId = runtime.NewRuntimeId()
		if not validStableId(runtimeId) then
			return nil, "InvalidRuntimeId"
		end
		if enemies[runtimeId] or pendingDeaths[runtimeId] then
			return nil, "RuntimeIdCollision"
		end
		local state: State = {
			RuntimeId = runtimeId,
			DefinitionId = definition.Id,
			Level = level,
			MaxHealth = stats.MaxHealth,
			Health = stats.MaxHealth,
			Damage = stats.Damage,
			GoldReward = stats.GoldReward,
			Alive = true,
		}
		enemies[runtimeId] = state
		return copyState(state), nil
	end

	function service.GetSnapshot(runtimeId: string): (State?, string?)
		if not validStableId(runtimeId) then
			return nil, "InvalidRuntimeId"
		end
		local state = enemies[runtimeId]
		if not state then
			return nil, "EnemyNotFound"
		end
		return copyState(state), nil
	end

	function service.Remove(runtimeId: string): (State?, string?)
		if not validStableId(runtimeId) then
			return nil, "InvalidRuntimeId"
		end
		local state = enemies[runtimeId]
		if not state then
			return nil, "EnemyNotFound"
		end
		enemies[runtimeId] = nil
		contributions[runtimeId] = nil
		return copyState(state), nil
	end

	-- Read-only contribution summary for debugging/UI; never mutates state. An empty table is a
	-- valid summary (no boss-flagged damage recorded yet), not an error.
	function service.GetContribution(runtimeId: string): (Contribution?, string?)
		if not validStableId(runtimeId) then
			return nil, "InvalidRuntimeId"
		end
		local runtimeContribution = contributions[runtimeId]
		local result: Contribution = {}
		if runtimeContribution then
			for userId, amount in runtimeContribution do
				result[userId] = amount
			end
		end
		return result, nil
	end

	function service.ApplyDamage(runtimeId: string, amount: number): (DamageResult?, string?)
		if not validStableId(runtimeId) then
			return nil, "InvalidRuntimeId"
		end
		if not finitePositive(amount) then
			return nil, "InvalidDamage"
		end
		local state = enemies[runtimeId]
		if not state then
			return nil, "EnemyNotFound"
		end
		if not state.Alive then
			return nil, "EnemyDead"
		end
		local appliedDamage = math.min(amount, state.Health)
		state.Health -= appliedDamage
		local death: Death? = nil
		if state.Health <= 0 then
			state.Health = 0
			state.Alive = false
			death = {
				RuntimeId = state.RuntimeId,
				DefinitionId = state.DefinitionId,
				Level = state.Level,
				FinalDamage = appliedDamage,
				GoldReward = state.GoldReward,
			}
		end
		return { Enemy = copyState(state), AppliedDamage = appliedDamage, Death = death }, nil
	end

	-- Combat target adapters queue a death here so reward/presentation composition can consume it once.
	function service.ConsumeDeath(runtimeId: string): (Death?, string?)
		if not validStableId(runtimeId) then
			return nil, "InvalidRuntimeId"
		end
		local death = pendingDeaths[runtimeId]
		if not death then
			return nil, "DeathNotAvailable"
		end
		pendingDeaths[runtimeId] = nil
		return copyDeath(death), nil
	end

	function service.CreateCombatTargetResolver(distanceFor: DistanceProvider)
		assert(type(distanceFor) == "function", "Enemies requires a trusted distance provider")
		return function(attackerUserId: number, runtimeId: string): (CombatTarget?, string?)
			local state, reason = service.GetSnapshot(runtimeId)
			if not state then
				return nil, reason
			end
			local distance, distanceReason = distanceFor(attackerUserId, copyState(state))
			if type(distance) ~= "number" or not finiteNonNegative(distance) then
				return nil, distanceReason or "InvalidTargetDistance"
			end
			return {
				Id = state.RuntimeId,
				Eligible = state.Alive,
				Distance = distance,
				ApplyDamage = function(request: any): (number?, string?)
					if type(request) ~= "table" or request.TargetId ~= state.RuntimeId or not finitePositive(request.Damage) then
						return nil, "InvalidDamageRequest"
					end
					local result, damageReason = service.ApplyDamage(state.RuntimeId, request.Damage)
					if not result then
						return nil, damageReason
					end
					-- Attribute only the actual applied (already overkill-clamped) damage, and only
					-- for boss-flagged enemies -- normal Goblin combat is otherwise unaffected.
					local definition = Definitions.ById[state.DefinitionId]
					if definition and definition.Boss and validUserId(attackerUserId) then
						local runtimeContribution = contributions[state.RuntimeId]
						if not runtimeContribution then
							runtimeContribution = {}
							contributions[state.RuntimeId] = runtimeContribution
						end
						runtimeContribution[attackerUserId] = (runtimeContribution[attackerUserId] or 0) + result.AppliedDamage
					end
					if result.Death then
						pendingDeaths[state.RuntimeId] = copyDeath(result.Death)
					end
					return result.AppliedDamage, nil
				end,
			}, nil
		end
	end

	return table.freeze(service)
end

return table.freeze(Service)
