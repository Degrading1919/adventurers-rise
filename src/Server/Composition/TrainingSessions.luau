--!strict

-- Trusted server-owned continuous plot-training coordinator, mirroring GatheringSessions: the
-- underlying Plots.Service.AwardTrainingForElapsed accepts elapsed seconds because it was built
-- below the remote layer, and this module is the only place allowed to compute that duration.
export type Plots = {
	read GetStation: (number, string) -> (any?, string?),
	read AwardTrainingForElapsed: (number, string, number) -> (any?, string?),
}

export type Coordinator = {
	read Begin: (number, string) -> (any?, string?),
	read Settle: (number) -> (any?, string?),
	read Stop: (number) -> (any?, string?),
	read Clear: (number) -> (),
	read SettleAllActive: () -> (),
}

local Service = {}

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

function Service.New(plots: Plots, maximumElapsedSeconds: number, clock: () -> number, isNearStation: (number, string) -> (boolean, string?)): Coordinator
	assert(type(plots) == "table" and type(plots.GetStation) == "function" and type(plots.AwardTrainingForElapsed) == "function", "TrainingSessions requires Plots")
	assert(type(maximumElapsedSeconds) == "number" and maximumElapsedSeconds > 0, "TrainingSessions requires a positive chunk boundary")
	assert(type(clock) == "function", "TrainingSessions requires a trusted server clock")
	assert(type(isNearStation) == "function", "TrainingSessions requires a trusted station-proximity check")

	local sessions: { [number]: { StationId: string, LastSettledAt: number } } = {}
	local coordinator = {}

	function coordinator.Clear(userId: number)
		sessions[userId] = nil
	end

	-- Called by Composition's shared heartbeat, never per-player.
	function coordinator.SettleAllActive()
		local userIds: { number } = {}
		for userId in sessions do
			table.insert(userIds, userId)
		end
		for _, userId in userIds do
			coordinator.Settle(userId)
		end
	end

	function coordinator.Settle(userId: number): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local session = sessions[userId]
		if not session then
			return nil, "NoActiveTrainingSession"
		end
		local now = clock()
		local elapsed = now - session.LastSettledAt
		if elapsed <= 0 then
			return nil, "NothingToSettle"
		end
		-- Server-authoritative proximity revalidation: if the player is no longer physically at the
		-- station, stop the session now and credit nothing for this interval. The session is cleared,
		-- so the absent time can never be recovered by a later settlement -- a fresh Begin (which
		-- requires being back at the station) restarts the settlement clock.
		local near, nearReason = isNearStation(userId, session.StationId)
		if not near then
			sessions[userId] = nil
			return nil, nearReason or "TooFarFromStation"
		end
		local lastResult: any = nil
		while elapsed > 0 do
			local chunk = math.min(elapsed, maximumElapsedSeconds)
			-- Re-resolves the station's authoritative tier/rate for every chunk.
			local result, reason = plots.AwardTrainingForElapsed(userId, session.StationId, chunk)
			if not result then
				sessions[userId] = nil
				return nil, reason
			end
			lastResult = result
			elapsed -= chunk
			session.LastSettledAt += chunk
		end
		return lastResult, nil
	end

	-- Begin never awards XP: it only proves the station is currently valid (via Plots' own
	-- authoritative GetStation read) and starts the trusted server-timed session at the current
	-- monotonic clock reading. All progress comes from real elapsed time, settled periodically and
	-- on Stop.
	function coordinator.Begin(userId: number, stationId: string): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if type(stationId) ~= "string" or stationId == "" then
			return nil, "InvalidStationId"
		end
		if sessions[userId] then
			coordinator.Settle(userId)
			sessions[userId] = nil
		end
		local station, reason = plots.GetStation(userId, stationId)
		if not station then
			return nil, reason
		end
		-- Server-authoritative: the player must physically be at the requested station to start.
		local near, nearReason = isNearStation(userId, stationId)
		if not near then
			return nil, nearReason or "TooFarFromStation"
		end
		sessions[userId] = { StationId = stationId, LastSettledAt = clock() }
		return station, nil
	end

	function coordinator.Stop(userId: number): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not sessions[userId] then
			return nil, "NoActiveTrainingSession"
		end
		local result, reason = coordinator.Settle(userId)
		sessions[userId] = nil
		return result, reason
	end

	return table.freeze(coordinator)
end

return table.freeze(Service)
