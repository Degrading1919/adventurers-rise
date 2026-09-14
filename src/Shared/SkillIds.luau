--!strict

-- Persist these IDs, never the display names. Keep existing values when adding skills.
local SkillIds: { [string]: string } = {
	Melee = "skill_melee",
	Defense = "skill_defense",
	Mining = "skill_mining",
	Smithing = "skill_smithing",
}

return table.freeze(SkillIds)
