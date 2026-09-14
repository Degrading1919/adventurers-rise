# Adventurer's Rise — Technical Architecture Rules

**Status:** Agreed pre-implementation architecture doctrine.

The architecture should be deliberately modular, data-driven, server-authoritative, and easy for Codex/Astra to extend without rewriting systems.

## Source-of-Truth Split

### GitHub is authoritative for

- Luau source code
- configuration/data definitions
- balancing/config tables
- save-data schemas
- reusable system definitions
- implementation specifications
- documentation

### Roblox Studio is authoritative for

- terrain and map geometry
- placed world instances
- imported meshes
- animations
- VFX
- sounds
- physical plot layouts
- scene-heavy presentation content

Roblox Script Sync/native Studio tooling may bridge code between GitHub and Studio where useful.

## Core Architecture Principle

Repeating content should use:

> one reusable system + data describing each instance

Avoid bespoke logic for every enemy, item, recipe, resource, or station.

Examples of data-driven systems include:

- skills
- mastery trees
- enemies
- bosses
- items/equipment
- resource nodes
- recipes
- training stations
- production stations
- Ascensions
- shops

## Server Authority

Anything that changes progression, economy, combat outcomes, or permanent state is server-authoritative.

The server owns/validates:

- XP and levels
- Gold
- inventory quantities
- item rewards
- crafting outputs
- purchases/sales
- damage
- enemy rewards
- boss loot
- mastery points/selections
- Ascension
- station upgrades
- offline progression

The client primarily handles:

- input
- UI
- camera
- local presentation
- responsive animation/VFX feedback

Client-to-server remotes are treated as **requests**, never trusted outcome commands.

Bad conceptual remote:

> GivePlayerXP(5000)

Good conceptual remote:

> RequestStartTraining(stationId)

The server validates access, state, timing, and resulting rewards.

## Responsibility Boundaries

The implementation may organize these as services/modules differently, but responsibilities should remain separated.

### PlayerData

Owns persistent player state and schema/migrations.

### Skills

Owns XP, levels, unlock evaluation, and Mastery Point earning.

### Mastery

Owns branch selections, node effects, validation, and respecs.

### Combat

Owns targeting integration, attack validation, damage, health, attack timing, and combat-state rules.

### Enemies

Owns spawning, level rolls, aggression, reusable AI behavior, death/reward eligibility.

### Bosses

Builds on Enemy/Combat foundations and adds shared encounters, contribution, respawn, personal loot rolls, and signature mechanics.

### Items / Equipment

Owns item definitions, requirements, stats, equipment validation, set bonuses, and visual references.

### Inventory

Owns stackable resources, discrete equipment, and special loot state.

### Gathering

Owns persistent nodes, tool checks, action timing, XP, and yields.

### Crafting

Owns Smithing/Fletching/Arcana recipes, requirements, batch actions, consumption, production XP, and outputs.

### Economy

Owns Gold, shop prices, NPC selling/buying, and infrastructure costs.

### Plots

Owns plot assignment, saved station state, fixed sockets, and plot restoration.

### Training

Owns active combat-station training, station efficiency, and offline training calculations.

### Ascension

Owns rank requirements, validation, rewards/unlocks, and permanent rank progression.

### UI

Presents authoritative state but does not own permanent progression.

## Data-Driven Content

Central definitions should drive repeated content.

### Skill definitions

May include:

- stable ID
- display name
- XP curve/reference
- unlock table
- mastery reference

### Enemy definitions

May include:

- stable ID
- archetype
- level range
- base stats/scaling
- aggression behavior
- attack style
- XP/Gold rewards
- drop table reference
- presentation/model references

### Item definitions

May include:

- stable ID
- display name
- equipment slot/type
- tier
- requirements
- combat/tool stats
- set membership
- base visual asset
- material/texture/effect variant

### Recipe definitions

May include:

- stable ID
- production skill
- required level
- inputs
- output
- action duration
- station type

### Station definitions

May include:

- station type
- tier
- Gold/material cost
- training or speed multiplier
- offline multiplier where relevant
- visual variant

Avoid special-case conditionals such as `if item == "IronSword"` unless a genuinely unique behavior requires them.

## Stable Internal IDs

Player-facing names may change without breaking saves.

Use stable internal identifiers such as:

- `skill_mining`
- `enemy_goblin`
- `boss_goblin_chieftain`
- `resource_iron_ore`
- `weapon_sword_tier_02`
- `station_melee_03`

Do not use display names as persistent identifiers.

## Save Data

Player data is versioned from the beginning.

Conceptual persistent state includes:

