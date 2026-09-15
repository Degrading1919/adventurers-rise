--!strict

-- Trusted server-owned continuous plot-training coordinator, mirroring GatheringSessions: the
-- underlying Plots.Service.AwardTrainingForElapsed accepts elapsed seconds because it was built
-- below the remote layer, and this module is the only place allowed to compute that duration.
export type Plots = {
	read AwardTrainingForElapsed: (number, string, number) -> (any?, string?),
}

export type Coordinator = {
	read Begin: (number, string) -> (any?, string?),
	read Settle: (number) -> (any?, string?),
	read Stop: (number) -> (any?, string?),
	read Clear: (number) -> (),
}

local Service = {}

local BEGIN_SECONDS = 1

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

function Service.New(plots: Plots, maximumElapsedSeconds: number, clock: () -> number): Coordinator
	assert(type(plots) == "table" and type(plots.AwardTrainingForElapsed) == "function", "TrainingSessions requires Plots")
	assert(type(maximumElapsedSeconds) == "number" and maximumElapsedSeconds > 0, "TrainingSessions requires a positive chunk boundary")
	assert(type(clock) == "function", "TrainingSessions requires a trusted server clock")

	local sessions: { [number]: { StationId: string, LastSettledAt: number } } = {}
	local coordinator = {}

	function coordinator.Clear(userId: number)
		sessions[userId] = nil
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
		local now = clock()
		local result, reason = plots.AwardTrainingForElapsed(userId, stationId, BEGIN_SECONDS)
		if not result then
			return nil, reason
		end
		sessions[userId] = { StationId = stationId, LastSettledAt = now }
		return result, nil
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
