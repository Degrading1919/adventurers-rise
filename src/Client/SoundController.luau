--!strict

-- Client-side UI/feedback audio: a tiny, data-driven layer over engine-shipped `rbxasset://sounds/*`
-- assets (verified to load, so no marketplace dependency). One pooled 2D Sound per event key, replayed
-- on demand. The audio counterpart to the client's visual feedback (hit flash, banners, toasts). A
-- module-level singleton so every client module shares one pool via `require`; no injection needed.
-- Clean replacement seam: swap the ids/volumes in SOUNDS for bespoke assets later without touching callers.

local SoundService = game:GetService("SoundService")

export type Spec = { Id: string, Volume: number }

-- Event key -> engine built-in sound. Short UI clips, chosen so nothing loops or lingers.
local SOUNDS: { [string]: Spec } = {
	LevelUp = { Id = "rbxasset://sounds/victory.wav", Volume = 0.5 },
	Discovery = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.55 },
	Objective = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.55 },
	Hit = { Id = "rbxasset://sounds/hit.wav", Volume = 0.3 },
	Craft = { Id = "rbxasset://sounds/metal.mp3", Volume = 0.5 },
	Ascend = { Id = "rbxasset://sounds/victory.wav", Volume = 0.6 },
	BossReward = { Id = "rbxasset://sounds/victory.wav", Volume = 0.65 },
	Equip = { Id = "rbxasset://sounds/switch.wav", Volume = 0.4 },
	Banner = { Id = "rbxasset://sounds/switch.wav", Volume = 0.3 },
}

-- Pool is created lazily on first Play (client context only), parented to SoundService so each plays as
-- a 2D UI sound with no 3D falloff. Replaying resets TimePosition; overlapping plays of one key restart
-- it, which is fine for short blips. An unknown key is a silent no-op.
local pool: { [string]: Sound } = {}
local initialized = false
local function ensureInitialized()
	if initialized then
		return
	end
	initialized = true
	for key, spec in SOUNDS do
		local sound = Instance.new("Sound")
		sound.Name = "AR_Sound_" .. key
		sound.SoundId = spec.Id
		sound.Volume = spec.Volume
		sound.Parent = SoundService
		pool[key] = sound
	end
end

local SoundController = {}

function SoundController.Play(key: string)
	ensureInitialized()
	local sound = pool[key]
	if sound then
		sound.TimePosition = 0
		sound:Play()
	end
end

return table.freeze(SoundController)
