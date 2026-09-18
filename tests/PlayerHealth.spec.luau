--!strict

local PlayerHealth = require("PlayerHealthService")

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

test("New requires a positive MaxHealth", function()
	equal(pcall(PlayerHealth.New, { MaxHealth = 0 }), false)
	equal(pcall(PlayerHealth.New, { MaxHealth = -5 }), false)
	equal(pcall(PlayerHealth.New, {}), false)
	assert(pcall(PlayerHealth.New, { MaxHealth = 100 }))
end)

test("an uninitialised player reads as full health and alive", function()
	local s = PlayerHealth.New({ MaxHealth = 100 })
	local state = assert(s.GetState(7))
	equal(state.Health, 100)
	equal(state.MaxHealth, 100)
	equal(s.IsAlive(7), true)
end)

test("ApplyDamage reduces health and reports a non-lethal hit", function()
	local s = PlayerHealth.New({ MaxHealth = 100 })
	local result = assert(s.ApplyDamage(7, 30))
	equal(result.AppliedDamage, 30)
	equal(result.Health, 70)
	equal(result.Died, false)
	equal(assert(s.GetState(7)).Health, 70)
end)

test("overkill is clamped to remaining health and reports death exactly at zero", function()
	local s = PlayerHealth.New({ MaxHealth = 100 })
	assert(s.ApplyDamage(7, 90))
	local lethal = assert(s.ApplyDamage(7, 9999))
	equal(lethal.AppliedDamage, 10) -- only the remaining 10 is applied
	equal(lethal.Health, 0)
	equal(lethal.Died, true)
	equal(s.IsAlive(7), false)
end)

test("a dead player cannot be damaged again until revived", function()
	local s = PlayerHealth.New({ MaxHealth = 100 })
	assert(s.ApplyDamage(7, 100))
	local again, reason = s.ApplyDamage(7, 10)
	equal(again, nil)
	equal(reason, "AlreadyDead")
	-- Reset (respawn) revives to full.
	assert(s.Reset(7))
	equal(assert(s.GetState(7)).Health, 100)
	equal(s.IsAlive(7), true)
end)

test("invalid damage and invalid user fail closed", function()
	local s = PlayerHealth.New({ MaxHealth = 100 })
	equal(select(2, s.ApplyDamage(7, 0)), "InvalidDamage")
	equal(select(2, s.ApplyDamage(7, -5)), "InvalidDamage")
	equal(select(2, s.ApplyDamage(0, 5)), "InvalidUserId")
	equal(assert(s.GetState(7)).Health, 100) -- nothing was applied
end)

test("Clear discards runtime health so a fresh life reads full", function()
	local s = PlayerHealth.New({ MaxHealth = 100 })
	assert(s.ApplyDamage(7, 40))
	s.Clear(7)
	equal(assert(s.GetState(7)).Health, 100)
end)

print(("%d PlayerHealth checks passed"):format(passed))
