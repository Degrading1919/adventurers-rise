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

## CURRENT PHASE: Phases 1–3 DONE + evaluator-cleared. In Phase 4 — 4a (Vanguard) + 4b-1 (discovery) DONE + verified; next 4b-2 (region map), then 4c (more Mastery), then Phase-4 evaluator.
Phase 3 close-out: independent evaluator re-graded after the legibility fix cycle — criterion 5 = 4, 8 = 4, 9 = 4 (all ≥4). **VERDICT: advance to Phase 4.** Tracked debt to Phase 5 (non-blocking): armor BODY visual (EquipmentVisuals seam ready), a visceral harder-content signal, done: de-dup 0.9 clamp (EnemyCombat now exports MaxIncomingDamageReduction).
Phase 3 approach (DONE for iron tier): Head/Body/Legs slots + an armor damage-reduction stat folded into the EXISTING EnemyCombat `IncomingDamageReduction` slot via the Composition defense-modifier provider (so EnemyCombat itself is unchanged — least-regression). Iron set (helm 0.04 / body 0.07 / legs 0.05 = 0.16) craftable from Iron Bars via Smithing (helm Lv4 / legs Lv6 / body Lv7). Gear panel + Forge are data-driven so armor appears/equips automatically (added ITEM_LABELS + SLOT_LABELS). EquipmentVisuals iterates only Weapon/Tool → armor has no character visual yet (clean seam). New Composition test proves 16% reduction through the real pipeline.

## NEXT ACTION — Phase 4 (progression breadth + discovery)
Sequence into verify-per-slice sub-slices (implement → test → Studio-verify → evaluator at phase end):
- **4a — Ascension → Vanguard + next-rank progress. ✅ DONE + Studio-verified** (Vanguard chains from Adept; gated on Melee 15 / Defense 12 / Mining 8 / Smithing 10 / BanditWarlordDefeated; read model + client generalized to the player's next rank).
- **4b-1 — First-visit discovery + rewards. ✅ DONE + Studio-verified** (server-authoritative zone discovery, per-zone Gold rewards, anti-spoof position resolver, read-model DiscoveredZoneIds, client auto-trigger + toast; live-confirmed +30 Meadow / +80 Warren).
- **4b-2 — Region map (NEXT):** a minimal top-down map panel using RegionDefinitions zone centres/radii + the read-model `Discovery.DiscoveredZoneIds` — show the zones (discovered vs unknown), the player's position, and the current objective/next-rank hint. Addresses the evaluator's recurring "no map" note (criteria 6 & 9). Client-only (reads existing read-model data); no new server surface needed.
- **4c — More Mastery nodes:** deepen per-skill trees so leveling keeps offering choices (criterion 4).
- Stretch: Woodcutting+Ranged as a 2nd combat/gathering pillar. Independent evaluator at Phase-4 end (grade criteria 4, 6, 9).

Live-playtest tooling note (unchanged): drive checks via `ReplicatedStorage.Remotes.Request:InvokeServer(RequestIds.*, payload)` (Client datamodel) + in-engine `require` (Server); MCP `_G` is sandboxed from the running server, so full hands-on high-level loops need a pre-leveled dev-store player.

Note on live playtest tooling: the MCP `execute_luau` runs in a Luau state sandboxed from the running server's `_G`, so the Bootstrap `_G.__AdventurersRiseServer` debug seam is NOT reachable to seed PlayerData. Drive live checks through the real client RemoteFunction `ReplicatedStorage.Remotes.Request:InvokeServer(RequestIds.*, payload)` (Client datamodel) and in-engine `require` of synced modules (Server datamodel). Full hands-on loops need a dev-store player already leveled/stocked.

Remember: **SAVE THE PLACE** (Studio-owned world not in Git). Fresh-context bootstrap in MISSION.md.
