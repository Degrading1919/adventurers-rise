--!strict

local Definitions = require(script.Parent.Definitions)

export type PlayerData = {
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type Enemies = {
	read GetSnapshot: (string) -> (any?, string?),
	read ConsumeDeath: (string) -> (any?, string?),
	read GetContribution: (string) -> ({ [number]: number }?, string?),
}
export type Economy = {
	read CreditGoldToData: (any, number) -> (number?, string?),
}
export type Inventory = {
	read AddStackToData: (any, string, number) -> (number?, string?),
}
export type Ascension = {
	read RecordBossMilestoneToData: (any, string) -> (boolean?, string?),
}
export type Runtime = {
	-- Returns a float in [0, 1); injected so reward rolls are deterministic under test.
	Roll01: () -> number,
}
export type ParticipantResult = {
	UserId: number,
	Contribution: number,
	Eligible: boolean,
	RewardGranted: boolean,
	-- Sourced from the consumed Enemy death record, not from Boss loot data.
	CommonGoldAmount: number?,
	CommonItemDefinitionId: string?,
	CommonItemAmount: number?,
	RareGranted: boolean?,
	RareItemDefinitionId: string?,
	MilestoneRecorded: boolean?,
	FailureReason: string?,
}
export type Result = {
	RuntimeId: string,
	DefinitionId: string,
	Participants: { ParticipantResult },
}
export type ParticipationEntry = {
	UserId: number,
	Contribution: number,
	Eligible: boolean,
}
export type ParticipationSummary = {
	RuntimeId: string,
	DefinitionId: string,
	Entries: { ParticipationEntry },
}

-- Trusted server composition (a later shared/personal boss encounter) calls ResolveBossDeath once
-- the Enemy runtime reports a death; the killing blow itself never determines eligibility or
-- reward -- only accumulated Enemies.Contribution does.
local Service = {}

local function validStableId(value: any): boolean
	return type(value) == "string" and value ~= ""
end

local function sortedUserIds(contribution: { [number]: number }): { number }
	local userIds: { number } = {}
	for userId in contribution do
		table.insert(userIds, userId)
	end
	table.sort(userIds)
	return userIds
end

function Service.New(playerData: PlayerData, enemies: Enemies, economy: Economy, inventory: Inventory, ascension: Ascension, runtime: Runtime)
	assert(type(playerData) == "table" and type(playerData.Update) == "function", "Bosses requires PlayerData")
	assert(
		type(enemies) == "table" and type(enemies.GetSnapshot) == "function" and type(enemies.ConsumeDeath) == "function" and type(enemies.GetContribution) == "function",
		"Bosses requires Enemies"
	)
	assert(type(economy) == "table" and type(economy.CreditGoldToData) == "function", "Bosses requires Economy")
	assert(type(inventory) == "table" and type(inventory.AddStackToData) == "function", "Bosses requires Inventory")
	assert(type(ascension) == "table" and type(ascension.RecordBossMilestoneToData) == "function", "Bosses requires Ascension")
	assert(type(runtime) == "table" and type(runtime.Roll01) == "function", "Bosses requires an RNG source")
	local valid, reason = Definitions.Validate(Definitions.ById)
	assert(valid, reason)

	local service = {}

	local function bossDefinitionFor(runtimeId: string): (Definitions.Definition?, any?, string?)
		if not validStableId(runtimeId) then
			return nil, nil, "InvalidRuntimeId"
		end
		local snapshot, snapshotReason = enemies.GetSnapshot(runtimeId)
		if not snapshot then
			return nil, nil, snapshotReason
		end
		local bossDefinition = Definitions.ById[(snapshot :: any).DefinitionId]
		if not bossDefinition then
			return nil, nil, "NotABossEncounter"
		end
		return bossDefinition, snapshot, nil
	end

	-- Read-only; never consumes the death or mutates anything. Usable while the boss is still
	-- alive or after death, for debugging/UI, independent of reward resolution.
	function service.GetParticipationSummary(runtimeId: string): (ParticipationSummary?, string?)
		local bossDefinition, snapshot, reason = bossDefinitionFor(runtimeId)
		if not bossDefinition then
			return nil, reason
		end
		local contribution, contributionReason = enemies.GetContribution(runtimeId)
		if not contribution then
			return nil, contributionReason
		end
		local threshold = bossDefinition.Eligibility.MinimumContributionFraction * (snapshot :: any).MaxHealth
		local entries: { ParticipationEntry } = {}
		for _, userId in sortedUserIds(contribution) do
			local damage = contribution[userId]
			table.insert(entries, { UserId = userId, Contribution = damage, Eligible = damage >= threshold })
		end
		return { RuntimeId = runtimeId, DefinitionId = (snapshot :: any).DefinitionId, Entries = entries }, nil
	end

	-- Consumes the boss's pending death exactly once (via Enemies.ConsumeDeath), so calling this
	-- twice for the same runtime instance fails closed on the second call rather than duplicating
	-- rewards. Every eligible participant rolls independently and is granted atomically.
	function service.ResolveBossDeath(runtimeId: string): (Result?, string?)
		local bossDefinition, snapshot, reason = bossDefinitionFor(runtimeId)
		if not bossDefinition then
			return nil, reason
		end
		local death, deathReason = enemies.ConsumeDeath(runtimeId)
		if not death then
			return nil, deathReason
		end
		local contribution, contributionReason = enemies.GetContribution(runtimeId)
		if not contribution then
			return nil, contributionReason
		end
		local threshold = bossDefinition.Eligibility.MinimumContributionFraction * (snapshot :: any).MaxHealth

		local participants: { ParticipantResult } = {}
		for _, userId in sortedUserIds(contribution) do
			local damage = contribution[userId]
			local eligible = damage >= threshold
			local participant: ParticipantResult = {
				UserId = userId,
				Contribution = damage,
				Eligible = eligible,
				RewardGranted = false,
				CommonGoldAmount = nil,
				CommonItemDefinitionId = nil,
				CommonItemAmount = nil,
				RareGranted = nil,
				RareItemDefinitionId = nil,
				MilestoneRecorded = nil,
				FailureReason = nil,
			}
			if eligible then
				local rareGranted = runtime.Roll01() < bossDefinition.Loot.Rare.Chance
				local mutationReason: string? = nil
				local function abort(abortReason: string)
					mutationReason = abortReason
					error(abortReason, 0)
				end
				local ok, updateReason = playerData.Update(userId, function(data)
					-- Gold is the Enemy death's own GoldReward -- the single authoritative amount,
					-- never a second Gold value duplicated in Boss loot data.
					local _, goldReason = economy.CreditGoldToData(data, (death :: any).GoldReward)
					if goldReason then
						abort(goldReason)
					end
					local _, commonItemReason = inventory.AddStackToData(data, bossDefinition.Loot.Common.ItemDefinitionId, bossDefinition.Loot.Common.Amount)
					if commonItemReason then
						abort(commonItemReason)
					end
					if rareGranted then
						local _, itemReason = inventory.AddStackToData(data, bossDefinition.Loot.Rare.ItemDefinitionId, bossDefinition.Loot.Rare.Amount)
						if itemReason then
							abort(itemReason)
						end
					end
					local _, milestoneReason = ascension.RecordBossMilestoneToData(data, bossDefinition.MilestoneId)
					if milestoneReason then
						abort(milestoneReason)
					end
				end)
				if ok then
					participant.RewardGranted = true
					participant.CommonGoldAmount = (death :: any).GoldReward
					participant.CommonItemDefinitionId = bossDefinition.Loot.Common.ItemDefinitionId
					participant.CommonItemAmount = bossDefinition.Loot.Common.Amount
					participant.RareGranted = rareGranted
					participant.RareItemDefinitionId = if rareGranted then bossDefinition.Loot.Rare.ItemDefinitionId else nil
					participant.MilestoneRecorded = true
				else
					participant.FailureReason = mutationReason or updateReason or "PlayerDataUpdateFailed"
				end
			end
			table.insert(participants, participant)
		end

		return { RuntimeId = runtimeId, DefinitionId = (snapshot :: any).DefinitionId, Participants = participants }, nil
	end

	return table.freeze(service)
end

return table.freeze(Service)
