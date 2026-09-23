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
-- Server-owned Mastery modifier totals for the attacker's Melee tree (see Mastery.GetModifiers, the
-- single source of truth). Combat only READS the totals it cares about; it never recomputes node logic.
export type ModifierTotals = { [string]: number }
export type MeleeModifierProvider = (number) -> ModifierTotals
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
	-- How many nearby secondary enemies took Cleave splash damage this hit (0 without the mastery).
	CleaveHits: number,
	-- Runtime ids of the cleaved secondary enemies, so the reward coordinator can consume any resulting
	-- deaths exactly once and pay their Gold (group farming). Empty without the mastery.
	CleaveTargetIds: { string },
}

-- Keeps a fully-stacked attack-interval reduction from ever reaching (or passing) the base interval,
-- so the effective interval stays strictly positive regardless of future Mastery data. Current slice
-- data caps a completed Tempo branch at 0.10, well inside this bound.
local MAX_ATTACK_INTERVAL_REDUCTION = 0.9

local Service = {}

local function finitePositive(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and math.abs(value) < math.huge
end

-- Reads one modifier total defensively; a missing or non-finite entry contributes nothing (never a
-- bonus). Mastery already validates its stored values, so this only fails closed on corruption.
local function modifierTotal(totals: any, key: string): number
	if type(totals) ~= "table" then
		return 0
	end
	local value = totals[key]
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return 0
	end
	return value
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

-- Given a primary target id, returns lightweight secondary targets (each with an ApplyDamage closure)
-- for Melee "Cleave" splash. Optional: without it, cleave is simply never applied.
export type CleaveTarget = { RuntimeId: string, ApplyDamage: (number) -> (number?, string?) }
export type CleaveResolver = (string) -> ({ CleaveTarget }?, string?)

function Service.New(equipment: Equipment, skills: Skills, resolveTarget: TargetResolver, configuration: Configuration, clock: () -> number, meleeModifiers: MeleeModifierProvider?, resolveCleaveTargets: CleaveResolver?)
	assert(type(equipment) == "table" and type(equipment.GetEquippedItem) == "function", "Combat requires Equipment")
	assert(type(skills) == "table" and type(skills.AwardXP) == "function", "Combat requires Skills")
	assert(type(resolveTarget) == "function", "Combat requires a trusted target resolver")
	assert(type(configuration) == "table" and finitePositive(configuration.MeleeXPPerSuccessfulHit), "Combat requires a positive Melee XP amount")
	assert(type(clock) == "function", "Combat requires a clock")
	assert(meleeModifiers == nil or type(meleeModifiers) == "function", "Combat meleeModifiers must be a function when provided")
	assert(resolveCleaveTargets == nil or type(resolveCleaveTargets) == "function", "Combat resolveCleaveTargets must be a function when provided")
	-- Defaults to "no selected Mastery" so callers/tests that do not wire Mastery keep exact prior
	-- behavior. Composition injects the real server-authoritative provider.
	local resolveMeleeModifiers: MeleeModifierProvider = meleeModifiers or function()
		return {}
	end

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

		-- Apply the attacker's Melee Mastery totals to the weapon's base numbers. Damage scales up by
		-- MeleeDamageBonus; the attack interval scales down by MeleeAttackIntervalReduction (clamped so
		-- it stays strictly positive). Range and XP are intentionally unmodified in the slice.
		local meleeModifierTotals = resolveMeleeModifiers(userId)
		local damageBonus = math.max(0, modifierTotal(meleeModifierTotals, "MeleeDamageBonus"))
		local intervalReduction = math.clamp(math.max(0, modifierTotal(meleeModifierTotals, "MeleeAttackIntervalReduction")), 0, MAX_ATTACK_INTERVAL_REDUCTION)
		local effectiveDamage = melee.Damage * (1 + damageBonus)
		local effectiveInterval = melee.AttackIntervalSeconds * (1 - intervalReduction)

		local request: DamageRequest = {
			AttackerUserId = userId,
			TargetId = targetId,
			WeaponInstanceId = instanceId,
			WeaponDefinitionId = definition.Id,
			Damage = effectiveDamage,
		}
		local appliedDamage, damageReason = target.ApplyDamage(request)
		if type(appliedDamage) ~= "number" or not finitePositive(appliedDamage) or appliedDamage > request.Damage then
			return nil, damageReason or "NoMeaningfulDamage"
		end

		nextAttackAt[userId] = now + effectiveInterval

		-- Melee "Cleave" mastery: splash a fraction of the primary hit's damage to nearby enemies. Pure
		-- crowd control and best-effort -- secondary hits never affect the primary result, cooldown, XP,
		-- or Gold (cleaved kills bypass the reward path), and any secondary failure is ignored.
		local cleaveHits = 0
		local cleaveTargetIds: { string } = {}
		local cleaveBonus = math.max(0, modifierTotal(meleeModifierTotals, "MeleeCleaveDamageBonus"))
		if cleaveBonus > 0 and resolveCleaveTargets ~= nil then
			local cleaveDamage = effectiveDamage * cleaveBonus
			if cleaveDamage > 0 then
				local secondaries = resolveCleaveTargets(targetId)
				if type(secondaries) == "table" then
					for _, secondary in secondaries do
						if type(secondary) == "table" and type(secondary.ApplyDamage) == "function" then
							local applied = secondary.ApplyDamage(cleaveDamage)
							if type(applied) == "number" and applied > 0 then
								cleaveHits += 1
								-- Report the id so the reward coordinator can consume a cleaved death exactly
								-- once and pay its Gold (group farming), without Combat owning any reward logic.
								if type(secondary.RuntimeId) == "string" then
									table.insert(cleaveTargetIds, secondary.RuntimeId)
								end
							end
						end
					end
				end
			end
		end

		local _, xpReason = skills.AwardXP(userId, SkillIds.Melee, configuration.MeleeXPPerSuccessfulHit)
		return {
			AttackerUserId = userId,
			TargetId = targetId,
			WeaponInstanceId = instanceId,
			WeaponDefinitionId = definition.Id,
			Damage = request.Damage,
			AppliedDamage = appliedDamage,
			AttackIntervalSeconds = effectiveInterval,
			AttackRange = melee.AttackRange,
			MeleeXP = configuration.MeleeXPPerSuccessfulHit,
			XPGranted = xpReason == nil,
			XPReason = xpReason,
			CleaveHits = cleaveHits,
			CleaveTargetIds = cleaveTargetIds,
		}, nil
	end

	return table.freeze(service)
end

return table.freeze(Service)
