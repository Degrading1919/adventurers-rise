--!strict

-- Thin client transport over the single trusted RemoteFunction request boundary. The client may only
-- select and request actions; every result is the server's authoritative RequestResult. No gameplay
-- logic lives here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = {}

function Net.New()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
	assert(remotes, "Missing ReplicatedStorage.Remotes; is the server bootstrap running?")
	local request = remotes:WaitForChild("Request", 30)
	assert(request and request:IsA("RemoteFunction"), "Missing Remotes.Request RemoteFunction")

	local net = {}

	-- Returns (ok, result, reason). ok is the server's authoritative RequestResult.Ok; a transport
	-- failure or malformed response is reported as a closed failure, never a fabricated success.
	function net.Request(requestId: string, payload: any?): (boolean, any?, string?)
		local ok, response = pcall(function()
			return (request :: RemoteFunction):InvokeServer(requestId, payload)
		end)
		if not ok then
			return false, nil, "RemoteError"
		end
		if type(response) ~= "table" then
			return false, nil, "MalformedResponse"
		end
		return response.Ok == true, response.Result, response.Reason
	end

	return net
end

return Net
