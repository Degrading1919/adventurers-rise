--!strict

-- REGION I SCENE BUILDER — "The Borderlands" (Studio-owned world, reproducibly generated).
--
-- HOW TO RUN: paste this script's body into the Roblox_Studio MCP `execute_luau` in EDIT mode (place id
-- 136843447225408). It rebuilds the whole Region I world: ELEVATED walkable terrain biomes (a low, flat
-- town basin that rises gently into the wilderness, with the mine hollow dipping below town level),
-- scenic edge hills, biome props/landmarks, a small town, and it relocates the tagged enemy-territory
-- markers and ore nodes into their zones, re-grounded onto the new surface. Idempotent-ish: it clears
-- terrain and the props/landmarks folder it owns, then rebuilds. It NEVER deletes the Studio-owned hub
-- instances (stations/forge/shop/spawn) or the tagged markers it only repositions.
--
-- ELEVATION MODEL: the town (radius ~55 of origin) is a flat basin at the terrain base height, so the
-- existing hub parts (Forge/Training/Shop at y~2) and spawn stay seated without being moved. Past the
-- rim the land eases upward into rolling knolls; the southern hills climb and then sink into the mine
-- hollow, a shallow bowl below town level, so descending to the mine reads as going into the earth. All
-- gradients are gentle (a few studs over tens of studs) so Humanoids and the kinematic enemy
-- terrain-follower (World/Service.luau sampleGroundY) climb them without jank. Every prop, marker, and
-- node is placed by SAMPLING the finished surface beneath its XZ, so nothing floats or sinks.
--
-- Zone centres MUST match src/Shared/RegionDefinitions.luau (the runtime zone classifier is XZ-only, so
-- elevation does not affect zone membership). Output is Studio-owned; SAVE THE PLACE to persist.
-- Placeholders live under Workspace.AR_World.Scenery and are tagged "AR_Scenery" (clean replacement seam).

local Terrain = workspace.Terrain
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local M = Enum.Material

local AR = workspace:FindFirstChild("AR_World")
assert(AR, "AR_World missing")

-- Zone centres (x, z) — keep in sync with RegionDefinitions.
local ZONES = {
	town = Vector3.new(0, 0, 0),
	meadow = Vector3.new(260, 0, 0),
	forest = Vector3.new(0, 0, 260),
	hills = Vector3.new(0, 0, -270),
	ruins = Vector3.new(-270, 0, 0),
	warren = Vector3.new(330, 0, 0),
}

local rng = Random.new(20260922) -- fixed seed => reproducible scatter

-- ---------- scenery container (owned by the builder; safe to clear/rebuild) ----------
local scenery = AR:FindFirstChild("Scenery")
if scenery then scenery:Destroy() end
scenery = Instance.new("Folder")
scenery.Name = "Scenery"
scenery.Parent = AR

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = props.CanCollide ~= false -- solid props collide by default; pass false for overhead leaves
	p.CanQuery = false
	p.CanTouch = false
	p.Material = props.Material or M.SmoothPlastic
	if props.Color then p.Color = props.Color end
	if props.Size then p.Size = props.Size end
	if props.CFrame then p.CFrame = props.CFrame end
	if props.Shape then p.Shape = props.Shape end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = props.Parent or scenery
	CollectionService:AddTag(p, "AR_Scenery")
	return p
end

