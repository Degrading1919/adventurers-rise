--!strict

-- Trusted server-owned continuous-gathering coordinator. Gathering.Service intentionally accepts
-- an elapsed duration because it was built below the remote layer; this module is the only place
-- allowed to compute that duration, always from the injected server clock, never from a client.
export type Gathering = {
	read GatherForElapsed: (number, string, number) -> (any?, string?),
}

export type Coordinator = {
	read Begin: (number, string) -> (any?, string?),
	read Settle: (number) -> (any?, string?),
	read Stop: (number) -> (any?, string?),
	read Clear: (number) -> (),
}

local Service = {}

-- The first tick is awarded immediately at Begin so the request itself proves the node/tool are
-- valid right now (reusing GatherForElapsed rather than a second validation path).
local BEGIN_SECONDS = 1

local function validUserId(value: any): boolean
	return type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991
end

function Service.New(gathering: Gathering, maximumElapsedSeconds: number, clock: () -> number): Coordinator
	assert(type(gathering) == "table" and type(gathering.GatherForElapsed) == "function", "GatheringSessions requires Gathering")
	assert(type(maximumElapsedSeconds) == "number" and maximumElapsedSeconds > 0, "GatheringSessions requires a positive chunk boundary")
	assert(type(clock) == "function", "GatheringSessions requires a trusted server clock")

	local sessions: { [number]: { NodeId: string, LastSettledAt: number } } = {}
	local coordinator = {}

	function coordinator.Clear(userId: number)
		sessions[userId] = nil
	end

	-- Advances the session's own settlement clock by exactly what a chunk consumed, even on
	-- failure, so a rejected chunk (node moved out of range, tool unequipped, level lost, ...)
	-- never lets a later successful settlement silently re-claim the rejected interval.
	function coordinator.Settle(userId: number): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		local session = sessions[userId]
		if not session then
			return nil, "NoActiveGatheringSession"
		end
		local now = clock()
		local elapsed = now - session.LastSettledAt
		if elapsed <= 0 then
			return nil, "NothingToSettle"
		end
		local lastResult: any = nil
		while elapsed > 0 do
			local chunk = math.min(elapsed, maximumElapsedSeconds)
			-- Re-validates node eligibility/range/tool/level for every chunk: an earlier chunk
			-- succeeding never grandfathers a later one.
			local result, reason = gathering.GatherForElapsed(userId, session.NodeId, chunk)
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

	function coordinator.Begin(userId: number, nodeId: string): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if type(nodeId) ~= "string" or nodeId == "" then
			return nil, "InvalidNodeId"
		end
		-- One session per player: replace whatever was running, settling it first.
		if sessions[userId] then
			coordinator.Settle(userId)
			sessions[userId] = nil
		end
		local now = clock()
		local result, reason = gathering.GatherForElapsed(userId, nodeId, BEGIN_SECONDS)
		if not result then
			return nil, reason
		end
		sessions[userId] = { NodeId = nodeId, LastSettledAt = now }
		return result, nil
	end

	function coordinator.Stop(userId: number): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not sessions[userId] then
			return nil, "NoActiveGatheringSession"
		end
		local result, reason = coordinator.Settle(userId)
		sessions[userId] = nil
		return result, reason
	end

	return table.freeze(coordinator)
end

return table.freeze(Service)
