# PLAN — phased roadmap + NEXT ACTION

Each phase = research → implement → Studio-integrate → playtest → INDEPENDENT critic → fix, before advancing.

- **Phase 0 — Control + baseline.** [IN PROGRESS] mission/ artifacts + rubric; branch `feature/open-world-rpg` off living-world work; baseline verified (21 suites green). Final mission PR supersedes PR #33.
- **Phase 1 — The World.** Rebuild the flat plane into a ~1000–1500 stud **terrained Region I**: central safe **town hub** (relocate stations/forge/shop/spawn) + biome sub-areas (forest edge, farmland, rocky hills, old mine, ruins/watchtower) with real terrain materials, elevation, paths, landmarks/POIs. Zone detection (part volumes) + region-entry banner + ambient audio + lighting mood. Enemy **territories** + **resources** placed geographically on a difficulty gradient. Goal: "going somewhere / inhabited world."
- **Phase 2 — Enemy ecology + combat feel.** Region I families (Bandit, Hobgoblin + Goblin/Wolf), level ranges rising with distance; 2nd boss (Bandit Warlord) on the boss framework; loot tables (enemies drop resources/gear); combat feedback (hit flash/sound, attack swing, death fx).
- **Phase 3 — Equipment ladder + armor + production depth.** Head/Body/Legs slots (data extension); copper→iron→steel weapon+armor tiers; 2nd resource (ore+gems or wood) + gathering; expanded Smithing recipes (armor + tier-2); loot/shop integration. Creates gear↔exploration loop + real Defense progression.
- **Phase 4 — Progression breadth + discovery.** More Mastery nodes; next Ascension rank(s) (Adept→Vanguard, 4-category reqs); discoverable POI objectives/tasks + first-visit rewards; map/compass UI; retention hooks. Stretch: Woodcutting+Ranged (2nd combat pillar).
- **Phase 5 — Presentation/perf/mobile.** Audio pass, VFX, UI for new systems, balance/pacing, StreamingEnabled if warranted, mobile validation.
- **Phase 6+ — Region II extension + critic-driven iteration** until the DoD rubric is genuinely met.

---

## CURRENT PHASE: Phase 1 (The World) — repo prep done; Studio integration BLOCKED (place closed)

## NEXT ACTION (when the Studio place is reopened)
1. Reconnect the Studio MCP (place id 136843447225408); run `studio/RegionOneBuilder.luau` via `execute_luau` (Edit mode) to build Region I "The Marchlands". Screenshot; tune terrain/props/positions live.
2. Sync branch `feature/open-world-rpg` code into the place (raw-fetch script Sources; add new `Shared/RegionIds` + `Shared/RegionDefinitions` ModuleScripts under ReplicatedStorage.Shared).
3. Implement the client region-entry **banner** + per-zone **ambient audio** (client reads `RegionDefinitions.ZoneAt(playerX, playerZ)` each ~0.3s; swap ambient Sound + show banner on zone change). Add a placeholder ambient Sound per Ambient key.
4. Playtest: walk the world (town → meadow goblins → forest wolves → hills ore → warren chieftain); verify enemies/resources sit in their zones on a difficulty gradient, banners/audio fire, existing loop still works, no console errors; desktop + mobile viewport. Regression-check the full loop.
5. Independent evaluator subagent grades Phase 1 vs the DoD rubric using screenshots + runtime state; fix findings; then advance to Phase 2.

Repo prep already landed: RegionIds/RegionDefinitions (+test, 22 suites green) and the run-ready scene-builder.
