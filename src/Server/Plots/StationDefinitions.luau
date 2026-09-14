--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local PlotSockets = require(Shared.PlotSockets)
local SkillIds = require(Shared.SkillIds)

export type Tier = {
	read Tier: number,
	read UpgradeCostGold: number,
	read XPPerSecond: number,
}
export type Definition = {
	read Id: string,
	read SocketId: string,
	read SkillId: string,
	read Tiers: { [number]: Tier },
}

local function tier(number: number, upgradeCostGold: number, xpPerSecond: number): Tier
	return table.freeze({
		Tier = number,
		UpgradeCostGold = upgradeCostGold,
		XPPerSecond = xpPerSecond,
	})
end

local function definition(id: string, socketId: string, skillId: string, tiers: { [number]: Tier }): Definition
	return table.freeze({
		Id = id,
		SocketId = socketId,
		SkillId = skillId,
		Tiers = table.freeze(tiers),
	})
end

-- Rates and costs are provisional. Add later tiers as data without changing station logic.
local definitions: { [string]: Definition } = {
	station_training_melee = definition("station_training_melee", PlotSockets.Melee, SkillIds.Melee, {
		[1] = tier(1, 0, 1),
		[2] = tier(2, 100, 2),
	}),
	station_training_defense = definition("station_training_defense", PlotSockets.Defense, SkillIds.Defense, {
		[1] = tier(1, 0, 1),
		[2] = tier(2, 125, 2),
	}),
}

return table.freeze({
	ById = table.freeze(definitions),
})
