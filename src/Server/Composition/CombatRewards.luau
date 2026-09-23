--!strict

local EnemyDefinitions = require(script.Parent.Parent.Enemies.Definitions)

-- Trusted composition seam associating a normal enemy's death-triggering attack with reward
-- resolution, without turning the generic Enemy death record into a permanent "reward owner"
-- object. Boss deaths are routed to the existing participation-based Bosses service instead.
export type Combat = {
	read ResolveMeleeAttack: (number, string) -> (any?, string?),
}
export type Enemies = {
	read GetSnapshot: (string) -> (any?, string?),
	read ConsumeDeath: (string) -> (any?, string?),
}
export type Economy = {
	read CreditGold: (number, number) -> (number?, string?),
}
export type Bosses = {
	read ResolveBossDeath: (string) -> (any?, string?),
}

local Service = {}

function Service.New(combat: Combat, enemies: Enemies, economy: Economy, bosses: Bosses, warn: (string) -> (), announceBossReward: (any) -> (), onNormalEnemyDefeated: (number, string) -> ())
	assert(type(combat) == "table" and type(combat.ResolveMeleeAttack) == "function", "CombatRewards requires Combat")
	assert(type(enemies) == "table" and type(enemies.GetSnapshot) == "function" and type(enemies.ConsumeDeath) == "function", "CombatRewards requires Enemies")
	assert(type(economy) == "table" and type(economy.CreditGold) == "function", "CombatRewards requires Economy")
	assert(type(bosses) == "table" and type(bosses.ResolveBossDeath) == "function", "CombatRewards requires Bosses")
	assert(type(warn) == "function", "CombatRewards requires a warn sink")
	assert(type(announceBossReward) == "function", "CombatRewards requires a boss-reward announcer")
	assert(type(onNormalEnemyDefeated) == "function", "CombatRewards requires a normal-enemy-defeated sink")

	local coordinator = {}

	-- Runs unconditionally after every successful attack against the target, whether or not this
	-- particular hit was lethal: Enemies.ConsumeDeath and Bosses.ResolveBossDeath are each
	-- exactly-once by construction, so calling them speculatively on a target that is not (yet, or
	-- no longer) dead is a cheap, safe no-op. This keeps normal-enemy Gold exactly-once per death
	-- without composition re-deriving "was this the killing blow" itself.
	function coordinator.ResolveMeleeAttack(userId: number, targetId: string): (any?, string?)
		local result, reason = combat.ResolveMeleeAttack(userId, targetId)
		if not result then
			return nil, reason
		end

		local snapshot = enemies.GetSnapshot(targetId)
		if snapshot then
			local definition = EnemyDefinitions.ById[(snapshot :: any).DefinitionId]
			if definition and definition.Boss then
				-- Boss enemies never pass through the normal last-hit Gold path; participation
				-- rewards remain entirely owned by Bosses.Service. ResolveBossDeath returns a Result
				-- only on the single hit that consumes the death, so the announce fires exactly once.
				local bossResult = bosses.ResolveBossDeath(targetId)
				if bossResult then
					-- Presentation only, best-effort, and strictly AFTER the authoritative reward
					-- transaction already committed. Isolated in pcall so a delivery/announce failure can
					-- never change, duplicate, or roll back the reward, nor fail the attack request.
					local announced = pcall(announceBossReward, bossResult)
					if not announced then
						warn(("[CombatRewards] Boss reward announce failed for %s"):format(targetId))
					end
				end
			else
				local death = enemies.ConsumeDeath(targetId)
				if death then
					-- This hit consumed a NORMAL enemy's death (exactly-once by construction). Report it with
					-- the enemy's definition id so the onboarding sink can record the "first Goblin defeated"
					-- milestone ONLY for an actual Goblin, not any future non-boss archetype. Isolated in pcall
					-- and done before the Gold credit so a defeat is reported even if the (separate) payout path
					-- has an issue; a transient failure just means the next defeat reports it.
					local noted = pcall(onNormalEnemyDefeated, userId, (snapshot :: any).DefinitionId)
					if not noted then
						warn(("[CombatRewards] Onboarding normal-enemy note failed for %d on %s"):format(userId, targetId))
					end
				end
				if death and (death :: any).GoldReward and (death :: any).GoldReward > 0 then
					local _, goldReason = economy.CreditGold(userId, (death :: any).GoldReward)
					if goldReason then
						-- The death record is already consumed; a dead target becomes ineligible
						-- for further attacks (Combat rejects it), so there is no retry path that
						-- could duplicate this payout -- it is simply never granted. Surface that
						-- to the caller as a failed request rather than silently reporting the
						-- overall attack as a full success.
						warn(("[CombatRewards] Gold credit failed for %d on %s: %s"):format(userId, targetId, goldReason))
						return nil, goldReason or "GoldRewardFailed"
					end
				end
			end
		end

		-- Cleave rewards (docs/MASTERY_TREES: Cleave supports GROUP FARMING). Each cleaved NORMAL-enemy
		-- death is consumed exactly once and paid its Gold on the same flow as a primary kill, so farming a
		-- pack with Cleave actually rewards the extra kills. Bosses are excluded from cleave targets
		-- upstream (Enemies.CreateCleaveResolver), so no boss/participation/contribution path is touched
		-- here. Best-effort and pcall/warn-isolated: a cleave-reward failure never fails the primary attack.
		local cleaveTargetIds = (result :: any).CleaveTargetIds
		if type(cleaveTargetIds) == "table" then
			for _, cleavedId in cleaveTargetIds do
				local cleavedDeath = enemies.ConsumeDeath(cleavedId)
				if cleavedDeath then
					pcall(onNormalEnemyDefeated, userId, (cleavedDeath :: any).DefinitionId)
					local goldReward = (cleavedDeath :: any).GoldReward
					if type(goldReward) == "number" and goldReward > 0 then
						local _, goldReason = economy.CreditGold(userId, goldReward)
						if goldReason then
							warn(("[CombatRewards] Cleave Gold credit failed for %d on %s: %s"):format(userId, tostring(cleavedId), tostring(goldReason)))
						end
					end
				end
			end
		end

		return result, nil
	end

	return table.freeze(coordinator)
end

return table.freeze(Service)
