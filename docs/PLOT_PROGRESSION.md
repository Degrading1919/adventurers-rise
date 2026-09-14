# Adventurer's Rise — Player Plot Progression

**Status:** Agreed pre-implementation design.

Player plots are visible functional progression spaces in the shared server. They provide tycoon-flavored progression and social status without becoming a freeform housing game.

## Core Rules

- Every player receives a visible plot in the shared server.
- Plot layout is fixed rather than freeform.
- No land-expansion system is required for V1.
- Every plot is physically large enough from the start to support its full launch configuration.
- Empty reserved station spaces should communicate future progression.
- Plot progression should improve utility and visible prestige together.

## Starting Plot — Training Yard

Every new player starts with:

- Melee training station
- Defense training station
- Ranged training station
- Magic training station
- owner sign/banner or equivalent identity marker
- fixed reserved sockets for later production stations

The four combat stations begin usable at Tier 1.

## Combat Training Stations

Each combat station has **6 progression tiers**, broadly aligned with the six Ascensions.

Ascension establishes the ceiling for how far a station can be developed, but the player still needs to earn the upgrade rather than receiving it automatically.

Every station upgrade should provide:

1. improved active training XP rate,
2. improved offline training effectiveness,
3. stronger visual presentation/status.

Routine combat-station upgrades primarily cost **Gold Coins** plus the appropriate progression/Ascension access. They should not normally require crafting materials because all four combat stations are recurring infrastructure sinks and should not excessively compete with equipment crafting.

### Visual Progression

Station families should reuse geometry aggressively and escalate through materials, attachments, armor pieces, effects, and presentation.

Example Melee progression:

> Wooden Dummy → Reinforced Dummy → Armored Target → Runic Target → Enchanted Combat Construct → Ascendant Training Construct

The other combat stations should use equivalent six-tier visual logic.

Exact names, XP multipliers, prices, and art variants remain balance/content decisions.

## Personal Production Stations

The central hub always provides basic shared:

- Forge / Smithing station
- Fletching station
- Arcana station

Players initially rely on these communal stations.

Later, approximately around **Vanguard / early Champion progression**, players can begin becoming self-sufficient by constructing personal production stations on their own plots:

- personal Forge
- personal Fletching station
- personal Arcana station

This is a meaningful progression milestone, not starting infrastructure.

### Construction Requirements

Personal production-station construction may require a combination of:

- relevant production skill progress,
- Gold Coins,
- appropriate materials.

Exact requirements remain TBD.

### Production Station Upgrades

Each personal production station should have roughly **3 meaningful upgrade tiers** at V1.

Upgrades primarily improve:

- action speed,
- convenience/batch efficiency where appropriate,
- visual prestige.

Production-station tier does **not** unlock recipes. Recipe access remains governed by **skill level + materials**.

The shared hub stations remain functional forever as the basic baseline. Personal stations are faster and more convenient, not mandatory access gates.

## Plot End State

A highly developed launch plot contains:

- 4 highly upgraded combat training stations,
- personal Forge,
- personal Fletching station,
- personal Arcana station,
- owner identity/signage,
- increasingly prestigious environmental treatment.

Broad plot presentation may improve automatically as infrastructure develops, such as better fencing, stonework, banners, or runic details. These should not become a separate freeform decoration system in V1.

## Technical Layout Principle

Plots use fixed station sockets rather than arbitrary placement:

- MeleeSocket
- DefenseSocket
- RangedSocket
- MagicSocket
- ForgeSocket
- FletchingSocket
- ArcanaSocket

Player progression determines which station/tier occupies each socket.

## V1 Exclusions

- freeform building
- furniture/decor placement
- land expansion purchases
- complex housing systems
- plot layouts that differ mechanically between players

The plot exists to reinforce training, production self-sufficiency, Gold sinks, offline progression, and visible social status.