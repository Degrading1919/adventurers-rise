--!strict

local Shared = game:GetService("ReplicatedStorage").Shared
local SkillIds = require(Shared.SkillIds)
local StationDefinitions = require(script.Parent.Parent.Plots.StationDefinitions)

export type Configuration = {
	-- Applied to the same active XPPerSecond rate Plot/Training owns; always below active (1.0).
	read EfficiencyMultiplier: number,
	-- Hard cap on credited duration per claim, regardless of real elapsed time.
	read MaximumOfflineSeconds: number,
	-- Below this, a claim is a no-op rather than awarding a near-zero sliver of XP.
	read MinimumElapsedSeconds: number,
}

-- Only the vertical slice's functional combat-training paths support offline training. Ranged
-- and Magic stations are not trained by any real system yet, so they are deliberately excluded.
local SUPPORTED_FOCUS_SKILL_IDS: { [string]: boolean } = {
	[SkillIds.Melee] = true,
	[SkillIds.Defense] = true,
}

-- Derived from the authoritative Plot/Training station catalog (never a second hand-written
-- rate/tier table): the one station that trains each supported skill.
local stationIdBySkillId: { [string]: string } = {}
for stationId, definition in StationDefinitions.ById do
	if SUPPORTED_FOCUS_SKILL_IDS[definition.SkillId] then
		stationIdBySkillId[definition.SkillId] = stationId
	end
end

-- All values are provisional and conservative for the vertical slice: a quarter of active
-- efficiency, capped at 8 real-time hours per claim, with a 60-second minimum to bother awarding.
local configuration: Configuration = table.freeze({
	EfficiencyMultiplier = 0.25,
	MaximumOfflineSeconds = 8 * 60 * 60,
	MinimumElapsedSeconds = 60,
})

local function validateConfiguration()
	assert(type(configuration.EfficiencyMultiplier) == "number" and configuration.EfficiencyMultiplier > 0 and configuration.EfficiencyMultiplier < 1, "Offline efficiency must be a fraction below active (1.0)")
	assert(type(configuration.MaximumOfflineSeconds) == "number" and configuration.MaximumOfflineSeconds > 0, "Offline cap must be a positive duration")
	assert(type(configuration.MinimumElapsedSeconds) == "number" and configuration.MinimumElapsedSeconds >= 0 and configuration.MinimumElapsedSeconds <= configuration.MaximumOfflineSeconds, "Offline minimum threshold must be within [0, cap]")
	for skillId in SUPPORTED_FOCUS_SKILL_IDS do
		assert(stationIdBySkillId[skillId] ~= nil, "Every supported offline focus skill must resolve to a real station")
	end
end
validateConfiguration()

return table.freeze({
	Configuration = configuration,
	SupportedFocusSkillIds = table.freeze(SUPPORTED_FOCUS_SKILL_IDS),
	StationIdBySkillId = table.freeze(stationIdBySkillId),
})
