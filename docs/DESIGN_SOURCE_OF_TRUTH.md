# Adventurer's Rise — Design Source of Truth

**Status:** Pre-production / design

**Purpose:** This document records the current agreed game design. It supersedes earlier brainstorming where there is a conflict. Exact balance values remain subject to playtesting unless explicitly marked as a structural decision.

---

## 1. Product Identity

**Adventurer's Rise** is a Roblox **lite-MMORPG built on simulator and tycoon progression logic**.

The game is not intended to be a traditional MMORPG or a AAA-style RPG. It should be immediately understandable, repetitive in satisfying ways, visually rewarding, highly replayable, and capable of supporting deeper progression without requiring huge amounts of authored content.

The core fantasy is:

> Begin as an ordinary adventurer. Train skills. Gather resources. Craft or acquire better gear. Upgrade your personal plot. Fight stronger enemies and shared bosses. Ascend permanently. Progress from grounded medieval adventure into high fantasy.

### Design principles

- Simulator simplicity first; RPG character-building and identity layered on top.
- Repeating tier patterns are desirable when the next goal remains obvious and rewarding.
- Tycoon-flavored infrastructure progression is appropriate when it reinforces character growth.
- One persistent character; no permanent class lock.
- Progress should be visible through equipment, effects, titles, plot infrastructure, and Ascension status.
- Active play must remain worthwhile even with offline progression.
- Avoid systems that add traditional-MMO complexity without improving retention, progression, social appeal, or fantasy.
- Reusable systems and assets are preferred over large amounts of unique content.
- Monetization may accelerate or personalize progression later, but the free progression loop must remain enjoyable and viable.

---

## 2. Character Identity and Combat Paths

Players build **one persistent character**.

There are no permanent Knight, Archer, or Mage classes. Instead, the player's current equipment, combat skill investment, mastery choices, and gear build create their combat identity.

### Starter choice

At the beginning of the game, the player chooses one starter weapon:

- Sword
- Bow
- Staff

This determines the player's initial combat focus only. The other starter weapon types become cheaply obtainable early in the first session. Switching combat styles never requires creating a new character.

### Combat skills

The four launch combat skills are:

- **Melee** — melee weapon effectiveness and melee progression.
- **Defense** — universal survivability and armor progression.
- **Ranged** — bows and ranged weapon effectiveness.
- **Magic** — staffs/spells and magical weapon effectiveness.

Melee is intentionally one skill rather than separate Attack and Strength skills.

---

## 3. Noncombat Skills

The five launch noncombat skills are:

- **Mining**
- **Woodcutting**
- **Smithing**
- **Fletching**
- **Arcana**

Arcana is the game's compressed magical-production skill, covering the useful roles that a deeper MMORPG might split among enchanting, magical crafting, runecrafting, and magical refinement.

### Interoperability rule

The game uses a **skill web, not isolated class trees**.

No combat path should be vertically self-contained. Skill interoperability should come primarily from materials and outputs crossing skill boundaries rather than arbitrary prerequisites.

Examples:

- Mining supplies ore for Smithing and gems/crystals/essence for Arcana.
- Mining/Smithing supply metal ranged components such as arrowheads and fittings.
- Woodcutting supplies bow materials, staff bodies, handles, tool components, and other timber inputs.
- Smithing creates melee equipment, armor, gathering tools, metal ranged components, and metal magical components.
- Fletching creates bows, arrows/components, staff bodies, handles, and other wooden components.
- Arcana creates/refines magical equipment and later enhancements that can benefit Melee, Ranged, and Magic builds.

A player may buy materials rather than personally gathering every ingredient. The dependency is economic/systemic; the game should not force every player to personally level every supporting skill equally.

---

## 4. Skill Progression

### Launch skill cap

**60** for every launch skill.

### Pace philosophy

