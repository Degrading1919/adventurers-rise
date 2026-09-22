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

## CURRENT PHASE: Phase 1 & 2 DONE. Phase 3 DONE + Studio-verified — iron+steel gear ladder & 2nd resource (Coal) live (22 suites green). Next: Phase-3 evaluator, then Phase 4.
Phase 3 approach (DONE for iron tier): Head/Body/Legs slots + an armor damage-reduction stat folded into the EXISTING EnemyCombat `IncomingDamageReduction` slot via the Composition defense-modifier provider (so EnemyCombat itself is unchanged — least-regression). Iron set (helm 0.04 / body 0.07 / legs 0.05 = 0.16) craftable from Iron Bars via Smithing (helm Lv4 / legs Lv6 / body Lv7). Gear panel + Forge are data-driven so armor appears/equips automatically (added ITEM_LABELS + SLOT_LABELS). EquipmentVisuals iterates only Weapon/Tool → armor has no character visual yet (clean seam). New Composition test proves 16% reduction through the real pipeline.

## NEXT ACTION — Phase-3 close-out → Phase 4
Phase 3 core is DONE + Studio-verified: iron+steel weapon/armour ladder, 2nd resource (Coal), two-input smelting, generic multi-node mining. Remaining:
1. **Independent Phase-3 evaluator** (subagent that did NOT implement it): grade criterion 5 (weapons AND armour tiers that visibly ease/gate harder areas) + 8 (gather→produce chains) + 9 (visible progress / reasons to continue) against the code + the live evidence recorded in PROGRESS. Feed findings into a fix cycle before Phase 4. (Watch for: is the steel tier reachable in a reasonable session? does the player SEE armour's benefit? is coal's danger-gating fair at Mining Lv3?)
2. **(Optional, evaluator-dependent) legibility:** surface an armour/defense-reduction readout in the read model + Gear panel so the mitigation is visible (addresses "visibly eases"); consider a shop path for gear.
3. **Then Phase 4 — progression breadth + discovery:** more Mastery nodes; next Ascension rank (Adept→Vanguard, docs' 4-category reqs); discoverable POI objectives + first-visit rewards; map/compass UI. (Stretch: Woodcutting+Ranged 2nd combat pillar.)

Note on live playtest tooling: the MCP `execute_luau` runs in a Luau state sandboxed from the running server's `_G`, so the Bootstrap `_G.__AdventurersRiseServer` debug seam is NOT reachable to seed PlayerData. Drive live checks through the real client RemoteFunction `ReplicatedStorage.Remotes.Request:InvokeServer(RequestIds.*, payload)` (Client datamodel) and in-engine `require` of synced modules (Server datamodel). Full hands-on loops need a dev-store player already leveled/stocked.

Remember: **SAVE THE PLACE** (Studio-owned world not in Git). Fresh-context bootstrap in MISSION.md.
