--!strict

-- REGION I SCENE BUILDER — "The Marchlands" (Studio-owned world, reproducibly generated).
--
-- HOW TO RUN: paste this script's body into the Roblox_Studio MCP `execute_luau` in EDIT mode (place id
-- 136843447225408). It rebuilds the whole Region I world: terrain biomes on a flat walkable surface,
-- scenic edge hills + a river, biome props/landmarks, a small town, and it relocates the existing hub
-- content, enemy-territory markers, and ore nodes into their zones. Idempotent-ish: it clears terrain
-- and the props/landmarks folder it owns, then rebuilds. It NEVER deletes the Git-owned hub instances
-- (stations/forge/shop/spawn) or the tagged markers it only repositions.
--
-- Zone centres MUST match src/Shared/RegionDefinitions.luau (the runtime zone classifier). Output is
-- Studio-owned; SAVE THE PLACE to persist. Placeholders (part trees/rocks/ruins/buildings) carry a
-- clean replacement seam: they live under Workspace.AR_World.Scenery and are tagged "AR_Scenery".

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
	p.CanCollide = props.CanCollide == true
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

-- ---------- 1) terrain: flat walkable biomes (top y=0) + scenic edge hills + river ----------
local function floor(cx: number, cz: number, sx: number, sz: number, mat: Enum.Material)
	local h = 8
	Terrain:FillBlock(CFrame.new(cx, -h / 2, cz), Vector3.new(sx, h, sz), mat)
end
local function hill(cx: number, cz: number, r: number, height: number, mat: Enum.Material)
	Terrain:FillBall(Vector3.new(cx, 0, cz), r, mat)
	Terrain:FillBall(Vector3.new(cx, height * 0.45, cz), r * 0.66, mat)
end

Terrain:Clear()
floor(0, 0, 940, 940, M.Grass) -- base
floor(260, 0, 400, 360, M.Grass) -- meadow (E)
floor(0, 260, 360, 400, M.LeafyGrass) -- forest (N)
floor(0, -270, 380, 380, M.Rock) -- hills/mine (S)
floor(0, -170, 220, 140, M.Ground) -- dirt approach to the mine
floor(-270, 0, 360, 380, M.Ground) -- ruins frontier (W)
floor(0, 0, 96, 96, M.Ground) -- town plaza
floor(0, 0, 24, 300, M.Ground) -- N-S road
floor(0, 0, 300, 24, M.Ground) -- E-W road
for _, h in ipairs({
	{ 480, 0, 95, 42, M.Rock }, { -480, 0, 95, 42, M.Rock },
	{ 0, 480, 95, 36, M.Rock }, { 0, -480, 100, 50, M.Slate },
	{ 400, 400, 85, 40, M.Rock }, { -400, 400, 85, 34, M.Rock },
	{ 400, -400, 85, 44, M.Slate }, { -400, -400, 85, 42, M.Slate },
}) do hill(h[1], h[2], h[3], h[4], h[5]) end
Terrain:FillBlock(CFrame.new(-150, -3, 300), Vector3.new(50, 8, 230), M.Water) -- NW river

-- ---------- 2) biome props + landmarks ----------
local function tree(pos: Vector3)
	local trunk = part({ Size = Vector3.new(2, 12, 2), Color = Color3.fromRGB(96, 66, 42), Material = M.Wood,
		CFrame = CFrame.new(pos + Vector3.new(0, 6, 0)) })
	part({ Size = Vector3.new(12, 12, 12), Shape = Enum.PartType.Ball, Color = Color3.fromRGB(58, 120, 55),
		Material = M.Grass, CFrame = CFrame.new(pos + Vector3.new(0, 14, 0)), Parent = scenery })
	return trunk
end
local function rock(pos: Vector3, s: number)
	part({ Size = Vector3.new(s, s * 0.8, s), Shape = Enum.PartType.Block, Color = Color3.fromRGB(115, 115, 122),
		Material = M.Slate, CFrame = CFrame.new(pos + Vector3.new(0, s * 0.35, 0)) * CFrame.Angles(0, rng:NextNumber() * 6, 0.1) })
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

-- Mine entrance (S, in the hills): a dark stone archway + timber frame.
do
	local base = ZONES.hills + Vector3.new(0, 0, 60)
	part({ Size = Vector3.new(26, 3, 20), Color = Color3.fromRGB(70, 66, 60), Material = M.Rock, CFrame = CFrame.new(base + Vector3.new(0, 1.5, 0)) })
	part({ Size = Vector3.new(6, 14, 6), Color = Color3.fromRGB(70, 66, 60), Material = M.Rock, CFrame = CFrame.new(base + Vector3.new(-9, 7, -6)) })
	part({ Size = Vector3.new(6, 14, 6), Color = Color3.fromRGB(70, 66, 60), Material = M.Rock, CFrame = CFrame.new(base + Vector3.new(9, 7, -6)) })
	part({ Size = Vector3.new(24, 4, 6), Color = Color3.fromRGB(96, 66, 42), Material = M.Wood, CFrame = CFrame.new(base + Vector3.new(0, 13, -6)) })
	part({ Size = Vector3.new(12, 10, 3), Color = Color3.fromRGB(20, 18, 16), Material = M.Slate, CFrame = CFrame.new(base + Vector3.new(0, 5, -8)) }) -- dark mouth