- Levels 1–10 should be very fast.
- Levels 10–25 remain quick and frequently rewarding.
- Levels 25–40 form the normal midgame.
- Levels 40–50 represent meaningful commitment.
- Levels 50–60 are long-term launch progression but should not resemble RuneScape's extreme high-level grind curve.
- A skill should generally expose a useful unlock or visible improvement every few levels rather than requiring a reward every single level.

Later progression should become slower through multiple simultaneous goals rather than a single miserable grind wall.

### How combat skills gain XP

- **Melee:** using melee attacks and the personal Melee training station.
- **Ranged:** using ranged attacks and the personal Ranged training station.
- **Magic:** using magic attacks and the personal Magic training station.
- **Defense:** direct training at the personal Defense station plus passive Defense XP from meaningful combat.

Defense combat XP scales with enemy difficulty/level relative to the player. Fighting trivial enemies should award little Defense XP; fighting appropriate or dangerous enemies should award more, within balance caps. Defense XP is not primarily based on damage taken, avoiding incentives to wear worse armor or deliberately tank hits.

---

## 5. Mastery Trees

Every launch skill has a lightweight mastery tree at V1.

The shared framework is:

- 3 branches per skill.
- 4 sequential nodes per branch.
- 12 possible nodes per skill.
- 8 total Mastery Points available by skill level 60.
- Mastery Points are skill-specific rather than universal.
- Masteries specialize how a skill performs; they do not gate the normal level-based unlock ladder.
- Trees are passive-focused and should not require extra combat hotbars or new control schemes at launch.
- Individual skill trees can be respecced. The first respec for each skill is free; later respecs cost Gold Coins.

See `docs/MASTERY_TREES.md` for the agreed branch framework.

---

## 6. Gathering

Mining and Woodcutting use **simulator-style persistent resource nodes** similar in spirit to modern RuneScape's non-depleting gathering model.

### Node rules

- Resource nodes do not normally deplete.
- The player can remain at a node and repeatedly gather resources and XP.
- Higher-tier resources are unlocked by skill level.
- Gathering efficiency depends on both skill progression and tool tier.
- Better tools increase gathering speed/efficiency.
- Tools do **not** use durability at launch.
- Underleveled players cannot gather a resource whose skill requirement they do not meet.
- Reaching a dangerous region early does not bypass resource requirements.

### Repeating tier structure

Each major progression tier can introduce:

- a new primary ore,
- a new primary timber,
- a new magical resource or occasional rare resource,
- stronger gathering tools,
- new production recipes,
- new equipment outputs.

Not every resource tier must require a new tool tier. Tool upgrades can be spaced to create larger efficiency jumps.

---

## 7. Production and Crafting

Production skills use **levels + materials** as their fundamental access gates.

Production station tier does not determine whether a recipe is unlocked. Better stations improve efficiency, especially action time.

### Crafting chains

Crafting should usually have **one meaningful intermediate step** before the finished item.

Canonical example:

> Iron Ore → Iron Bar → Iron Sword

Equivalent patterns apply to Fletching and Arcana.

Avoid long crafting chains that create complexity without payoff.

### Acquisition philosophy

Crafting is **one route** to equipment, not a mandatory route.

Players may obtain gear through:

- crafting,
- boss RNG drops,
- NPC shops,
- future systems if later added.

Crafted gear establishes the dependable baseline for each tier. Boss gear supplies desirable alternatives, rare uniques, and later build-defining pieces.

### Production stations

The central hub begins with basic communal:

- Forge / Smithing station
- Fletching station
- Arcana station

These allow all new players to participate in production immediately.

Later, players can earn the ability to construct personal production stations on their plots. Personal production stations are not immediately available. Their construction may require appropriate skill progress, Gold Coins, and/or materials. Once owned, upgrades primarily reduce production action time and increase convenience rather than unlocking recipes.

Exact construction requirements and upgrade curves are not yet balanced.

---

## 8. Inventory

The game uses a **simulator inventory**, not RuneScape-style limited backpack/banking friction.

### Inventory layers

