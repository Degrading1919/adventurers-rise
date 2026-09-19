--!strict

-- The one reusable server -> client presentation-event seam. It exists so asynchronous, player-
-- specific gameplay OUTCOMES (already resolved and committed elsewhere) can be surfaced to the owning
-- client, without becoming a generic untyped message bus:
--   * every event has a stable EventId (Shared/EventIds) and an explicit per-event sanitizer;
--   * the sanitizer builds a FRESH payload containing only the allowed presentation fields, so no
--     internal/mutable server state (RNG, contribution maps, PlayerData, reward structs) can ever
--     leak through, no matter what the caller passes;
--   * delivery is one-way and best-effort: a transport failure is contained here and can never
--     propagate into (or re-run) the authoritative transaction that produced the event.
-- It never grants anything and is never reachable from a client request; only trusted server
-- composition calls Emit.

local EventIds = require(game:GetService("ReplicatedStorage").Shared.EventIds)

export type Transport = {
	-- Injected by Bootstrap (FireClient to the owning player); a recorder under test. Receives only the
	-- already-sanitized payload.
	read Send: (number, string, any) -> (),
}
-- Sanitized Goblin Chieftain personal reward, the first event on this channel.
export type BossPersonalReward = {
	BossDefinitionId: string,
	Qualified: boolean,
	GoldAwarded: number,
	CommonItemDefinitionId: string?,
	CommonItemAmount: number?,
	RareItemDefinitionId: string?,
	RareItemAmount: number?,
}

local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

local function nonEmptyString(value: any): boolean
	return type(value) == "string" and value ~= ""
end

local function finiteNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and math.abs(value) < math.huge
end

local function finitePositiveWhole(value: any): boolean
	return type(value) == "number" and value == value and value > 0 and value % 1 == 0 and value < math.huge
end

-- Builds a clean BossPersonalReward from arbitrary input, validating every field and copying ONLY the
-- allowed keys. A non-qualifier may never carry any reward data, so the "you didn't qualify" case can
-- never be turned into a fabricated reward at the boundary.
local function sanitizeBossPersonalReward(raw: any): (BossPersonalReward?, string?)
	if type(raw) ~= "table" then
		return nil, "MalformedPayload"
	end
	if not nonEmptyString(raw.BossDefinitionId) then
		return nil, "InvalidBossDefinitionId"
	end
	if type(raw.Qualified) ~= "boolean" then
		return nil, "InvalidQualified"
	end
	if not finiteNonNegative(raw.GoldAwarded) then
		return nil, "InvalidGoldAwarded"
	end
	-- Item rewards are optional but, when present, need both a stable id and a positive whole amount.
	local commonId, commonAmount = raw.CommonItemDefinitionId, raw.CommonItemAmount
	if commonId ~= nil or commonAmount ~= nil then
		if not nonEmptyString(commonId) or not finitePositiveWhole(commonAmount) then
			return nil, "InvalidCommonReward"
		end
	end
	local rareId, rareAmount = raw.RareItemDefinitionId, raw.RareItemAmount
	if rareId ~= nil or rareAmount ~= nil then
		if not nonEmptyString(rareId) or not finitePositiveWhole(rareAmount) then
			return nil, "InvalidRareReward"
		end
	end
	if raw.Qualified ~= true and (commonId ~= nil or rareId ~= nil or raw.GoldAwarded ~= 0) then
		return nil, "NonQualifierCannotCarryReward"
	end
	return {
		BossDefinitionId = raw.BossDefinitionId,
		Qualified = raw.Qualified,
		GoldAwarded = raw.GoldAwarded,
		CommonItemDefinitionId = commonId,
		CommonItemAmount = commonAmount,
		RareItemDefinitionId = rareId,
		RareItemAmount = rareAmount,
	}, nil
end

-- One sanitizer per stable EventId. Adding a future event (e.g. a rare-drop announcement) is a data
-- addition here plus a Shared/EventIds entry -- never a new networking path or an untyped passthrough.
local SANITIZERS: { [string]: (any) -> (any?, string?) } = {
	[EventIds.BossPersonalReward] = sanitizeBossPersonalReward,
}

function Service.New(transport: Transport)
	assert(type(transport) == "table" and type(transport.Send) == "function", "PlayerEvents requires a transport with Send")

	local service = {}

	-- Sanitizes `rawPayload` for `eventId` and pushes the clean result to `userId`. Returns
	-- (true, nil) on delivery, or (false, reason) on a rejected/unknown event or a contained delivery
	-- failure. Never throws, so an emit site can treat it as fire-and-forget.
	function service.Emit(userId: number, eventId: string, rawPayload: any): (boolean, string?)
		if not validUserId(userId) then
			return false, "InvalidUserId"
		end
		local sanitizer = if type(eventId) == "string" and EventIds.ById[eventId] == true then SANITIZERS[eventId] else nil
		if not sanitizer then
			return false, "UnknownEvent"
		end
		local clean, reason = sanitizer(rawPayload)
		if not clean then
			return false, reason
		end
		local delivered = pcall(transport.Send, userId, eventId, clean)
		if not delivered then
			return false, "DeliveryFailed"
		end
		return true, nil
	end

	return table.freeze(service)
end

return table.freeze(Service)