-- ---------- 1) elevated walkable terrain ----------
-- Height of the TOP of the solid terrain column at (x, z). See the elevation model note above. Town is a
-- flat basin (relief eased to 0 within the rim); the wilderness rolls and rises; the mine hollow dips
-- below town level. Kept gentle on purpose.
local MINE_CENTRE = Vector3.new(0, 0, -210) -- bottom of the descent, where the mine mouth sits
local function heightTop(x: number, z: number): number
	local r = math.sqrt(x * x + z * z)
	-- Broad, low rolling knolls and swales (two long sine waves).
	local roll = 5.0 * math.sin(x / 140) * math.cos(z / 150) + 3.0 * math.sin((x + z) / 95)
	-- The frontier rises away from town (eased in past the basin rim).
	local rise = (math.clamp((r - 55) / 260, 0, 1)) ^ 1.2 * 12
	-- The southern hills band climbs.
	local hills = if z < -120 then math.clamp((-120 - z) / 180, 0, 1) * 10 else 0
	-- The mine hollow: a shallow bowl sinking below town level around the mine mouth.
	local dmb = math.sqrt((x - MINE_CENTRE.X) ^ 2 + (z - MINE_CENTRE.Z) ^ 2)
	local mineBowl = if dmb < 130 then -(1 - dmb / 130) * 16 else 0
	-- Flatten everything to the town base inside the rim, easing the relief in from radius 55 to ~95.
	local basin = math.clamp((r - 55) / 40, 0, 1)
	return math.clamp((roll + rise + hills + mineBowl) * basin, -18, 26)
end

-- Base material by zone (matches the original biome layout).
local function matAt(x: number, z: number): Enum.Material
	if math.abs(x) <= 50 and math.abs(z) <= 50 then return M.Ground end -- town plaza
	if z <= -150 then return M.Rock end -- Ironrock Hollow (S)
	if z >= 120 then return M.LeafyGrass end -- Whispering Woods (N)
	if x <= -120 then return M.Ground end -- Ashen Ruins frontier (W)
	if x >= 120 then return M.Grass end -- Green Meadows (E)
	return M.Grass -- open base
end

Terrain:Clear()
local HALF = 440 -- walkable region half-extent (studs)
local CELL = 24 -- grid resolution; smaller = smoother slopes but more fills
local BASE_Y = -60 -- deep solid base so no relief exposes a hole or lets the player fall through
-- Fill the region as a grid of columns, each rising from BASE_Y to heightTop at its centre.
for cx = -HALF, HALF, CELL do
	for cz = -HALF, HALF, CELL do
		local top = heightTop(cx, cz)
		local height = top - BASE_Y
		Terrain:FillBlock(CFrame.new(cx, (top + BASE_Y) / 2, cz), Vector3.new(CELL + 1, height, CELL + 1), matAt(cx, cz))
	end
end
-- Roads: overlay Ground columns along the four routes so travel follows a graded path over the relief.
local function road(x0: number, z0: number, x1: number, z1: number, width: number)
	local dx, dz = x1 - x0, z1 - z0
	local len = math.sqrt(dx * dx + dz * dz)
	local steps = math.ceil(len / (CELL * 0.5))
	for i = 0, steps do
		local t = i / steps
		local x, z = x0 + dx * t, z0 + dz * t
		local top = heightTop(x, z)
		Terrain:FillBlock(CFrame.new(x, (top + BASE_Y) / 2, z), Vector3.new(width, top - BASE_Y, width), M.Ground)
	end
end
road(0, 55, 0, 250, 18)   -- N to Whispering Woods
road(0, -55, 0, -300, 18)  -- S to Ironrock Hollow / the mine
road(55, 0, 300, 0, 18)   -- E to Green Meadows / Warren
road(-55, 0, -300, 0, 18)  -- W to Ashen Ruins

-- Walkable surface Y beneath (x, z), computed ANALYTICALLY from the height field rather than by raycast.
-- Terrain FillBlock writes settle asynchronously, so a raycast taken during the same build can miss the
-- fresh terrain and read stale/empty ground -- that raced grounding buried markers on the first pass.
-- heightTop is the deterministic source of the fill top; the voxel grid rounds the queryable surface a
-- couple of studs above it (measured ~2-3), so every placement rests flush without any timing hazard.
-- (The runtime enemy grounder in World/Service.luau DOES raycast -- correct there, since the terrain is
-- long since settled in a running game.)
local VOXEL_LIFT = 2.5
local function surfaceY(x: number, z: number): number
	return heightTop(x, z) + VOXEL_LIFT
end