- **Resources:** highly stackable materials such as ores, bars, logs, refined magical materials, and components.
- **Equipment:** discrete weapons, armor, tools, and other meaningful gear.
- **Special loot:** boss drops, rare materials, unique equipment, cosmetics, and similar prestige items.

A traditional bank system is not required for V1.

---

## 9. Equipment

### Equipment progression

Early equipment is intentionally linear and obvious.

> Higher normal tier = clearly better baseline gear.

Around mid to mid-late game, curated set bonuses, unique boss items, and equipment combinations begin to matter materially in combat.

The game does **not** use randomized Diablo-style affix rolls at launch.

### Gear acquisition roles

- **Crafting:** predictable baseline progression.
- **Bosses:** RNG alternatives, rare upgrades, curated sets, unique weapons, prestige drops.
- **NPC shops:** convenient access to materials and some gear.

### Visual asset rule

Normal equipment tiers should aggressively reuse models.

The same weapon or armor family can represent multiple tiers through:

- texture/paint changes,
- material changes,
- metallic finishes,
- emissive accents,
- glow/shimmer,
- attachments,
- particles/effects.

Genuinely unique models should be reserved primarily for boss uniques, prestige rewards, or items where visual uniqueness creates meaningful value.

### Working equipment slot structure

The current working slot model is:

- Weapon
- Head
- Body
- Legs

This slot list has not received the same explicit lock-in as the broader gear progression philosophy and may still be adjusted if implementation or visual design suggests a better minimal structure.

---

## 10. Combat Controls

Combat must be comfortable on Roblox, including mobile.

### Targeting and attacks

- Mostly automatic soft targeting.
- Target selection favors enemies in front of the player, within usable range, and reasonably aligned with camera/player intent.
- Manual target selection can exist as an optional override.
- **Hold Attack** continuously attacks at the equipped weapon's attack rate.
- No precision third-person aiming requirement.
- Ranged and Magic use assisted projectiles/effects so those styles are not inherently clunkier than Melee.
- Weapon design determines attack speed, range, and later build behavior.
- Movement remains player-controlled.

The player should be responsible for movement, positioning, target preference, avoiding boss attacks, gear/build choices, and later combat depth rather than pixel-perfect aim or click speed.

### Ability scope

V1 does not include a complex ability/hotbar system. Mastery trees are primarily passive. A future update may expand active combat depth after the core progression loop is proven.

---

## 11. Enemies and Death

### Standard enemies

Launch target: **12 standard enemy archetypes** across three regions.

Each archetype has a predefined level range. Individual spawns can roll levels within that range.

Enemies do **not** scale their level to the player. Returning to an early region as a strong character should make the player's progression obvious.

### Conditional aggression

Enemies use conditional aggression.

- Underpowered players entering a dangerous area are actively threatened.
- Players who substantially outgrow an enemy tier are no longer automatically harassed by those enemies unless they attack first.

Exact aggression thresholds remain a balance value.

### Death

Death has no item, material, or Gold loss at launch.

The punishment is losing the fight and being returned to the player's plot or an appropriate safe respawn point.

---

## 12. Shared Bosses

Launch target: **6 bosses**, two per progression region.

Bosses are:

- shared-server encounters,
- continuously farmable,
- on short respawn timers,
- repeatable progression/loot targets,
- sources of combat XP, Gold/material rewards, rare gear, curated sets, unique items, and prestige drops.

### Loot

Every eligible participant receives an **independent personal RNG loot roll**.

Loot is not physically contested among participants. Last hit does not determine ownership.

Players must meet a meaningful participation threshold to qualify for a full loot roll. The exact participation formula remains TBD.

Bosses should remain mechanically readable rather than becoming miniature raid encounters. Each can share a reusable boss framework while using distinct visuals, timings, effects, and a small number of signature mechanics.

---

## 13. Ascension

Ascension is a **permanent milestone/rank system**, not a rebirth/reset mechanic.

Skills never reset when the player Ascends.

### Launch ladder

