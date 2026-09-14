# Adventurer's Rise — Vertical Slice Definition

**Status:** Agreed first implementation target.

The vertical slice exists to prove the complete end-to-end progression architecture before expanding toward V1.

## Vertical Slice Goal

A new player should be able to:

> spawn → choose a starter weapon → train → fight → earn Gold → gather → craft or buy an upgrade → fight a shared boss → Ascend → leave → return and receive offline training gains

If this loop works cleanly, the project has proven most of the architecture the full game depends on.

## Included Systems

### Player Progression

Implement:

- Melee
- Defense
- Mining
- Smithing
- skill XP and levels
- mastery-system framework
- populated mastery content for Melee, Defense, Mining, and Smithing only
- Adventurer → Adept only
- persistent save/load

Ranged, Magic, Woodcutting, Fletching, and Arcana are not part of the functional slice, but the architecture must support adding them without redesigning the system.

## Combat

Implement:

- Sword combat only
- mostly automatic targeting
- optional target preference/override if needed for usability
- Hold Attack
- server-authoritative attack validation and damage
- conditional enemy aggression
- Defense XP from meaningful combat
- death/respawn with no item, resource, or Gold loss

The implementation must be structured so Ranged and Magic can later consume the same targeting/attack foundations.

## Player Plot

Implement:

- shared-server plot claiming/assignment
- fixed plot sockets
- Melee training station
- Defense training station
- reusable station-tier framework
- at least one meaningful upgrade step
- saved station state
- offline training calculation framework

The full seven-station end-state does not need to be populated in the slice.

## Gathering

Implement one Mining resource family with:

- persistent/non-depleting node behavior
- Mining XP
- continuous gathering interaction
- skill requirement
- tool requirement/efficiency
- one pickaxe progression step
- server-authoritative rewards

The framework must be reusable for later ores and Woodcutting nodes.

## Production

Implement a basic shared Forge in the hub.

Required test chain:

> Ore → Bar → Sword

Implement:

- Smithing XP
- recipe definitions
- level/material validation
- batch crafting
- material consumption
- item output
- reusable station interaction pattern

## Economy

Implement:

- Gold Coins
- Gold rewards from standard enemies
- basic NPC shop framework
- buying at least one useful item/material
- selling resources/items to an NPC
- pricing validation sufficient to avoid an obvious buy-inputs → craft → resell infinite-profit loop

Robux monetization is not part of the vertical slice.

## Inventory and Equipment

Implement:

- stackable resource inventory
- discrete equipment inventory
- weapon equipping
- starter sword
- at least one upgraded sword
- equipment requirements/stat effects sufficient to demonstrate a real combat improvement

The inventory model must remain compatible with later special/rare boss loot.

## Standard Enemy

Implement one standard enemy archetype, preferably **Goblin**.

The Goblin must use the reusable enemy-definition framework and demonstrate:

- predefined level range
- random level roll within that range
- derived stats/rewards
- conditional aggression
- reusable combat behavior
- Gold/XP/drop rewards

Do not author separate scripts/objects for individual Goblin levels.

## Boss

Implement **Goblin Chieftain** as the first shared-server boss.

Required behavior:

- shared encounter
- short respawn
- meaningful participation tracking
- independent personal RNG loot roll for every eligible participant
- at least one common drop
- at least one rare drop
- contribution/damage information sufficient for debugging and later UI

The boss should use the common combat/enemy foundations where possible rather than becoming a bespoke isolated system.

## Ascension

Implement Adventurer → Adept.

The Adept requirement must demonstrate all four requirement categories:

1. Melee/offensive combat threshold
2. Defense threshold
3. small overall-skilling requirement using slice skills
4. Goblin Chieftain defeat

Requirements remain data-driven.

Ascending:

- permanently saves Adept rank
- does not reset any skill
- provides a visible rank change/feedback

Exact numeric thresholds may be tuned during slice playtesting.

## UI Required for the Slice