-- Scenic edge hills beyond the walkable region: silhouette + a soft wall bounding play. Seated on the
-- local surface so they rise from the ground rather than floating.
local function hill(cx: number, cz: number, radius: number, height: number, mat: Enum.Material)
	local base = surfaceY(cx, cz)
	Terrain:FillBall(Vector3.new(cx, base, cz), radius, mat)
	Terrain:FillBall(Vector3.new(cx, base + height * 0.45, cz), radius * 0.66, mat)
end
for _, h in ipairs({
	{ 480, 0, 95, 42, M.Rock }, { -480, 0, 95, 42, M.Rock },
	{ 0, 480, 95, 36, M.Rock }, { 0, -480, 100, 50, M.Slate },
	{ 400, 400, 85, 40, M.Rock }, { -400, 400, 85, 34, M.Rock },
	{ 400, -400, 85, 44, M.Slate }, { -400, -400, 85, 42, M.Slate },
}) do hill(h[1], h[2], h[3], h[4], h[5]) end

-- ---------- 2) biome props + landmarks (all surface-grounded) ----------
local function tree(pos: Vector3)
	local base = surfaceY(pos.X, pos.Z)
	part({ Size = Vector3.new(2, 12, 2), Color = Color3.fromRGB(96, 66, 42), Material = M.Wood,
		CFrame = CFrame.new(pos.X, base + 6, pos.Z) })
	part({ Size = Vector3.new(12, 12, 12), Shape = Enum.PartType.Ball, Color = Color3.fromRGB(58, 120, 55),
		Material = M.Grass, CFrame = CFrame.new(pos.X, base + 14, pos.Z), CanCollide = false, Parent = scenery })
end
local function rock(pos: Vector3, s: number)
	local base = surfaceY(pos.X, pos.Z)
	part({ Size = Vector3.new(s, s * 0.8, s), Shape = Enum.PartType.Block, Color = Color3.fromRGB(115, 115, 122),
		Material = M.Slate, CFrame = CFrame.new(pos.X, base + s * 0.35, pos.Z) * CFrame.Angles(0, rng:NextNumber() * 6, 0.1) })