end

-- Ruined watchtower + rubble (W): a visible, future-dangerous frontier POI (bandits arrive in Phase 2).
do
	local base = ZONES.ruins
	for i = 0, 3 do
		part({ Size = Vector3.new(22 - i * 3, 8, 22 - i * 3), Shape = Enum.PartType.Block, Color = Color3.fromRGB(120, 112, 100), Material = M.Slate,
			CFrame = CFrame.new(base + Vector3.new(0, 4 + i * 8, 0)) * CFrame.Angles(0, i * 0.15, 0) })
	end
	part({ Size = Vector3.new(24, 10, 8), Color = Color3.fromRGB(120, 112, 100), Material = M.Slate, CFrame = CFrame.new(base + Vector3.new(0, 5, 0)) * CFrame.Angles(0.3, 0.4, 0.1) }) -- fallen slab
	scatter(base, 70, 14, function(p) rock(p, rng:NextInteger(3, 7)) end)
end

-- Town buildings (a few placeholder cottages around the plaza) so Havenbrook reads as a town.
local function cottage(pos: Vector3, rot: number)
	part({ Size = Vector3.new(16, 10, 14), Color = Color3.fromRGB(150, 130, 96), Material = M.WoodPlanks, CFrame = CFrame.new(pos + Vector3.new(0, 5, 0)) * CFrame.Angles(0, rot, 0) })
	part({ Size = Vector3.new(19, 6, 17), Color = Color3.fromRGB(120, 60, 45), Material = M.Slate, CFrame = CFrame.new(pos + Vector3.new(0, 12, 0)) * CFrame.Angles(0, rot, 0) })
end
cottage(Vector3.new(-52, 0, -42), 0.2)
cottage(Vector3.new(52, 0, -46), -0.2)
cottage(Vector3.new(-58, 0, 44), 0.1)
cottage(Vector3.new(56, 0, 40), -0.1)

-- Goblin warren totems (deep E, around the Chieftain) — a crude, ominous landmark.
do
	local base = ZONES.warren
	for i = 1, 6 do
		local a = i / 6 * math.pi * 2
		part({ Size = Vector3.new(2.5, 12, 2.5), Color = Color3.fromRGB(80, 70, 50), Material = M.Wood, CFrame = CFrame.new(base + Vector3.new(math.cos(a) * 34, 6, math.sin(a) * 34)) })
	end
end

-- ---------- 3) remove the old flat floor part (terrain replaces it) ----------
local oldGround = AR:FindFirstChild("Ground")
if oldGround then oldGround:Destroy() end

-- ---------- 4) relocate enemy-territory markers + ore nodes into their zones ----------
local function setTerritory(id: string, centre: Vector3, radius: number, population: number?)
	local terr = AR:FindFirstChild("Territories")
	if not terr then return end
	for _, m in ipairs(terr:GetChildren()) do
		if m:GetAttribute("TerritoryId") == id and m:IsA("BasePart") then
			m.Position = centre
			m:SetAttribute("Radius", radius)
			if population then m:SetAttribute("Population", population) end
		end
	end
end
setTerritory("goblin_camp", ZONES.meadow + Vector3.new(-40, 0, 40), 48, 5) -- near meadow (starter combat)
setTerritory("goblin_ruins", ZONES.meadow + Vector3.new(60, 0, -50), 44, 4) -- deeper meadow escalation
setTerritory("wolf_den", ZONES.forest, 52, 4) -- Whispering Woods
setTerritory("chieftain_arena", ZONES.warren, 8, 1) -- Goblin Warren boss

-- Iron Ore nodes -> Ironrock Hollow (spread in a small vein near the mine entrance).
local iron = AR:FindFirstChild("IronOre")
if iron then
	local spots = { Vector3.new(-14, 2, -6), Vector3.new(-4, 2, 4), Vector3.new(8, 2, -8), Vector3.new(16, 2, 6) }
	local i = 1
	for _, node in ipairs(iron:GetChildren()) do
		if node:IsA("BasePart") and spots[i] then
			node.Position = ZONES.hills + spots[i]
			i += 1
		end
	end
end

-- ---------- 5) lighting mood: bright grounded-medieval afternoon ----------
Lighting.ClockTime = 14.2
Lighting.Brightness = 2.6
Lighting.OutdoorAmbient = Color3.fromRGB(120, 120, 130)
local atmos = Lighting:FindFirstChildOfClass("Atmosphere")
if atmos then atmos.Density = 0.34; atmos.Haze = 1.4; atmos.Color = Color3.fromRGB(210, 214, 224) end

return ("Region I 'The Marchlands' built: terrain biomes + %d scenery parts; town, mine, ruins, warren landmarks; territories & ore relocated to zones. SAVE THE PLACE to persist."):format(#scenery:GetChildren())
