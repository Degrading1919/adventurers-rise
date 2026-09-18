--!strict

-- Deterministic tests for World's multiplayer target selection. A live two-player Studio session
-- cannot be driven headlessly here, so the selection logic is extracted as the pure
-- World.SelectAttackTarget and verified directly against a fake resolver.

local World = require("WorldService")

local passed = 0
local function test(name, run)
	local ok, message = pcall(run)
	assert(ok, name .. ": " .. tostring(message))
	passed += 1
	print("PASS " .. name)
end
local function equal(actual, expected)
	assert(actual == expected, ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
end

-- Resolver double: `engaged` is the set of userIds the enemy will actually attack (aggressive or
-- provoked). Records call order so we can assert nearest-first evaluation and stop-at-first-hit.
local function resolver(engaged)
	local calls = {}
	local fn = function(userId)
		table.insert(calls, userId)
		if engaged[userId] then
			return { landed = true, target = userId }
		end
		return nil, "NotEngaged"
	end
	return fn, calls
end

test("a nearer passive player does not block an eligible farther player", function()
	local fn, calls = resolver({ [2] = true }) -- only player 2 is engaged
	local candidates = {
		{ UserId = 1, Distance = 3 }, -- closest, passive/overleveled
		{ UserId = 2, Distance = 9 }, -- farther, eligible
	}
	local chosen, result = World.SelectAttackTarget(candidates, fn)
	assert(chosen ~= nil and result ~= nil, "an eligible target must be chosen")
	equal(chosen.UserId, 2)
	equal(result.target, 2)
	-- Nearest was evaluated first and skipped, then the eligible farther one was hit; no further tries.
	equal(calls[1], 1)
	equal(calls[2], 2)
	equal(#calls, 2)
end)

test("the nearest engaged player is chosen and no farther player is attacked", function()
	local fn, calls = resolver({ [1] = true, [2] = true })
	local candidates = {
		{ UserId = 2, Distance = 9 },
		{ UserId = 1, Distance = 3 }, -- given out of order; must still be picked as nearest
	}
	local chosen = assert(World.SelectAttackTarget(candidates, fn))
	equal(chosen.UserId, 1)
	equal(#calls, 1) -- stops at the first (nearest) engaged target
	equal(calls[1], 1)
end)

test("no engaged candidate in range yields no attack", function()
	local fn, calls = resolver({}) -- nobody engaged
	local candidates = { { UserId = 1, Distance = 3 }, { UserId = 2, Distance = 9 } }
	local chosen, result = World.SelectAttackTarget(candidates, fn)
	equal(chosen, nil)
	equal(result, nil)
	equal(#calls, 2) -- both tried, both passive
end)

test("an empty candidate list yields no attack", function()
	local fn = resolver({ [1] = true })
	local chosen = World.SelectAttackTarget({}, fn)
	equal(chosen, nil)
end)

print(("%d World checks passed"):format(passed))