Only implement the minimum surfaces needed to operate and evaluate the loop:

- main HUD
- current onboarding objective
- skill/XP view
- mastery view for implemented slice skills
- inventory/equipment UI
- Forge/crafting UI
- basic shop/selling UI
- Ascension requirement UI
- boss health/loot presentation
- offline-return summary

UI must be usable on PC and mobile.

## Onboarding Required for the Slice

The slice should provide a shortened version of the agreed onboarding flow:

1. Spawn at plot.
2. Choose starter weapon; Sword is the only fully implemented combat style in the slice, so non-Sword choices may remain disabled/clearly marked unavailable until their systems exist.
3. Train Melee.
4. Train Defense.
5. Fight Goblins.
6. Earn Gold.
7. Mine ore.
8. Smelt bars.
9. Craft or purchase an upgraded sword.
10. Defeat Goblin Chieftain.
11. Ascend to Adept.
12. Leave/rejoin and validate persistence/offline training.

The slice should not pretend unimplemented Ranged/Magic content exists.

## Explicitly Excluded From the Vertical Slice

Do not implement merely because these systems are planned for V1:

- functional Ranged combat
- functional Magic combat
- Woodcutting
- Fletching
- Arcana
- later Ascensions
- Regions II or III
- additional standard enemy families
- additional bosses
- set bonuses
- full equipment tier ladder
- personal production stations
- all nine populated mastery trees
- leaderboards
- PvP
- tournaments
- trading
- advanced plot presentation
- finalized VFX/art polish
- detailed monetization

## Acceptance Criteria

Do not expand toward full V1 until the vertical slice satisfies all of the following:

1. A fresh player can complete the slice without developer intervention.
2. Permanent progression survives leaving and rejoining.
3. Offline training awards correctly and respects its configured cap/rules.
4. The client cannot directly grant itself XP, Gold, inventory items, boss loot, or damage outcomes.
5. Goblin content can be changed through definitions without rewriting the generic combat/enemy framework.
6. A new recipe can be added through data/configuration rather than a recipe-specific code path.
7. Training-station tiers are data-driven.
8. The primary loop is usable on mobile as well as PC.
9. Multiple players can fight the Goblin Chieftain and each eligible player receives an independent valid loot roll.
10. Adept Ascension permanently saves and does not reset skill progression.
11. The player can mine ore, smelt bars, craft an upgraded sword, equip it, and observe the expected combat improvement.
12. NPC buying/selling does not expose an obvious guaranteed infinite-profit crafting loop.
13. Death preserves Gold, items, materials, and permanent progress.
14. No Robux interaction is required to complete or enjoy the slice.
15. The architecture can accept additional skills, enemies, recipes, station tiers, items, and Ascensions primarily as content/data extensions rather than rewrites.

If these criteria fail, fix the architecture before adding breadth.

## Recommended Implementation Dependency Order

Work roughly in this order:

1. repository/project foundation
2. stable IDs and shared data/config patterns
3. versioned PlayerData/save framework
4. skill/XP framework
5. inventory/item/equipment framework
6. Gold/economy framework
7. plot assignment and training-station framework
8. combat/targeting framework
9. standard enemy framework + Goblin
10. Mining/resource-node framework
11. Smithing/recipe/crafting framework
12. Goblin Chieftain boss framework
13. Adept Ascension framework
14. minimum UI/onboarding integration
15. offline progression and persistence hardening
16. PC/mobile end-to-end acceptance testing

These steps may be grouped into appropriately narrow PRs, but dependency direction should remain clear.

## Implementation Handoff Rule

Codex should receive narrow repository-first tasks with explicit acceptance criteria rather than a single request to "build Adventurer's Rise V1."

Astra + Roblox Studio MCP should handle Studio-context assembly and iteration while using the same repository source of truth.

The vertical slice is complete when the loop is technically sound, understandable, persistent, mobile-usable, and extensible—not when it has launch-quality content volume or final presentation polish.