| State | Rank |
|---|---|
| Starting state | Adventurer |
| Ascension I | Adept |
| Ascension II | Vanguard |
| Ascension III | Champion |
| Ascension IV | Runebound |
| Ascension V | Paragon |
| Ascension VI | Ascendant |

### Ascension purpose

Ascension acts as an overall character-readiness milestone above individual skill levels.

Each Ascension should combine:

1. **Combat specialization requirement** — one of Melee, Ranged, or Magic reaches the required threshold.
2. **Defense requirement** — lower universal survivability threshold.
3. **Overall skilling requirement** — enough combined gathering/production progression to demonstrate broad character development while preserving freedom to specialize.
4. **Boss milestone** — defeat the appropriate progression boss at least once.

Ascension should **not** require equal levels in every noncombat skill.

Ascension should **not** require a Gold payment simply to rank up.

### What Ascension provides

Ascension can unlock or raise the ceiling for:

- new equipment/material tiers,
- new progression content,
- stronger training infrastructure,
- visual title/status treatment,
- increasingly prestigious gear/effects,
- later systems as appropriate.

The world itself remains primarily soft-gated rather than being physically locked behind Ascension doors.

### Target pacing

These are **balance targets**, not final requirements:

| Ascension | Working combat target | Target cumulative active time |
|---|---:|---:|
| I — Adept | Offense ~8, Defense ~5 | 15–25 min |
| II — Vanguard | Offense ~15, Defense ~10 | 45–75 min |
| III — Champion | Offense ~25, Defense ~18 | 2–3.5 hr |
| IV — Runebound | Offense ~35, Defense ~27 | 5–7 hr |
| V — Paragon | Offense ~45, Defense ~36 | 10–15 hr |
| VI — Ascendant | Offense ~55, Defense ~45 | 20–30 hr |

Each Ascension also requires appropriate overall skilling and boss progression. Exact total-skilling thresholds are not yet defined.

The desired first-session experience is for a motivated new player to complete roughly **two meaningful Ascensions in the first 1–2 hours**, see Ascension III clearly within reach, and still have substantial launch progression remaining.

---

## 14. World Structure

The launch world is intentionally compact.

### Core layout

- Central medieval-adventure hub/town.
- Visible shared-server player plots.
- Three compact progression regions.
- Short travel times.
- Future-dangerous content should be visible before the player is ready for it.

### Soft gating

Players may physically enter stronger regions early.

They are prevented from skipping progression through:

- dangerous enemies,
- conditional aggression,
- resource skill requirements,
- tool efficiency,
- equipment requirements,
- boss difficulty.

A new player can walk into the final region, but should quickly discover that they are not prepared for it.

### Region I — The Borderlands

**Tone:** grounded medieval frontier around the town; forest, farmland, rocky hills, old mine, ruins/watchtowers.

**Enemy families:**

- Wolves
- Bandits
- Goblins
- Hobgoblins

**Bosses:**

1. Goblin Chieftain
2. Bandit Warlord

**Progression band:** Adventurer → Adept → Vanguard.

### Region II — The Elderwood

**Tone:** grounded fantasy visibly becoming magical; ancient forest, ruins, enchanted resources, magical creatures.

**Enemy families:**

- Dire Wolves
- Orc Raiders
- Forest Trolls
- Lesser Elementals

**Bosses:**

3. Troll King
4. Runic Guardian

**Progression band:** Vanguard → Champion → Runebound.

### Region III — The Shattered Reach

**Tone:** full launch high fantasy; magical catastrophe, crystals, arcane/corrupted ruins, unnatural vegetation, stronger effects.

**Enemy families:**

- Armored Orc Champions
- Arcane Constructs
- Corrupted Knights
- Greater Elementals

**Bosses:**

5. Fallen Champion
6. Arcane Colossus

**Progression band:** Runebound → Paragon → Ascendant.

Region/enemy/boss names are current working names and may change for presentation without changing the underlying structure.

---

## 15. Visual Direction

The visual progression is:

> **Grounded fantasy → high fantasy**

