# Adventurer's Rise — Decision Log

This log records the major design decisions made during the initial concept-definition session. It is not a substitute for `DESIGN_SOURCE_OF_TRUTH.md`; it exists to preserve why the current design differs from the original project brief.

**Session date:** 2026-09-13

---

## Product Direction

### Locked
- The project is a **Roblox lite-MMORPG built on simulator/tycoon progression logic**.
- It is not intended to become a traditional MMORPG.
- Repetitive tier patterns are acceptable and desirable when they create obvious progression.
- The visual setting begins as **classic medieval adventure** and escalates from **grounded fantasy → high fantasy**.
- Visual muscle/body transformations are out of scope; visible progression comes from armor, weapons, effects, titles, Ascension rank, and plot infrastructure.

---

## Character and Combat Identity

### Superseded from the original brief
- Permanent Knight/Mage/Archer classes were rejected.

### Locked
- One persistent character can develop every skill.
- Sword/Bow/Staff is an initial weapon choice, not a permanent class selection.
- Combat identities emerge from current weapon, combat skills, gear, and mastery choices.
- Combat skills are **Melee, Defense, Ranged, Magic**.
- Melee is one combined skill rather than separate Attack/Strength-style skills.

---

## Noncombat Skills and Interoperability

### Locked
- Launch noncombat skills are **Mining, Woodcutting, Smithing, Fletching, Arcana**.
- Arcana replaces the narrower working concept of Enchanting and compresses several magical-production roles into one skill.
- Skills must interoperate through outputs/materials; no combat path should have a fully isolated support pipeline.
- Players are not forced to personally level every supporting skill equally; buying inputs is a valid alternate route.

---

## Training and Gathering

### Locked
- Combat skills use personal training stations at player plots.
- Defense is trained at its station and also gains passive XP from meaningful combat.
- Defense combat XP scales with enemy difficulty/level rather than primarily with damage taken.
- Mining and Woodcutting use persistent simulator-style nodes rather than depleting rocks/trees.
- Gathering progression uses **skill level + tool tier**.
- Tool durability is not part of V1.

---

## Crafting and Production

### Locked
- Production access is fundamentally gated by **skill level + materials**.
- Better production stations improve speed/efficiency rather than unlocking recipes.
- Crafting should generally include one meaningful intermediate step, e.g. `Ore → Bar → Sword`.
- Crafting is one equipment-acquisition route, not the mandatory route.
- The hub starts with basic shared Smithing/Fletching/Arcana stations.
- Players can later establish personal production stations at their plots.
- Personal crafting infrastructure is a later progression goal rather than an immediate starting feature.

---

## Inventory

### Locked
- Use a simulator-style inventory with large material stacks and minimal backpack/bank friction.
- A traditional limited inventory/banking loop is not required for V1.

---

## Equipment

### Locked
- Early gear progression is primarily linear.
- Mid/mid-late game introduces curated set bonuses and meaningful equipment combinations.
- Bosses provide curated alternatives and unique weapons rather than randomized affix loot.
- Normal equipment tiers aggressively reuse the same models with different textures/materials/paint/glow/shimmer/effects.
- Unique models are reserved mainly for prestige/boss-unique items.

### Working, not fully locked
- Minimal slot structure currently assumes Weapon, Head, Body, Legs.

---

## Combat Controls

### Locked
- Mostly automatic targeting.
- Hold Attack rather than click/tap spam.
- Assisted Ranged/Magic targeting/projectiles.
- No precision third-person aiming requirement.
- Optional manual target selection can supplement automatic targeting.
- Enemy aggression is conditional; enemies stop auto-aggressing players who substantially outgrow them.
- Death causes no permanent/resource/currency loss; the player simply loses the encounter and respawns.

---

## Bosses

### Locked
- Shared-server bosses rather than private instances.
- Every eligible participant receives an independent RNG loot roll.
- Bosses are always available/short-respawn rather than scheduled-only events.
- V1 target is 6 bosses, two per region.

---

## Ascension

### Superseded from the original brief
- Ascension is not a rebirth/reset system.
- The earlier 8–10 launch-tier target was reduced after the skill/crafting systems became deeper.

### Locked
- Skills never reset on Ascension.
- Launch has 6 Ascensions above the starting Adventurer state.
- Rank ladder:
  - Adventurer
  - Adept
  - Vanguard
  - Champion
  - Runebound
  - Paragon
  - Ascendant
