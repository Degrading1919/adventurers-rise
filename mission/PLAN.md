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

## CURRENT PHASE: Phase 1 & 2 DONE. Phase 3 iron-armor slice DONE + Studio-verified (22 suites green). Continuing Phase 3 with a 2nd resource + gear tier.
Phase 3 approach (DONE for iron tier): Head/Body/Legs slots + an armor damage-reduction stat folded into the EXISTING EnemyCombat `IncomingDamageReduction` slot via the Composition defense-modifier provider (so EnemyCombat itself is unchanged — least-regression). Iron set (helm 0.04 / body 0.07 / legs 0.05 = 0.16) craftable from Iron Bars via Smithing (helm Lv4 / legs Lv6 / body Lv7). Gear panel + Forge are data-driven so armor appears/equips automatically (added ITEM_LABELS + SLOT_LABELS). EquipmentVisuals iterates only Weapon/Tool → armor has no character visual yet (clean seam). New Composition test proves 16% reduction through the real pipeline.

## NEXT ACTION — Phase 3 continued (iron armor loop DONE + Studio-verified @ 4f3d7c7)
1. **2nd resource + gear tier:** add a second gatherable resource (2nd ore, e.g. Coal, or Wood) with a gathering node + geography on the difficulty gradient, then a Steel weapon+armor tier (Iron + Coal → Steel Bar → steel sword + steel Head/Body/Legs) so gear is a real ladder, not a single step. Data-driven via Gathering/Crafting/Item Definitions + the *Ids modules. Steel armor should out-protect iron (e.g. ~0.24 set) and gate a harder zone. Test + Studio playtest (sync + StateGet recipe check + in-engine data check, same recipe as the iron slice).
2. **Shop integration:** optionally sell/buy armor via Economy/ShopCatalog so gear is obtainable by gold too (a fallback path for players who dislike grinding Smithing).
3. Independent evaluator at Phase-3 end: re-grade criterion 5 (weapons AND armor tiers that visibly ease/gate) + 8 (gather→produce chains). Consider surfacing an armor/defense readout in the read model so the benefit is legible in the Gear panel (Phase 5 polish candidate; would let a live player SEE the mitigation number).

Note on live playtest tooling: the MCP `execute_luau` runs in a Luau state sandboxed from the running server's `_G`, so the Bootstrap `_G.__AdventurersRiseServer` debug seam is NOT reachable to seed PlayerData. Drive live checks through the real client RemoteFunction `ReplicatedStorage.Remotes.Request:InvokeServer(RequestIds.*, payload)` (Client datamodel) and in-engine `require` of synced modules (Server datamodel). Full hands-on loops need a dev-store player already leveled/stocked.

Remember: **SAVE THE PLACE** (Studio-owned world not in Git). Fresh-context bootstrap in MISSION.md.