end
local function scatter(centre: Vector3, radius: number, count: number, make: (Vector3) -> ())
	for _ = 1, count do
		local a, r = rng:NextNumber() * math.pi * 2, math.sqrt(rng:NextNumber()) * radius
		make(centre + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
	end
end
scatter(ZONES.forest, 190, 34, tree) -- Whispering Woods
scatter(Vector3.new(120, 0, 180), 60, 8, tree) -- treeline between town and forest
scatter(ZONES.hills, 180, 22, function(p) rock(p, rng:NextInteger(5, 11)) end) -- Ironrock Hollow

-- Mine entrance (S, at the bottom of the hollow): a dark stone archway + timber frame.
do
	local base = surfaceY(MINE_CENTRE.X, MINE_CENTRE.Z)
	local c = Vector3.new(MINE_CENTRE.X, base, MINE_CENTRE.Z)
	part({ Size = Vector3.new(26, 3, 20), Color = Color3.fromRGB(70, 66, 60), Material = M.Rock, CFrame = CFrame.new(c + Vector3.new(0, 1.5, 0)) })
	part({ Size = Vector3.new(6, 14, 6), Color = Color3.fromRGB(70, 66, 60), Material = M.Rock, CFrame = CFrame.new(c + Vector3.new(-9, 7, -6)) })
	part({ Size = Vector3.new(6, 14, 6), Color = Color3.fromRGB(70, 66, 60), Material = M.Rock, CFrame = CFrame.new(c + Vector3.new(9, 7, -6)) })
	part({ Size = Vector3.new(24, 4, 6), Color = Color3.fromRGB(96, 66, 42), Material = M.Wood, CFrame = CFrame.new(c + Vector3.new(0, 13, -6)) })
	part({ Size = Vector3.new(12, 10, 3), Color = Color3.fromRGB(20, 18, 16), Material = M.Slate, CFrame = CFrame.new(c + Vector3.new(0, 5, -8)) }) -- dark mouth
end

-- Ruined watchtower + rubble (W): a visible, dangerous frontier POI (the Bandit Warlord holds it).
do
	local base = surfaceY(ZONES.ruins.X, ZONES.ruins.Z)
	local c = Vector3.new(ZONES.ruins.X, base, ZONES.ruins.Z)
	for i = 0, 3 do
		part({ Size = Vector3.new(22 - i * 3, 8, 22 - i * 3), Shape = Enum.PartType.Block, Color = Color3.fromRGB(120, 112, 100), Material = M.Slate,
			CFrame = CFrame.new(c + Vector3.new(0, 4 + i * 8, 0)) * CFrame.Angles(0, i * 0.15, 0) })
	end
	part({ Size = Vector3.new(24, 10, 8), Color = Color3.fromRGB(120, 112, 100), Material = M.Slate, CFrame = CFrame.new(c + Vector3.new(0, 5, 0)) * CFrame.Angles(0.3, 0.4, 0.1) }) -- fallen slab
	scatter(ZONES.ruins, 70, 14, function(p) rock(p, rng:NextInteger(3, 7)) end)
end

-- Town buildings (a few placeholder cottages around the plaza) so Havenbrook reads as a town.
local function cottage(pos: Vector3, rot: number)
	local base = surfaceY(pos.X, pos.Z)
	part({ Size = Vector3.new(16, 10, 14), Color = Color3.fromRGB(150, 130, 96), Material = M.WoodPlanks, CFrame = CFrame.new(pos.X, base + 5, pos.Z) * CFrame.Angles(0, rot, 0) })
	part({ Size = Vector3.new(19, 6, 17), Color = Color3.fromRGB(120, 60, 45), Material = M.Slate, CFrame = CFrame.new(pos.X, base + 12, pos.Z) * CFrame.Angles(0, rot, 0) })
end
cottage(Vector3.new(-52, 0, -42), 0.2)
cottage(Vector3.new(52, 0, -46), -0.2)
cottage(Vector3.new(-58, 0, 44), 0.1)
cottage(Vector3.new(56, 0, 40), -0.1)

-- Goblin warren totems (deep E, around the Chieftain) — a crude, ominous landmark.
do
	for i = 1, 6 do
		local a = i / 6 * math.pi * 2
		local x, z = ZONES.warren.X + math.cos(a) * 34, ZONES.warren.Z + math.sin(a) * 34
		local base = surfaceY(x, z)
		part({ Size = Vector3.new(2.5, 12, 2.5), Color = Color3.fromRGB(80, 70, 50), Material = M.Wood, CFrame = CFrame.new(x, base + 6, z) })
	end
end

-- Keep tower on the SW corner of Havenbrook: the tallest structure and a region-wide sightline anchor.
do
	local cx, cz = -46, -46
	local base = surfaceY(cx, cz)
	part({ Size = Vector3.new(22, 44, 22), Color = Color3.fromRGB(128, 122, 110), Material = M.Brick, CFrame = CFrame.new(cx, base + 22, cz) })
	part({ Size = Vector3.new(27, 5, 27), Color = Color3.fromRGB(96, 60, 45), Material = M.Slate, CFrame = CFrame.new(cx, base + 46, cz) })
	part({ Size = Vector3.new(6, 16, 6), Color = Color3.fromRGB(150, 60, 45), Material = M.Slate, CFrame = CFrame.new(cx, base + 55, cz) })
	part({ Size = Vector3.new(2.5, 9, 2.5), Shape = Enum.PartType.Cylinder, Color = Color3.fromRGB(210, 190, 70), Material = M.Neon, CanCollide = false, CFrame = CFrame.new(cx, base + 64, cz) * CFrame.Angles(0, 0, math.rad(90)) })
end
-- Tall rock spires as sightline landmarks that frame the wild zones and break up the horizon.
local function spire(pos: Vector3, h: number, mat: Enum.Material?)
	local base = surfaceY(pos.X, pos.Z)
	part({ Size = Vector3.new(10, h, 10), Color = Color3.fromRGB(96, 96, 104), Material = mat or M.Rock, CFrame = CFrame.new(pos.X, base + h / 2, pos.Z) * CFrame.Angles(0.04, 0, 0.03) })
	part({ Size = Vector3.new(6, h * 0.5, 6), Color = Color3.fromRGB(86, 86, 96), Material = mat or M.Rock, CFrame = CFrame.new(pos.X + 3, base + h * 0.85, pos.Z - 1) * CFrame.Angles(0.12, 0, -0.06) })
end
spire(ZONES.hills + Vector3.new(-46, 0, -34), 46)
spire(ZONES.hills + Vector3.new(50, 0, -12), 34)
spire(ZONES.ruins + Vector3.new(-36, 0, 44), 42, M.Slate)
spire(ZONES.warren + Vector3.new(0, 0, -50), 32)
scatter(Vector3.new(220, 0, 15), 120, 10, function(p) rock(p, rng:NextInteger(3, 6)) end)
scatter(Vector3.new(60, 0, 150), 55, 10, tree)

-- ---------- 3) remove the old flat floor part (terrain replaces it) ----------
local oldGround = AR:FindFirstChild("Ground")
if oldGround then oldGround:Destroy() end