- Ascension evaluates overall character readiness through:
  - one combat specialization threshold,
  - Defense,
  - overall skilling progress,
  - boss progression.
- Players only need enough overall skilling progress to retain freedom to specialize; equal levels in every production/gathering skill are not required.
- Gold payment is not part of the core Ascension requirement.

### Working pacing targets
- Ascension I: 15–25 minutes cumulative active time.
- Ascension II: 45–75 minutes.
- Ascension III: 2–3.5 hours.
- Ascension IV: 5–7 hours.
- Ascension V: 10–15 hours.
- Ascension VI: 20–30 hours.
- Desired first-session result: roughly Ascension II in 1–2 hours with Ascension III visibly within reach.

---

## World

### Locked
- Central town/hub plus 3 compact progression regions.
- Regions are soft-gated; players can enter high-level areas early and be overwhelmed.
- Enemy archetypes roll random levels within predefined ranges.
- Enemies do not scale to the player.
- V1 target: 12 standard enemy archetypes.

### Working launch content
- Region I: The Borderlands
  - Wolves, Bandits, Goblins, Hobgoblins
  - Goblin Chieftain, Bandit Warlord
- Region II: The Elderwood
  - Dire Wolves, Orc Raiders, Forest Trolls, Lesser Elementals
  - Troll King, Runic Guardian
- Region III: The Shattered Reach
  - Armored Orc Champions, Arcane Constructs, Corrupted Knights, Greater Elementals
  - Fallen Champion, Arcane Colossus

Names can change without reopening the structural decisions.

---

## Player Plots

### Locked
- Player plots are visible in the shared server.
- No freeform building system at V1.
- Starting plot has Melee, Defense, Ranged, and Magic training stations.
- Combat stations are upgradeable and visually improve.
- Later plot progression allows personal Smithing/Fletching/Arcana stations.
- Personal production stations coexist with basic shared hub stations; they do not replace the need for early shared infrastructure.

---

## Offline Progression

### Locked
- Use direct offline training through plot combat stations rather than only a stored bonus.
- Offline training should be capped and remain less valuable than strong active play.

### Still TBD
- exact cap,
- rate,
- whether all four combat stations train simultaneously,
- detailed station-upgrade interaction.

No V1 decision has been made to automate gathering, crafting, Gold generation, or boss loot while offline.

---

## Economy

### Locked
- One soft currency: **Gold Coins**.
- Players earn Gold through combat and by selling items/resources to NPCs.
- Gathering and production should both be viable money-making activities.
- NPC shop economics must prevent guaranteed buy → craft → resell profit loops.

### Monetization intent, not final design
- Optional Robux-supported convenience/acceleration around station upgrades, materials, and/or gear is of interest.
- Exact products and pricing are not designed.
- Core free progression must not be intentionally miserable or hard-walled to force spending.

---

## Social / Competitive Scope

### Locked for V1
- visible plots,
- visible titles/Ascension status,
- visible rare gear,
- shared bosses,
- leaderboards,
- boss contribution/damage display.

### Deferred
- PvP,
- tournaments.

---

## Mastery Trees

### Added to V1 after scope review
The only explicit disagreement with the initial V1 cut list was the removal of skill trees. Skill trees were restored as a core launch feature.

### Locked framework
- mastery tree for all 9 skills,
- 3 branches × 4 nodes,
- 8 skill-specific Mastery Points by level 60,
- points earned at levels 5, 10, 15, 20, 30, 40, 50, 60,
- normal unlocks never require mastery choices,
- first respec per skill free,
- later respecs use Gold,
- mostly passive specialization rather than new inputs/hotbars.

See `MASTERY_TREES.md` for branch definitions.

---

## V1 Deferred Feature List

Locked out of initial scope unless later reopened for a specific reason:

- PvP
- tournaments
- player trading
- guilds
- pets/companions
- substantial quest chains
- stealing/risk mechanics
- dungeons
- raids
- freeform housing
- permanent classes
- randomized gear affixes
- complex ability/hotbar combat
- crafting minigames
- per-basic-attack consumable arrows/runes
- durability
- multiple soft currencies
- traditional bank/backpack friction

---

## Current Project Status

- Name selected: **Adventurer's Rise**.
- GitHub repository created: `Degrading1919/adventurers-rise`.
- Core game loop and launch-system architecture are substantially defined.
- Implementation has **not begun**.
- Immediate remaining pre-implementation work centers on plot progression detail, onboarding/UI, exact numeric balance/content tables, and implementation-ready specifications.
