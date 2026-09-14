--!strict

local Schema = require(script.Parent.Schema)
local Store = require(script.Parent.Store)

export type Runtime = {
	Players: any,
	Spawn: ((...any) -> (), ...any) -> (),
	Wait: (number) -> (),
	Clock: () -> number,
	Now: () -> number,
	BindToClose: (() -> ()) -> (),
	Warn: (string) -> (),
}
type Slot = {
	Player: any,
	Loading: boolean,
	Closing: boolean,
	Releasing: boolean,
	Session: Store.Session?,
}

local Service = { AutosaveSeconds = 60, ShutdownSeconds = 25 }

function Service.New(store: Store.Backend, runtime: Runtime)
	local slots: { [number]: Slot } = {}
	local started, stopping = false, false
	local service = {}

	local function report(userId: number, operation: string, reason: string?)
		runtime.Warn(("[PlayerData] %s failed for %d: %s"):format(operation, userId, reason or "Unknown"))
	end

	local function close(slot: Slot)
		slot.Closing = true
		if slot.Loading or slot.Releasing then
			return
		end
		slot.Releasing = true
		local session = slot.Session
		if session then
			-- An autosave already in flight must finish before the final snapshot.
			while session.Busy do
				runtime.Wait(0.1)
			end
			if not session.Closed then
				local ok, reason = store.Release(session)
				if not ok then
					report(slot.Player.UserId, "release", reason)
				end
			end
		end
		if slots[slot.Player.UserId] == slot then
			slots[slot.Player.UserId] = nil
		end
	end

	local function join(player: any)
		if stopping then
			player:Kick("Server is closing. Please rejoin.")
			return
		end
		local existing = slots[player.UserId]
		if existing then
			if existing.Player ~= player then
				player:Kick("Your previous data session is closing. Please rejoin shortly.")
			end
			return
		end
		local slot: Slot = { Player = player, Loading = true, Closing = false, Releasing = false, Session = nil }
		slots[player.UserId] = slot
		runtime.Spawn(function()
			local session, reason = store.Load(player.UserId)
			slot.Loading = false
			slot.Session = session
			if not session then
				report(player.UserId, "load", reason)
				slots[player.UserId] = nil
				if not slot.Closing then
					player:Kick("Your data could not be loaded safely. Please rejoin shortly.")
				end
			elseif slot.Closing or stopping then
				close(slot)
			end
		end)
	end

	local function ready(userId: number): Store.Session?
		local slot = slots[userId]
		if stopping or not slot or slot.Loading or slot.Closing then
			return nil
		end
		local session = slot.Session
		if not session or session.Closed or session.ExpiresAt <= runtime.Now() then
			return nil
		end
		return session
	end

	function service.GetSnapshot(userId: number): Schema.Data?
		local session = ready(userId)
		return if session then Schema.Copy(session.Data) else nil
	end

	-- For trusted server systems only. Callbacks must not yield or retain mutable state.
	function service.Update(userId: number, change: (Schema.Data) -> ()): (boolean, string?)
		local session = ready(userId)
		if not session then
			return false, "NotReady"
		end
		local candidate = Schema.Copy(session.Data)
		local thread = coroutine.create(change)
		local ok = coroutine.resume(thread, candidate)
		if not ok or coroutine.status(thread) ~= "dead" then
			coroutine.close(thread)
			return false, "InvalidMutation"
		end
		if not Schema.Validate(candidate) or candidate.LastSessionAt ~= session.Data.LastSessionAt then
			return false, "InvalidData"
		end
		session.Data = Schema.Copy(candidate)
		return true, nil
	end

	function service.Start()
		assert(not started, "PlayerData already started")
		started = true
		runtime.Players.PlayerAdded:Connect(join)
		runtime.Players.PlayerRemoving:Connect(function(player: any)
			local slot = slots[player.UserId]
			if slot and slot.Player == player then
				runtime.Spawn(close, slot)
			end
		end)
		runtime.BindToClose(function()
			stopping = true
			local deadline = runtime.Clock() + Service.ShutdownSeconds
			for _, slot in slots do
				runtime.Spawn(close, slot)
			end
			while next(slots) and runtime.Clock() < deadline do
				runtime.Wait(0.1)
			end
			if next(slots) then
				runtime.Warn("[PlayerData] Shutdown deadline reached with unfinished sessions; leases will expire.")
			end
		end)
		for _, player in runtime.Players:GetPlayers() do
			join(player)
		end
		runtime.Spawn(function()
			while not stopping do
				runtime.Wait(Service.AutosaveSeconds)
				if stopping then
					break
				end
				for userId, slot in slots do
					local session = slot.Session
					if not slot.Closing and session and not session.Busy then
						runtime.Spawn(function()
							if slot.Closing then
								return
							end
							local ok, reason = store.Save(session)
							if not ok then
								report(userId, "save", reason)
								if session.Closed then
									slot.Player:Kick("Your data session ended. Please rejoin.")
									close(slot)
								end
							end
						end)
					end
				end
			end
		end)
	end

	return table.freeze(service)
end

return table.freeze(Service)