-- ---------- 4) relocate enemy-territory markers + ore nodes into their zones (surface-grounded) ----------
-- Creates-or-updates a territory marker fully (the builder owns all territory placement). levelMin/Max
-- give a REAL difficulty-by-distance gradient (World reads them; Enemies.Create clamps into the
-- archetype band; nil = archetype default). tuning holds optional movement overrides (bosses stay put).
local TUNING_KEYS = { "RoamRadius", "LeashRadius", "AggroRadius", "DeaggroRadius", "RoamSpeed", "ChaseSpeed" }
local function ensureTerritory(id, defId, x, z, radius, population, levelMin, levelMax, tuning)
	local terr = AR:FindFirstChild("Territories")
	if not terr then terr = Instance.new("Folder"); terr.Name = "Territories"; terr.Parent = AR end
	local m
	for _, c in ipairs(terr:GetChildren()) do if c:GetAttribute("TerritoryId") == id then m = c end end
	if not m then
		m = Instance.new("Part")
		m.Name = "Territory_" .. id
		m.Anchored = true; m.CanCollide = false; m.CanQuery = false; m.CanTouch = false; m.Transparency = 1; m.Size = Vector3.new(2, 1, 2)
		CollectionService:AddTag(m, "AR_EnemyTerritory")
		m.Parent = terr
	end
	-- Marker centre sits on the finished surface; enemies seat on its top and then follow the terrain.
	m.Position = Vector3.new(x, surfaceY(x, z), z)
	m:SetAttribute("TerritoryId", id)
	m:SetAttribute("EnemyDefinitionId", defId)
	m:SetAttribute("Radius", radius)
	m:SetAttribute("Population", population)
	m:SetAttribute("LevelMin", levelMin)
	m:SetAttribute("LevelMax", levelMax)
	for _, k in ipairs(TUNING_KEYS) do m:SetAttribute(k, tuning and tuning[k] or nil) end
end
local BOSS_TUNING = { RoamRadius = 6, LeashRadius = 34, AggroRadius = 30 } -- bosses hold their ground/arena
-- Region I populations on a radial difficulty gradient (easiest near town, hardest deep/out):
ensureTerritory("wolf_den", "enemy_wolf", 0, 255, 52, 5, 2, 4)             -- Whispering Woods (starter)
ensureTerritory("goblin_camp", "enemy_goblin", 160, 25, 46, 5, 3, 4)        -- near-town goblins
ensureTerritory("goblin_ruins", "enemy_goblin", 255, -60, 44, 4, 6, 8)      -- deeper, bolder goblins
ensureTerritory("hobgoblin_hollow", "enemy_hobgoblin", 0, -360, 48, 4, 6, 10) -- deep Ironrock Hollow (past the mine)
ensureTerritory("bandit_camp", "enemy_bandit", -230, 40, 50, 4, 5, 9)        -- Ashen Ruins
ensureTerritory("warlord_tower", "enemy_bandit_warlord", -270, 0, 8, 1, nil, nil, BOSS_TUNING) -- ruined watchtower boss
ensureTerritory("chieftain_arena", "enemy_goblin_chieftain", 330, 10, 8, 1, nil, nil, BOSS_TUNING) -- Warren boss
-- Players spawn on the surface, not inside the terrain.
local spawn = workspace:FindFirstChild("AR_Spawn")
if spawn and spawn:IsA("BasePart") then spawn.Position = Vector3.new(spawn.Position.X, surfaceY(spawn.Position.X, spawn.Position.Z) + spawn.Size.Y / 2, spawn.Position.Z) end