- schema version
- Gold
- skill XP
- mastery selections
- Ascension rank/progress flags
- inventory
- equipped items
- plot/station progression
- boss/progression flags only where needed
- last valid logout/session timestamp
- relevant settings

Prefer derived state over duplicated state where practical. For example, level should normally be derivable from XP.

### Migration Rule

Every future schema change that affects existing data must have an explicit migration path.

Persistence is a core feature and should not be treated as temporary prototype code.

## Offline Progression

Do not simulate every missed training tick.

Store the relevant timestamp and player/station state, then on validated return:

> elapsed time → clamp to offline cap → calculate aggregate gain → award once

All offline calculations are server-side.

## Networking Rule

The client never determines how much XP, Gold, loot, damage, or crafting output it deserves.

Server endpoints validate:

- player ownership/access
- target validity
- timing/cooldowns
- inventory requirements
- station/node state
- combat state
- reward calculations

## Combat Architecture

Automatic targeting is one reusable system consumed by all combat styles.

Target evaluation may consider:

- valid/alive state
- range
- player facing
- camera intent/alignment
- line of sight where appropriate

Melee, Ranged, and Magic consume the selected target rather than implementing separate aiming systems.

Hold Attack feeds one reusable attack-state framework:

> input active → cooldown ready → server validation → attack resolution

Weapon data controls attack speed, range, damage profile, projectile/effect behavior, and later build interactions.

## Enemy Scaling

A standard spawn is:

> archetype + rolled level within predefined range

Example:

> Goblin, range 3–8 → spawned at Level 6

Stats/rewards derive from reusable archetype/scaling data rather than authoring separate objects/scripts per level.

Enemies never scale directly to the player's level.

Bosses may use fixed levels or narrow ranges where predictability improves balancing/presentation.

## Item Visual Reuse

Item definition and visual presentation should support multiple equipment tiers sharing one base model.

A base mesh can vary through:

- texture/paint
- material
- color
- emissive treatment
- glow/shimmer
- attachments
- VFX set

Unique boss/prestige items may use unique assets.

## Plot Architecture

Plots use fixed sockets:

- MeleeSocket
- DefenseSocket
- RangedSocket
- MagicSocket
- ForgeSocket
- FletchingSocket
- ArcanaSocket

Saved progression determines which station and tier occupies each socket.

Every server plot uses the same mechanical layout.

## Mobile-First Rule

Every interaction feature is evaluated on PC **and mobile** during implementation, not retrofitted at the end.

This especially applies to:

- targeting
- Attack
- station interactions
- gathering
- crafting quantities
- inventory/equipment
- skill/mastery navigation
- Ascension UI
- boss encounters

## Performance Rules

The game must expect repeated lightweight world objects and multiple players simultaneously using them.

Prefer:

- event/timer-driven logic over unnecessary per-frame loops
- centralized/reusable behavior over scripts inside every world instance
- simple enemy AI
- controlled particle counts
- reusable/poolable effects where valuable
- clear server/client workload separation

High-tier presentation should remain readable and performant on ordinary Roblox/mobile hardware.

## Logging and Debugging

Important server-side progression systems should be debuggable enough to answer questions such as:

- why did XP not award?
- why was boss loot eligibility rejected?
- how was an offline gain calculated?
- why is a recipe unavailable?
- what validated or rejected a purchase?

No enterprise telemetry system is required for the vertical slice, but critical calculations should not be opaque.

## Codex and Astra Responsibilities

### Codex is favored for repository-first engineering

- architecture and reusable modules
- config/data definitions
- save schemas and migrations
- validation
- generic systems
- tests/checks where practical
- refactoring
- technical documentation

### Astra + Roblox Studio MCP is favored for Studio-context work

- instance hierarchy
- map and scene setup
- plot/station placement
- resource-node placement
- enemy/boss placement
- UI assembly
- animation/VFX hookups
- Studio playtesting/iteration

There will be overlap, but two agents should not independently implement the same subsystem.

GitHub is the coordination point.

## Git Workflow

`main` represents accepted source of truth.

Implementation should use narrow feature branches/PRs rather than broad direct-to-main code changes, for example:

- `feature/player-data`
- `feature/skill-system`
- `feature/training-stations`

Implementation tasks should have:

- narrow scope
- explicit acceptance criteria
- tests/checks where practical
- no unrelated cleanup
- review before merge

## Locked Technical Doctrine

> **Server-authoritative progression. Data-driven content. Stable IDs. Versioned saves. Reusable systems. Fixed plot sockets. Mobile-first interaction. GitHub-managed code/configuration. Studio-managed world presentation.**