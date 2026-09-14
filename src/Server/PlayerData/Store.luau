--!strict

local Schema = require(script.Parent.Schema)
local Migrations = require(script.Parent.Migrations)

export type Session = {
	UserId: number,
	Token: string,
	Data: Schema.Data,
	ExpiresAt: number,
	Busy: boolean,
	Closed: boolean,
}
export type Runtime = {
	Now: () -> number,
	Sleep: (number) -> (),
	NewToken: () -> string,
}
export type Backend = {
	read Load: (number) -> (Session?, string?),
	read Save: (Session) -> (boolean, string?),
	read Release: (Session) -> (boolean, string?),
}

local Store = { LeaseSeconds = 180, Attempts = 3 }

function Store.New(dataStore: any, runtime: Runtime): Backend
	local store = {}

	local function update(userId: number, transform: (any, any) -> ...any): (boolean, any)
		for attempt = 1, Store.Attempts do
			local ok, result = pcall(function()
				return dataStore:UpdateAsync("player_" .. tostring(userId), transform)
			end)
			if ok then
				return true, result
			end
			if attempt < Store.Attempts then
				runtime.Sleep(2 ^ (attempt - 1))
			end
		end
		return false, nil
	end

	local function envelopeValid(record: any): boolean
		-- The transport envelope adds one level around the validated player data.
		if type(record) ~= "table" or not Schema.IsSerializable(record, Schema.MaxDepth + 1) or type(record.Data) ~= "table" then
			return false
		end
		for key in record do
			if key ~= "Data" and key ~= "Session" and key ~= "LastWriteId" then
				return false
			end
		end
		local lease = record.Session
		return (record.LastWriteId == nil or type(record.LastWriteId) == "string")
			and (lease == nil or (type(lease) == "table" and type(lease.Token) == "string"
				and type(lease.ExpiresAt) == "number" and lease.ExpiresAt >= 0 and lease.ExpiresAt % 1 == 0))
	end

	local function keepMetadata(record: any, info: any, userId: number): ...any
		local existingIds: { number } = if info then info:GetUserIds() else {}
		local ids = table.clone(existingIds)
		if not table.find(ids, userId) then
			table.insert(ids, userId)
		end
		return record, ids, if info then info:GetMetadata() else {}
	end

	function store.Load(userId: number): (Session?, string?)
		if userId <= 0 or userId % 1 ~= 0 or userId > 9007199254740991 then
			return nil, "InvalidUserId"
		end
		local token = runtime.NewToken()
		local reason: string? = nil
		local ok, record = update(userId, function(old, info)
			reason = nil -- UpdateAsync can rerun this callback after a competing write.
			if old ~= nil and not envelopeValid(old) then
				reason = "InvalidRecord"
				return nil
			end
			local now = runtime.Now()
			if old and old.Session and old.Session.Token ~= token and old.Session.ExpiresAt > now then
				reason = "SessionLocked"
				return nil
			end
			local data, migrationReason
			if old == nil then
				data = Schema.New()
			else
				data, migrationReason = Migrations.ToCurrent(old.Data)
			end
			if not data then
				reason = migrationReason
				return nil
			end
			return keepMetadata({
				Data = data,
				Session = { Token = token, ExpiresAt = now + Store.LeaseSeconds },
			}, info, userId)
		end)
		if not ok then
			return nil, "DataStoreUnavailable"
		end
		if not record then
			return nil, reason or "LoadCancelled"
		end
		if not record.Session or record.Session.Token ~= token or record.Session.ExpiresAt <= runtime.Now() then
			return nil, "SessionLost"
		end
		return {
			UserId = userId, Token = token, Data = Schema.Copy(record.Data),
			ExpiresAt = record.Session.ExpiresAt, Busy = false, Closed = false,
		}, nil
	end

	local function write(session: Session, release: boolean): (boolean, string?)
		if session.Closed then
			return false, "SessionClosed"
		elseif session.Busy then
			return false, "SessionBusy"
		elseif session.ExpiresAt <= runtime.Now() then
			session.Closed = true
			return false, "SessionLost"
		elseif not Schema.Validate(session.Data) then
			return false, "InvalidData"
		end
		session.Busy = true
		local snapshot = Schema.Copy(session.Data)
		local writeId = runtime.NewToken()
		local reason: string? = nil
		local ok, record = update(session.UserId, function(old, info)
			reason = nil
			if not envelopeValid(old) then
				reason = "InvalidRecord"
				return nil
			end
			-- A previous attempt may have committed but lost its network response.
			if old.LastWriteId == writeId then
				return keepMetadata(old, info, session.UserId)
			end
			local now = runtime.Now()
			if not old.Session or old.Session.Token ~= session.Token or old.Session.ExpiresAt <= now then
				reason = "SessionLost"
				return nil
			end
			local saved = Schema.Copy(snapshot)
			saved.LastSessionAt = now
			return keepMetadata({
				Data = saved,
				Session = if release then nil else { Token = session.Token, ExpiresAt = now + Store.LeaseSeconds },
				LastWriteId = writeId,
			}, info, session.UserId)
		end)
		session.Busy = false
		if not ok then
			if session.ExpiresAt <= runtime.Now() then
				session.Closed = true
				return false, "SessionLost"
			end
			return false, "DataStoreUnavailable"
		end
		if not record or record.LastWriteId ~= writeId then
			session.Closed = true
			return false, reason or "SaveCancelled"
		end
		if not release and (not record.Session or record.Session.ExpiresAt <= runtime.Now()) then
			session.Closed = true
			return false, "SessionLost"
		end
		-- Do not replace data edited by the server while UpdateAsync was yielding.
		session.Data.LastSessionAt = record.Data.LastSessionAt
		if release then
			session.Closed = true
		else
			session.ExpiresAt = record.Session.ExpiresAt
		end
		return true, nil
	end

	function store.Save(session: Session): (boolean, string?)
		return write(session, false)
	end

	function store.Release(session: Session): (boolean, string?)
		if session.Closed then
			return false, "SessionClosed"
		end
		return write(session, true)
	end

	table.freeze(store)
	return store
end

return table.freeze(Store)