-- Iron Ore nodes -> Ironrock Hollow (spread in a small vein near the mine entrance), on the surface.
local iron = AR:FindFirstChild("IronOre")
if iron then
	local spots = { Vector3.new(-14, 0, -6), Vector3.new(-4, 0, 4), Vector3.new(8, 0, -8), Vector3.new(16, 0, 6) }
	local i = 1
	for _, node in ipairs(iron:GetChildren()) do
		if node:IsA("BasePart") and spots[i] then
			local x, z = ZONES.hills.X + spots[i].X, ZONES.hills.Z + spots[i].Z
			node.Position = Vector3.new(x, surfaceY(x, z) + node.Size.Y / 2, z)
			i += 1
		end
	end
end

-- ---------- 4b) Coal seam -> DEEP Ironrock Hollow (past the mine, by the hobgoblins) ----------
-- Second resource, behind the steel tier. Sited deep in the hollow near hobgoblin_hollow so gathering it
-- is a step up in danger from the safe starter iron vein — a real difficulty gradient for resources.
-- Each rock is tagged AR_GatheringNode with the stable node id, so World.GatheringNodeResolver and the
-- client discover them generically (same seam as Iron Ore).
local coalFolder = AR:FindFirstChild("Coal")
if not coalFolder then coalFolder = Instance.new("Folder"); coalFolder.Name = "Coal"; coalFolder.Parent = AR end
coalFolder:ClearAllChildren()
local COAL_SPOTS = {
	Vector3.new(-12, 0, -318), Vector3.new(2, 0, -330), Vector3.new(14, 0, -320), Vector3.new(-2, 0, -342),
}
for i, spot in ipairs(COAL_SPOTS) do
	local n = Instance.new("Part")
	n.Name = "CoalNode_" .. i
	n.Anchored = true; n.CanCollide = true; n.CanQuery = true; n.CanTouch = false
	n.Material = M.Slate; n.Color = Color3.fromRGB(28, 28, 34)
	n.Size = Vector3.new(4.5, 3, 4.5)
	n.Position = Vector3.new(spot.X, surfaceY(spot.X, spot.Z) + n.Size.Y / 2, spot.Z)
	n.TopSurface = Enum.SurfaceType.Smooth; n.BottomSurface = Enum.SurfaceType.Smooth
	n:SetAttribute("GatheringNodeId", "node_coal")
	CollectionService:AddTag(n, "AR_GatheringNode")
	n.Parent = coalFolder
end

-- ---------- 5) lighting mood: bright, clear grounded-medieval afternoon ----------
Lighting.ClockTime = 14
Lighting.Brightness = 3
Lighting.OutdoorAmbient = Color3.fromRGB(140, 140, 145)
Lighting.Ambient = Color3.fromRGB(90, 90, 95)
local atmos = Lighting:FindFirstChildOfClass("Atmosphere")
if atmos then atmos.Density = 0.08; atmos.Haze = 0.4; atmos.Glare = 0; atmos.Color = Color3.fromRGB(220, 224, 230); atmos.Decay = Color3.fromRGB(150, 160, 175) end

return ("Region I 'The Borderlands' built: elevated terrain (town basin -> rolling wilderness -> mine hollow) + %d scenery parts; town, mine, ruins, warren landmarks; territories & iron re-grounded to zones; %d coal nodes seeded deep in Ironrock Hollow. SAVE THE PLACE to persist."):format(#scenery:GetChildren(), #coalFolder:GetChildren())
