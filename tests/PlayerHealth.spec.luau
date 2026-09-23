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

-- ===== Defense Mastery: MaxHealthBonus =====

test("a non-function Defense modifier provider is rejected", function()
	equal(pcall(PlayerHealth.New, { MaxHealth = 100 }, 5), false)
	assert(pcall(PlayerHealth.New, { MaxHealth = 100 }, function() return {} end))
end)

test("MaxHealthBonus raises maximum health and applies immediately", function()
	local bonus = 0
	local s = PlayerHealth.New({ MaxHealth = 100 }, function() return { MaxHealthBonus = bonus } end)
	-- No selections: exact base behavior.
	equal(assert(s.GetState(7)).MaxHealth, 100)
	equal(assert(s.GetState(7)).Health, 100)
	-- Selecting a +10% Fortitude total takes effect on the very next read (110 = floor(100 * 1.10)).
	bonus = 0.10
	local state = assert(s.GetState(7))
	equal(state.MaxHealth, 110)
	equal(state.Health, 110)
	equal(assert(s.Reset(7)).Health, 110)
	equal(assert(s.Reset(7)).MaxHealth, 110)
	-- Damage is dealt against the boosted maximum.
	equal(assert(s.ApplyDamage(7, 30)).Health, 80)
	equal(assert(s.ApplyDamage(7, 30)).MaxHealth, 110)
end)

test("a respec clearing MaxHealthBonus removes it immediately and clamps current health down", function()
	local bonus = 0.10
	local s = PlayerHealth.New({ MaxHealth = 100 }, function() return { MaxHealthBonus = bonus } end)
	assert(s.Reset(7))
	equal(assert(s.GetState(7)).Health, 110)
	-- Respec removes the node: the next read reflects the base maximum and clamps current health to it.
	bonus = 0
	local state = assert(s.GetState(7))
	equal(state.MaxHealth, 100)
	equal(state.Health, 100)
end)

test("a reduced maximum persists the clamp so hidden health cannot reappear when Fortitude is re-selected", function()
	local bonus = 0.10
	local s = PlayerHealth.New({ MaxHealth = 100 }, function() return { MaxHealthBonus = bonus } end)
	assert(s.Reset(7)) -- stored 110 at the boosted maximum
	equal(assert(s.GetState(7)).Health, 110)
	-- Respec removes the node; a read now (as the read-model poll does every tick) clamps the authoritative
	-- runtime value to 100 -- not merely the returned snapshot.
	bonus = 0
	equal(assert(s.GetState(7)).Health, 100)
	-- Re-selecting Fortitude raises the maximum again, but the 10 health hidden above the reduced maximum
	-- is gone for good -- it does not resurface.
	bonus = 0.10
	local restored = assert(s.GetState(7))
	equal(restored.MaxHealth, 110)
	equal(restored.Health, 100)
	-- The clamp also holds through the damage path (uses the same persisted value).
	equal(assert(s.ApplyDamage(7, 10)).Health, 90)
end)

test("the clamp persists even when the only read before re-selection is a damage application", function()
	local bonus = 0.10
	local s = PlayerHealth.New({ MaxHealth = 100 }, function() return { MaxHealthBonus = bonus } end)
	assert(s.Reset(7)) -- stored 110
	bonus = 0 -- respec, no GetState in between
	-- ApplyDamage observes the reduced max, clamps 110 -> 100 first, then applies 40 -> 60.
	equal(assert(s.ApplyDamage(7, 40)).Health, 60)
	bonus = 0.10 -- re-select: the hidden 10 must not come back (60, not 70)
	equal(assert(s.GetState(7)).Health, 60)
end)

test("spoofed or non-numeric Defense modifier values contribute no MaxHealth bonus", function()
	local s = PlayerHealth.New({ MaxHealth = 100 }, function()
		-- A string is not a trusted number; unrelated keys are ignored; a negative never lowers the base.
		return { MaxHealthBonus = "9.0", GarbageKey = 999 }
	end)
	equal(assert(s.GetState(7)).MaxHealth, 100)
	local negative = PlayerHealth.New({ MaxHealth = 100 }, function() return { MaxHealthBonus = -0.5 } end)
	equal(assert(negative.GetState(7)).MaxHealth, 100)
end)

-- ===== Defense Mastery: Resilience regeneration =====

test("Resilience RecoveryBonus regenerates a below-max living player; no bonus, full, and dead never heal", function()
	local recovery = 0.1
	local s = PlayerHealth.New({ MaxHealth = 100 }, function() return { RecoveryBonus = recovery } end)
	-- Damage to 60, then 1s of regen: heal = 100 * 0.1 * 0.5 * 1 = 5 -> 65.
	assert(s.ApplyDamage(7, 40))
	s.Regenerate(7, 1)
	equal(assert(s.GetState(7)).Health, 65)
	-- Regen never overshoots the maximum.
	s.Regenerate(7, 9999)
	equal(assert(s.GetState(7)).Health, 100)
	-- A full player needs no regen (no-op), and invalid dt is ignored.
	s.Regenerate(7, 5)
	s.Regenerate(7, 0)
	equal(assert(s.GetState(7)).Health, 100)
	-- No RecoveryBonus means no regeneration at all (baseline players are unchanged).
	recovery = 0
	assert(s.ApplyDamage(7, 30))
	s.Regenerate(7, 10)
	equal(assert(s.GetState(7)).Health, 70)
	-- A dead player does not self-heal.
	recovery = 0.1
	assert(s.ApplyDamage(7, 9999))
	s.Regenerate(7, 10)
	equal(s.IsAlive(7), false)
end)

print(("%d PlayerHealth checks passed"):format(passed))
