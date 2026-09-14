--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local EquipmentSlots = require(Shared.EquipmentSlots)
local ItemDefinitions = require(Shared.ItemDefinitions)
local SkillIds = require(Shared.SkillIds)

export type Equipment = {
	read GetEquippedItem: (number, string) -> (any?, string?),
}
export type Skills = {
	read AwardXP: (number, string, number) -> (any?, string?),
}
export type DamageRequest = {
	AttackerUserId: number,
	TargetId: string,
	WeaponInstanceId: string,
	WeaponDefinitionId: string,
	Damage: number,
}
export type Target = {
	Id: string,
	Eligible: boolean,
	Distance: number,
	ApplyDamage: (DamageRequest) -> (number?, string?),
}
export type TargetResolver = (number, string) -> (Target?, string?)
export type Configuration = {
	MeleeXPPerSuccessfulHit: number,
}
export type AttackResult = {
	AttackerUserId: number,
	TargetId: string,
	WeaponInstanceId: string,
	WeaponDefinitionId: string,
	Damage: number,
	AppliedDamage: number,
	AttackIntervalSeconds: number,
	AttackRange: number,
	MeleeXP: number,
	XPGranted: boolean,
	XPReason: string?,
}

local Service = {}

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

local function finiteNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and math.abs(value) < math.huge
end

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= 9007199254740991
end

local function validStableId(value: any): boolean
	return type(value) == "string" and value ~= ""
end

local function validMelee(data: any): boolean
	return type(data) == "table"
		and finitePositive(data.Damage)
		and finitePositive(data.AttackIntervalSeconds)
		and finitePositive(data.AttackRange)
end

function Service.New(equipment: Equipment, skills: Skills, resolveTarget: TargetResolver, configuration: Configuration, clock: () -> number)
	assert(type(equipment) == "table" and type(equipment.GetEquippedItem) == "function", "Combat requires Equipment")
	assert(type(skills) == "table" and type(skills.AwardXP) == "function", "Combat requires Skills")
	assert(type(resolveTarget) == "function", "Combat requires a trusted target resolver")
	assert(type(configuration) == "table" and finitePositive(configuration.MeleeXPPerSuccessfulHit), "Combat requires a positive Melee XP amount")
	assert(type(clock) == "function", "Combat requires a clock")

	local nextAttackAt: { [number]: number } = {}
	local service = {}

	function service.ResolveMeleeAttack(userId: number, targetId: string): (AttackResult?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not validStableId(targetId) then
			return nil, "InvalidTargetId"
		end
		local now = clock()
		if not finiteNonNegative(now) then
			return nil, "InvalidClock"
		end
		if nextAttackAt[userId] and now < nextAttackAt[userId] then
			return nil, "AttackOnCooldown"
		end

		local equipped, equippedReason = equipment.GetEquippedItem(userId, EquipmentSlots.Weapon)
		if type(equipped) ~= "table" then
			return nil, equippedReason or "NoMeleeWeapon"
		end
		local instanceId = equipped.InstanceId
		local definitionId = equipped.DefinitionId
		if type(instanceId) ~= "string" or instanceId == "" or type(definitionId) ~= "string" or definitionId == "" then
			return nil, "InvalidEquipment"
		end
		local definition = ItemDefinitions.ById[definitionId]
		local melee = if definition then definition.Melee else nil
		if not definition or definition.Kind ~= "Discrete" or not definition.Equipment or definition.Equipment.SlotId ~= EquipmentSlots.Weapon or not melee or not validMelee(melee) then
			return nil, "InvalidMeleeWeapon"
		end

		local target, targetReason = resolveTarget(userId, targetId)
		if not target then
			return nil, targetReason or "InvalidTarget"
		end
		if target.Id ~= targetId or not finiteNonNegative(target.Distance) or type(target.ApplyDamage) ~= "function" then
			return nil, "InvalidTarget"
		end
		if target.Eligible ~= true then
			return nil, "IneligibleTarget"
		end
		if target.Distance > melee.AttackRange then
			return nil, "TargetOutOfRange"
		end

		local request: DamageRequest = {
			AttackerUserId = userId,
			TargetId = targetId,
			WeaponInstanceId = instanceId,
			WeaponDefinitionId = definition.Id,
			Damage = melee.Damage,
		}
		local appliedDamage, damageReason = target.ApplyDamage(request)
		if type(appliedDamage) ~= "number" or not finitePositive(appliedDamage) or appliedDamage > request.Damage then
			return nil, damageReason or "NoMeaningfulDamage"
		end

		nextAttackAt[userId] = now + melee.AttackIntervalSeconds
		local _, xpReason = skills.AwardXP(userId, SkillIds.Melee, configuration.MeleeXPPerSuccessfulHit)
		return {
			AttackerUserId = userId,
			TargetId = targetId,
			WeaponInstanceId = instanceId,
			WeaponDefinitionId = definition.Id,
			Damage = request.Damage,
			AppliedDamage = appliedDamage,
			AttackIntervalSeconds = melee.AttackIntervalSeconds,
			AttackRange = melee.AttackRange,
			MeleeXP = configuration.MeleeXPPerSuccessfulHit,
			XPGranted = xpReason == nil,
			XPReason = xpReason,
		}, nil
	end

	return table.freeze(service)
end

return table.freeze(Service)
