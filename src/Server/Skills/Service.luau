--!strict

local Definitions = require(script.Parent.Definitions)

export type Curve = {
	MaximumXP: number,
	Thresholds: { [number]: number },
}
export type Configuration = {
	Curves: { [string]: Curve },
}
export type State = {
	SkillId: string,
	XP: number,
	Level: number,
	XPAtLevel: number,
	XPForNextLevel: number?,
}
export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}

local Service = {}

local function finiteNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and math.abs(value) < math.huge
end

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= 9007199254740991
end

local function validateCurve(curve: any): boolean
	if type(curve) ~= "table" or not finiteNonNegative(curve.MaximumXP) or type(curve.Thresholds) ~= "table" then
		return false
	end
	local previous = -1
	for level = 1, Definitions.LevelCap do
		local threshold = curve.Thresholds[level]
		if not finiteNonNegative(threshold) or threshold <= previous then
			return false
		end
		previous = threshold
	end
	if curve.Thresholds[1] ~= 0 or curve.MaximumXP < previous then
		return false
	end
	for level in curve.Thresholds do
		if type(level) ~= "number" or level % 1 ~= 0 or level < 1 or level > Definitions.LevelCap then
			return false
		end
	end
	return true
end

local function levelForXP(curve: Curve, xp: number): number
	local level = 1
	for candidate = 2, Definitions.LevelCap do
		if xp < curve.Thresholds[candidate] then
			break
		end
		level = candidate
	end
	return level
end

local function stateFor(skillId: string, curve: Curve, xp: number): State
	local level = levelForXP(curve, xp)
	return {
		SkillId = skillId,
		XP = xp,
		Level = level,
		XPAtLevel = curve.Thresholds[level],
		XPForNextLevel = if level < Definitions.LevelCap then curve.Thresholds[level + 1] else nil,
	}
end

local function copyCurve(curve: Curve): Curve
	local thresholds: { [number]: number } = {}
	for level = 1, Definitions.LevelCap do
		thresholds[level] = curve.Thresholds[level]
	end
	return {
		MaximumXP = curve.MaximumXP,
		Thresholds = thresholds,
	}
end

function Service.New(playerData: PlayerData, configuration: Configuration)
	assert(type(playerData) == "table", "Skills requires a PlayerData service")
	assert(type(configuration) == "table" and type(configuration.Curves) == "table", "Skills requires curve definitions")
	local curves: { [string]: Curve } = {}
	for _, definition in Definitions.ById do
		local curve = configuration.Curves[definition.CurveId]
		assert(validateCurve(curve), ("Invalid skill curve: %s"):format(definition.CurveId))
		curves[definition.CurveId] = copyCurve(curve)
	end

	local service = {}

	local function curveFor(skillId: any): (Curve?, string?)
		if type(skillId) ~= "string" then
			return nil, "InvalidSkillId"
		end
		local definition = Definitions.ById[skillId]
		if not definition then
			return nil, "InvalidSkillId"
		end
		return curves[definition.CurveId], nil
	end

	-- Trusted server compositions may use these inside one PlayerData.Update transaction.
	function service.GetStateFromData(data: any, skillId: string): (State?, string?)
		local curve, reason = curveFor(skillId)
		if not curve then
			return nil, reason
		end
		local xp = data.SkillXP and data.SkillXP[skillId]
		if not finiteNonNegative(xp) or xp > curve.MaximumXP then
			return nil, "XPOutOfBounds"
		end
		return stateFor(skillId, curve, xp), nil
	end

	function service.AwardXPToData(data: any, skillId: string, amount: number): (State?, string?)
		if not finiteNonNegative(amount) or amount <= 0 then
			return nil, "InvalidXPAmount"
		end
		local curve, reason = curveFor(skillId)
		if not curve then
			return nil, reason
		end
		local xp = data.SkillXP and data.SkillXP[skillId]
		if not finiteNonNegative(xp) or xp > curve.MaximumXP then
			return nil, "XPOutOfBounds"
		end
		local nextXP = xp + amount
		if not finiteNonNegative(nextXP) or nextXP > curve.MaximumXP then
			return nil, "XPOutOfBounds"
		end
		data.SkillXP[skillId] = nextXP
		return stateFor(skillId, curve, nextXP), nil
	end

	function service.GetState(userId: number, skillId: string): (State?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local curve, reason = curveFor(skillId)
		if not curve then
			return nil, reason
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		return service.GetStateFromData(data, skillId)
	end

	function service.AwardXP(userId: number, skillId: string, amount: number): (State?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not finiteNonNegative(amount) or amount <= 0 then
			return nil, "InvalidXPAmount"
		end
		local _, reason = curveFor(skillId)
		if reason then
			return nil, reason
		end
		local result: State? = nil
		local awardReason: string? = nil
		local ok, updateReason = playerData.Update(userId, function(data)
			result, awardReason = service.AwardXPToData(data, skillId, amount)
		end)
		if not ok then
			return nil, updateReason or "PlayerDataUpdateFailed"
		end
		if awardReason then
			return nil, awardReason
		end
		return result, nil
	end

	return table.freeze(service)
end

return table.freeze(Service)
