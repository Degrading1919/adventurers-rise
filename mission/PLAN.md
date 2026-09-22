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

## CURRENT PHASE: Phase 1 DONE (evaluator fix cycle applied). Starting Phase 2.

## NEXT ACTION — Phase 2: enemy ecology + combat feel
1. **New archetypes (data):** add Bandit (Ashen Ruins) + Hobgoblin (Ironrock Hollow) to `Enemies/Definitions` + `Shared/EnemyIds` (higher bands than goblins); placeholder box/mesh silhouettes; client display names. Add their territories via the builder (with LevelMin/Max) so the two currently-combat-empty tier-3 zones become real threats. Test.
2. **2nd boss:** Bandit Warlord on the reusable boss framework (Bosses/Definitions), sited in the Ashen Ruins ruined tower; participation/personal-reward like the Chieftain. Test.
3. **Loot tables:** a pure, tested loot-roll module + per-archetype tables (enemies drop region materials/gold, bosses drop better); wire into the combat/reward path (server-authoritative). Test.
4. **Combat feel:** hit flash + hit SFX + attack swing + enemy death fx (client presentation on authoritative hits).
Each item: implement → Studio-integrate → playtest → fix. Full independent evaluator at Phase-2 end (re-grades world + ecology vs the rubric, incl. whether criterion 2 needs the deferred terrain-elevation pass).

Remember: **SAVE THE PLACE** (Studio-owned world not in Git). Fresh-context bootstrap in MISSION.md.