The foundation is **classic medieval adventure**, not anime-first, dark-fantasy-first, or realism-first.

### Early game

- timber and stone town,
- conventional mines/forests,
- restrained spell effects,
- ordinary-looking metals/timber,
- readable swords, bows, staffs, leather, chain, plate.

### Midgame

- enchanted woods,
- runic metals,
- crystals,
- magical ruins,
- stronger silhouettes,
- more ornate armor and weapons,
- clear magical accents.

### Late launch game

- high-fantasy environments,
- arcane/corrupted structures,
- stronger emissive effects,
- visually prestigious equipment,
- floating/attached magical details where useful,
- powerful but readable particles and auras.

Player bodies do **not** need visual muscle/body transformations. Status is communicated through gear, effects, titles, rank, and plot development.

---

## 16. Working Material / Equipment Tier Pattern

Exact fantasy material names remain provisional, but the agreed pattern is:

| Progression band | Material/visual direction |
|---|---|
| Adventurer | Copper/basic hardwood/crude magical materials |
| Adept | Iron/oak/refined magical materials |
| Vanguard | Steel/yew-like timber/charged magical materials |
| Champion | Runic metal/enchanted wood/arcane cores |
| Runebound | Mythril-style fantasy metal/elderwood/greater arcane materials |
| Paragon | Rare magical alloy/ancient wood/concentrated arcane essence |
| Ascendant | Highest launch-tier materials and visual effects |

The exact resource names should be finalized during content design rather than treated as locked lore.

The repeating content pattern is intentionally simple:

> new ore + new wood + new magical material → new tools/components → new weapons/armor → stronger enemies/boss rewards → next tier

Early crafted equipment is strictly vertical. Later boss and set gear creates build choices.

---

## 17. Player Plots and Tycoon-Flavored Progression

Every player receives a **visible plot in the shared server**.

Plots are functional progression spaces, not freeform housing at launch.

### Starting plot

Each plot begins with four combat training stations:

- Melee
- Defense
- Ranged
- Magic

Stations can be upgraded using normal progression resources/currency. Upgrades improve training effectiveness and should become increasingly prestigious visually.

### Later plot development

Players can eventually construct personal:

- Forge / Smithing station
- Fletching station
- Arcana station

These are later progression goals rather than immediate starter infrastructure.

The plot should evolve from a crude training yard into a developed adventurer's compound, giving both utility and visible social status.

No freeform base-building system is required for V1.

---

## 18. Offline Progression

The agreed return mechanic is **direct offline training** through the player's combat training infrastructure.

Combat stations continue generating combat-skill progression while the player is offline.

Working guardrails:

- offline gains are time-capped,
- offline rates should remain lower than strong active progression,
- station upgrades can improve offline training effectiveness,
- returning players should clearly see what they gained.

Exact cap duration, rates, and whether every combat station trains simultaneously remain balance/implementation decisions.

Offline gathering, production, boss loot, or general automated economy generation has **not** been agreed as part of V1.

---

## 19. Economy

The launch economy uses **one soft currency: Gold Coins**.

### Gold sources

- roaming enemies,
- bosses,
- selling gathered materials to NPCs,
- selling intermediate/final crafted items to NPCs,
- other simple progression rewards if needed.

### Gold sinks

- personal training-station upgrades,
- personal production-station construction/upgrades,
- shop materials,
- shop equipment,
- mastery-tree respecs after the first free respec,
- other progression conveniences if balance requires them.

### NPC selling

Gathering and production are legitimate money-making paths. Players can sell materials and crafted items to NPCs.

NPC pricing must prevent guaranteed infinite-profit loops such as buying all inputs from a shop, crafting them, and immediately reselling the output for more Gold than the purchased inputs cost.

Gathering one's own materials should generally produce better economic margins than buying every input.

### Player trading

Player-to-player trading is **not V1 scope**.

---

## 20. Social Systems

V1 social comparison comes from:

- visible shared player plots,
- visible Ascension rank/title,
- recognizable armor and weapon progression,
- rare boss equipment,
- shared-server bosses,
- leaderboards,
- boss contribution/damage display,
- visual effects and prestige indicators.

PvP and tournaments are intentionally deferred from V1.

---

## 21. First-Session Experience

### First 30 seconds

- Player spawns at their plot.
- Chooses Sword, Bow, or Staff.
- Immediately begins earning XP through the corresponding training station or a similarly obvious first action.

### First ~5 minutes

The player should naturally experience:

- combat-skill training,
- Defense training,
- leaving the plot,
- fighting low-level roaming enemies,
- earning Gold,
- receiving basic drops.

### ~5–20 minutes

The player discovers:

- Mining,
- Woodcutting,
- shared production stations,
- NPC shops,
- an early equipment upgrade path,
- Boss 1 and the concept of shared boss progression.

### ~15–25 minutes

Target: Ascension I / Adept.

This should feel like a meaningful milestone rather than a routine level-up.

### First 1–2 hours

Target experience:

- roughly Ascension II / Vanguard,
- progress toward Ascension III clearly visible,
- at least one plot station upgraded,
- exposure to multiple combat/production skills,
- at least one desirable boss/item goal,
- an obvious reason to return for offline gains and continued progression.

---

## 22. Monetization Direction

Monetization is not allowed to dictate the underlying progression design.

Current intent includes optional acceleration/convenience opportunities around areas such as:

- training-station upgrades,
- materials,
- some shop gear/convenience,
- cosmetics/effects,
- other progression accelerators.

The player has expressed interest in Robux-supported convenience around stations and shop acquisition, but **exact products, prices, conversion mechanics, and limits are not yet designed or locked**.

Hard progression walls, overwhelming permanent paid advantages, and deliberately miserable free progression are out of bounds.

---

## 23. Development Workflow and Scope Philosophy

The game is intended to be built primarily through an AI-orchestrated Roblox workflow using:

- Astra Extra High as orchestrator,
- Roblox Studio,
- Roblox Studio MCP,
- Git/GitHub,
- Roblox Script Sync where useful,
- Tripo3D and Blender cleanup/optimization where useful for assets.

The human role focuses on creative direction, progression design, gameplay feel, visual judgment, balance, acceptance testing, and approval.

Production should favor:

- short specifications,
- clear acceptance criteria,
- small implementation tasks,
- rapid playtesting,
- frequent iteration,
- source control,
- reversible changes.

Implementation has **not begun**. The project is still in pre-production/design.

---

## 24. Explicit V1 Exclusions

Unless later reconsidered for a clear retention/design reason, V1 does not include:

- PvP,
- tournaments,
- player trading,
- guilds,
- pets/companions,
- traditional quest chains beyond minimal onboarding/objectives,
- stealing/risk mechanics,
- dungeons,
- raids,
- freeform housing/base building,
- permanent character classes,
- randomized gear affixes,
- complex active-ability/hotbar systems,
- crafting minigames,
- consumable arrows/runes for every basic attack,
- equipment/tool durability,
- multiple soft currencies,
- a traditional limited bank/backpack loop.

Skill mastery trees **are** V1 scope.

---

## 25. Open Design / Balance Items

The following remain intentionally unresolved or provisional:

- exact XP curves for all skills,
- exact Ascension total-skilling requirements,
- exact enemy level ranges and stats,
- exact boss respawn times and participation threshold,
- exact drop rates and boss loot tables,
- exact Gold economy/prices,
- exact offline XP caps/rates,
- exact training-station and production-station upgrade curves,
- exact material/resource names,
- exact item counts per tier,
- exact mastery-node numerical values,
- final UI/UX layout,
- final plot layout and server player/plot count,
- exact leaderboards,
- whether V1 includes any very small signature active abilities or remains purely basic-attack + passive-build combat,
- detailed monetization products and pricing.

These should be resolved through targeted design and playtesting rather than assumed prematurely.
