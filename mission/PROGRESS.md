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

## Studio scene state (Studio-owned; NOT in Git — the place must be saved to persist)
- Place id 136843447225408; studio id 1e765b7b-6dd9-439b-bfcc-66b1688e4943; dev DataStore `AdventurersRise_PlayerData_Development` (separate from live).
- `Workspace.AR_World.Territories` holds 4 `AR_EnemyTerritory` markers (living-world enemies). Old `AR_EnemySpawn` markers removed. Git-owned script Sources were synced into the place at the living-world commit.
- **The place is currently synced to `feature/living-world-enemies` code.** Re-sync to `feature/open-world-rpg` when world changes land (fetch raw from the branch, set script.Source; HttpEnabled on).

## Checkpoint log
- **[Phase 0]** Mission control system created (`mission/` artifacts + DoD rubric). Branch `feature/open-world-rpg` cut off `feature/living-world-enemies`. Baseline: 21 suites green. NEXT: begin Phase 1 world build.
