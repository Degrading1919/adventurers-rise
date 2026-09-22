# PROGRESS — checkpoints, game state, defects, Studio state

## Current game state (as inherited at mission start)
- **World:** flat 320×320 single grass Part, no terrain/elevation/landmarks/audio; central hub (spawn, Melee/Defense training stations, Forge, Shop) + 4 Iron Ore nodes (south) + living-world enemy **territories** (goblin_camp east, goblin_ruins SW, wolf_den NW, chieftain_arena N).
- **Skills built:** Melee, Defense, Mining, Smithing (cap 60; curve `25*level` cumulative). Ranged/Magic/Woodcutting/Fletching/Arcana = specified-but-unbuilt.
- **Combat:** hold-attack, server-authoritative, weapon-driven; conditional aggression + provocation; living-world enemies (Goblin, Wolf, Goblin Chieftain boss) roam/aggro/chase/leash/return.
- **Items/equipment:** Weapon + Tool slots only (no armor). Starter/Upgraded Sword, Basic/Upgraded Pickaxe, Iron Ore/Bar, Chieftain Fang (rare).
- **Production:** Forge (Iron Ore→Iron Bar→Upgraded Sword). Shop buy/sell (proximity-gated). Training stations (2 tiers). Mastery trees (per-skill, points at L5/10/15/20/30/40/50/60). Ascension: Adventurer→Adept only. Offline training (Melee/Defense focus). Onboarding (guided objective chain through the whole loop).
- **Client:** mobile-polished HUD (contextual action bar, panels, toasts, target/boss bars, map-less).

## Test/playtest status
- **Repo:** 21 suites green at mission start (Phase 0 baseline verified).
- **Studio playtest:** existing loop verified end-to-end in prior sessions (spawn→train→earn→mine→smelt→gear→chieftain→Ascend→offline). Living-world enemies playtested (territories, roam/aggro/chase/leash/return, respawn-in-region, conditional aggression).

## Known defects / limitations (inherited)
- Sword-step onboarding hint understates gates (Smith Lv5 / 500g) — nonblocking pacing (from earlier acceptance).
- Ascension "Adept" needs Melee Lv8 vs ~Lv3 from guided steps — pacing spike.
- Enemy movement is a gliding mesh + bob/facing (no leg animation) — placeholder pending rigs.
- Wolf is a box placeholder — needs art.
- No audio anywhere. No armor. Single resource/production chain. One region. Flat featureless world.

## Studio scene state (Studio-owned; NOT in Git — the place MUST BE SAVED to persist)
- Place id 136843447225408; studio id 1e765b7b-6dd9-439b-bfcc-66b1688e4943; dev DataStore `AdventurersRise_PlayerData_Development` (separate from live).
- **Region I "The Marchlands" is built** (via `studio/RegionOneBuilder.luau`): terrain biomes on a flat walkable surface (~940×940, surface y≈2), scenic edge hills + NW river, `Workspace.AR_World.Scenery` folder (~144 tagged `AR_Scenery` placeholder props: trees/rocks/cottages/mine-entrance/ruined-tower/warren-totems), lighting mood set. Old flat `Ground` part removed.
- `Workspace.AR_World.Territories` markers relocated to zones (y=2): goblin_camp (160,25) pop5, goblin_ruins (255,-60) pop4, wolf_den (0,255) pop4, chieftain_arena (330,10) pop1. Iron Ore nodes → Ironrock Hollow (0,-270). AR_Spawn raised to y=2.
- **Place code synced to `feature/open-world-rpg`**: new ModuleScripts `ReplicatedStorage.Shared.RegionIds` + `RegionDefinitions`; updated `Client.Controller` + `Client.Interface`.
- To re-run/rebuild the world: paste `studio/RegionOneBuilder.luau` body into the MCP execute_luau (Edit). To re-sync code: raw-fetch from the branch, set script.Source (HttpEnabled on).

## BLOCKER (resolved)
- Studio place was closed; reopened and connected. Region I world built + validated in Play.

## Checkpoint log
- **[Phase 0]** Mission control system created (`mission/` artifacts + DoD rubric). Branch `feature/open-world-rpg` cut off `feature/living-world-enemies`. Baseline: 21 suites green.
- **[Phase 1 — repo prep]** Added `Shared/RegionIds` + `Shared/RegionDefinitions` (Region I + 6 zones) with a pure `ZoneAt(x,z)` classifier + spec (6 checks). Authored `studio/RegionOneBuilder.luau`.
- **[Phase 1 — WORLD BUILT + VALIDATED]** Built Region I; added region banner + objective beacon; zoned populations; 22 suites green. Independent evaluator graded it: criteria 2 (distinct places) & 3 (gradient) at 2/5 — gradient was cosmetic, world flat, scenery non-colliding, empty "hard" zones. Verdict: fix before Phase 2.
- **[Phase 1 — FIX CYCLE (evaluator)]** (1) **Real gradient:** `Enemies.Create` takes an optional level band clamped into the archetype range; territory markers carry `LevelMin/Max` (World reads + reuses on respawn). Verified live: wolves Lv2-4, near goblins Lv3-4, deep goblins Lv6-8, Chieftain Lv10 — distance = difficulty. New Enemies test. (2) **Honest zones:** blurbs/levels no longer promise absent enemies (Ironrock=mining, Ashen Ruins=foreboding-empty). (3) **World v2:** roads radiate town→each zone; central **keep tower** (relocated to SW off the spawn) as region-wide sightline anchor; tall rock-spire landmarks; denser props; **solid (colliding) scenery**. (4) **Banner** dark backdrop + stronger strokes. (5) **Fresh Lv1-spawn playtest:** fresh player spawns in town, onboarding + objective **beacon** correctly guide to combat across the bigger world (beacon points to the Melee station / goblins). **22 suites green, no regression, console clean.** Criterion 3 now ~4 (real gradient); criterion 2 much improved (landmarks/paths/verticality/biomes) — residual: play-SURFACE is still flat (vertical relief is scenery/hills/tower, not terrain elevation) — deferred to a terrain-elevation pass. **NEXT:** Phase 2 (enemy ecology: Bandit in Ashen Ruins, Hobgoblin in Ironrock, 2nd boss Bandit Warlord, loot tables, combat hit/impact feedback); a full evaluator re-assesses world+ecology at Phase-2 end.
