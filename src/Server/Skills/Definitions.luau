--!strict

local SkillIds = require(game:GetService("ReplicatedStorage").Shared.SkillIds)

export type Definition = {
	read Id: string,
	read DisplayName: string,
	read CurveId: string,
}

local function definition(id: string, displayName: string): Definition
	return table.freeze({
		Id = id,
		DisplayName = displayName,
		-- Balance supplies this curve by ID when Skills is composed in a later task.
		CurveId = "curve_standard",
	})
end

-- Add a skill here, its PlayerData XP key, and a curve definition; no new level logic is needed.
local definitions: { [string]: Definition } = {
	[SkillIds.Melee] = definition(SkillIds.Melee, "Melee"),
	[SkillIds.Defense] = definition(SkillIds.Defense, "Defense"),
	[SkillIds.Mining] = definition(SkillIds.Mining, "Mining"),
	[SkillIds.Smithing] = definition(SkillIds.Smithing, "Smithing"),
}

return table.freeze({
	LevelCap = 60,
	ById = table.freeze(definitions),
})
