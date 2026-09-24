--!strict

-- First-visit zone discovery: when a player is genuinely standing in a discoverable wilderness zone for
-- the first time, record its one-time ProgressionFlag and grant the Gold reward, atomically, in one
-- PlayerData transaction. Server-authoritative end to end: the zone is resolved from the player's real
-- world position (an injected WorldAdapter), never from a client-supplied zone id, so a client cannot
-- claim a discovery it hasn't physically reached. Idempotent: a re-entry grants nothing.

local Definitions = require(script.Parent.Definitions)

export type PlayerData = {
	read GetSnapshot: (number) -> any?,
	read Update: (number, (any) -> ()) -> (boolean, string?),
}
export type Economy = {
	read CreditGoldToData: (any, number) -> (number?, string?),
}
-- Resolves the player's CURRENT zone id from their authoritative world position, or (nil, reason) when
-- they are in open wilderness / not ready. This is the anti-spoof boundary.
export type ZoneResolver = (number) -> (string?, string?)

export type DiscoveryResult = {
	ZoneId: string,
	NewlyDiscovered: boolean,
	RewardGold: number?,
	Gold: number?,
}

local Service = {}

local function validUserId(userId: any): boolean
	return type(userId) == "number" and userId > 0 and userId % 1 == 0 and userId <= 9007199254740991
end

function Service.New(playerData: PlayerData, economy: Economy, zoneResolver: ZoneResolver)
	assert(type(playerData) == "table" and type(playerData.GetSnapshot) == "function" and type(playerData.Update) == "function", "Discovery requires PlayerData")
	assert(type(economy) == "table" and type(economy.CreditGoldToData) == "function", "Discovery requires Economy")
	assert(type(zoneResolver) == "function", "Discovery requires a zone resolver")
	local valid, reason = Definitions.Validate(Definitions.ById)
	assert(valid, reason)

	local service = {}

	-- The set of zone ids this player has already discovered, derived from their permanent flags. Used by
	-- the read model (map: discovered vs unknown) and to keep grants idempotent.
	function service.GetDiscoveredFromData(data: any): ({ [string]: boolean }?, string?)
		local flags = data.ProgressionFlags
		if type(flags) ~= "table" then
			return nil, "InvalidProgressionFlags"
		end
		local discovered: { [string]: boolean } = {}
		for zoneId, def in Definitions.ById do
			if flags[def.FlagId] == true then
				discovered[zoneId] = true
			end
		end
		return discovered, nil
	end

	function service.GetDiscovered(userId: number): ({ [string]: boolean }?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local data = playerData.GetSnapshot(userId)
		if not data then
			return nil, "NotReady"
		end
		return service.GetDiscoveredFromData(data)
	end

	-- Resolve where the player physically is and, if that is a not-yet-discovered discoverable zone,
	-- grant its reward once. Returns a result describing the outcome (NewlyDiscovered false when the
	-- player is in the town / open wilderness / an already-known zone), or (nil, reason) on failure.
	function service.DiscoverCurrentZone(userId: number): (DiscoveryResult?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local zoneId, zoneReason = zoneResolver(userId)
		if not zoneId then
			return nil, zoneReason or "NoZone"
		end
		local def = Definitions.ById[zoneId]
		if not def then
			-- A real, known zone that simply isn't a discovery (the town), or open wilderness: nothing to
			-- grant, but not an error -- report the zone so the caller can still react.
			return { ZoneId = zoneId, NewlyDiscovered = false }, nil
		end

		local result: DiscoveryResult? = nil
		local mutationReason: string? = nil
		local function abort(abortReason: string)
			mutationReason = abortReason
			error(abortReason, 0)
		end
		local ok, updateReason = playerData.Update(userId, function(data)
			local flags = data.ProgressionFlags
			if type(flags) ~= "table" then
				abort("InvalidProgressionFlags")
			end
			if (flags :: any)[def.FlagId] == true then
				-- Already discovered: idempotent no-op, no second reward.
				result = { ZoneId = zoneId, NewlyDiscovered = false }
				return
			end
			local newGold, creditReason = economy.CreditGoldToData(data, def.RewardGold)
			if not newGold then
				abort(creditReason or "CreditFailed")
			end
			(flags :: any)[def.FlagId] = true
			result = { ZoneId = zoneId, NewlyDiscovered = true, RewardGold = def.RewardGold, Gold = newGold }
		end)
		if not ok then
			return nil, mutationReason or updateReason or "PlayerDataUpdateFailed"
		end
		return result, nil
	end

	return table.freeze(service)
end

return table.freeze(Service)
