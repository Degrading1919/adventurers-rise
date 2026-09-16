--!strict

local Definitions = require(script.Parent.Definitions)

export type Curve = {
	MaximumXP: number,
	Thresholds: { [number]: number },
}

-- The one production XP curve every slice skill currently references (Definitions.CurveId ==
-- "curve_standard" for all of them). Generated from a simple increasing-per-level formula rather
-- than hand-authored per level, and provisional/replaceable like every other balance value in the
-- repository -- Skills.Service only requires it to be validly shaped and strictly increasing.
local function buildCurveStandard(): Curve
	local thresholds: { [number]: number } = {}
	local xp = 0
	for level = 1, Definitions.LevelCap do
		thresholds[level] = xp
		xp += 25 * level
	end
	return { MaximumXP = xp, Thresholds = thresholds }
end

local curves: { [string]: Curve } = {
	curve_standard = buildCurveStandard(),
}

return table.freeze(curves)
