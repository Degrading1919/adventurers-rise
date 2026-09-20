--!strict

-- Trusted server-owned continuous-gathering coordinator. Gathering.Service intentionally accepts
-- an elapsed duration because it was built below the remote layer; this module is the only place
-- allowed to compute that duration, always from the injected server clock, never from a client.
export type Gathering = {
	read GatherForElapsed: (number, string, number) -> (any?, string?),
	read ValidateForBegin: (number, string) -> (any?, string?),
	read ResetCarry: (number) -> (),
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

-- onOreAwarded (optional): a best-effort presentation/observer sink fired once per settled chunk that
-- actually awarded ore, with the Gathering Result. It owns no gameplay authority (the award already
-- committed inside GatherForElapsed) and MUST NOT raise -- callers wrap their own work defensively so a
-- misbehaving observer can never break the shared settlement heartbeat.
function Service.New(gathering: Gathering, maximumElapsedSeconds: number, clock: () -> number, onOreAwarded: ((number, any) -> ())?): Coordinator
	assert(type(gathering) == "table" and type(gathering.GatherForElapsed) == "function" and type(gathering.ValidateForBegin) == "function" and type(gathering.ResetCarry) == "function", "GatheringSessions requires Gathering")
	assert(type(maximumElapsedSeconds) == "number" and maximumElapsedSeconds > 0, "GatheringSessions requires a positive chunk boundary")
	assert(type(clock) == "function", "GatheringSessions requires a trusted server clock")
	assert(onOreAwarded == nil or type(onOreAwarded) == "function", "GatheringSessions onOreAwarded must be a function when provided")
	local notifyOreAwarded: (number, any) -> () = onOreAwarded or function() end

	local sessions: { [number]: { NodeId: string, LastSettledAt: number } } = {}
	local coordinator = {}

	function coordinator.Clear(userId: number)
		sessions[userId] = nil
		gathering.ResetCarry(userId)
	end

	-- Called by Composition's shared heartbeat, never per-player: settles every currently active
	-- session by whatever real elapsed time has passed since its last settlement. Snapshot the
	-- user IDs first since a failed Settle clears its own entry mid-iteration.
	function coordinator.SettleAllActive()
		local userIds: { number } = {}
		for userId in sessions do
			table.insert(userIds, userId)
		end
		for _, userId in userIds do
			coordinator.Settle(userId)
		end
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
				-- "GatheringIntervalTooShort" is not a validation failure: the node/tool/level are all
				-- still valid, only less than one whole unit of real time has accumulated so far (the
				-- 1s heartbeat can fire its first tick a fraction of a second after Begin). Keep the
				-- session and its unspent time -- never advance LastSettledAt -- so the next settlement
				-- includes it, instead of killing a perfectly valid continuous-gathering session. Any
				-- other reason (out of range, tool unequipped, level lost) still fails closed.
				if reason == "GatheringIntervalTooShort" then
					return nil, reason
				end
				-- A real validation failure (out of range, tool unequipped, level lost, ...) ends the
				-- session. Tear it down through the normal clear path so its fractional ore carry is
				-- discarded immediately, exactly as on Stop/disconnect -- never left to leak into a later
				-- session for this user.
				coordinator.Clear(userId)
				return nil, reason
			end
			lastResult = result
			-- This chunk committed a real ore award; report it (best-effort) for observers such as the
			-- onboarding first-ore milestone. It never affects the authoritative settlement.
			notifyOreAwarded(userId, result)
			elapsed -= chunk
			session.LastSettledAt += chunk
		end
		return lastResult, nil
	end

	-- Begin never awards ore or XP: it only proves the node/tool/player state is valid right now
	-- (via Gathering's own ValidateForBegin, the same validation GatherForElapsed uses) and starts
	-- the trusted server-timed session at the current monotonic clock reading. All progress comes
	-- from real elapsed time, settled periodically and on Stop.
	function coordinator.Begin(userId: number, nodeId: string): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if type(nodeId) ~= "string" or nodeId == "" then
			return nil, "InvalidNodeId"
		end
		-- One session per player: replace whatever was running, settling it first so no already-
		-- elapsed time is lost or duplicated.
		if sessions[userId] then
			coordinator.Settle(userId)
			sessions[userId] = nil
		end
		local info, reason = gathering.ValidateForBegin(userId, nodeId)
		if not info then
			return nil, reason
		end
		sessions[userId] = { NodeId = nodeId, LastSettledAt = clock() }
		-- A fresh session starts with no inherited fractional ore (any prior session was settled above).
		gathering.ResetCarry(userId)
		return info, nil
	end

	function coordinator.Stop(userId: number): (any?, string?)
		if not validUserId(userId) then
			return nil, "InvalidUserId"
		end
		if not sessions[userId] then
			return nil, "NoActiveGatheringSession"
		end
		local result, reason = coordinator.Settle(userId)
		-- Settle above committed any final whole ore (threading the carry); Clear then drops the session
		-- and its sub-unit remainder.
		coordinator.Clear(userId)
		return result, reason
	end

	return table.freeze(coordinator)
end

return table.freeze(Service)
