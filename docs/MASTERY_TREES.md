# Adventurer's Rise — V1 Mastery Trees

**Status:** Agreed framework; exact numerical bonuses remain TBD.

This file defines the launch mastery-tree system for all nine skills.

---

## Shared Framework

Every skill uses the same underlying mastery-tree system.

- 3 specialization branches per skill.
- 4 sequential nodes per branch.
- 12 possible nodes per skill.
- 8 total Mastery Points by level 60.
- Mastery Points are specific to the skill that earned them.
- Normal skill unlocks never depend on mastery choices.
- Nodes should mostly be passive modifiers.
- V1 mastery trees should not require new hotbar inputs.

### Mastery Point Cadence

| Skill Level | Point Earned |
|---:|---:|
| 5 | 1 |
| 10 | 1 |
| 15 | 1 |
| 20 | 1 |
| 30 | 1 |
| 40 | 1 |
| 50 | 1 |
| 60 | 1 |

### Branch Depth

| Node | Minimum Skill Level | Role |
|---|---:|---|
| I | 5 | Establish specialization |
| II | 15 | Strengthen specialization |
| III | 30 | Create meaningful advantage |
| IV | 50 | Capstone |

Nodes are purchased sequentially within a branch.

At level 60, a player can fully complete two branches, fully commit to one branch and mix the others, or distribute points more broadly.

A completed branch should generally create a meaningful but controlled advantage in its specialty rather than doubling total performance. Exact percentages are balance values.

---

## Respec Rules

- Each skill is respecced independently.
- The first respec for each skill is free.
- Later respecs cost Gold Coins.
- Respec cost should scale sensibly with skill/mastery depth without becoming punitive.
- Respeccing immediately returns all Mastery Points for that skill.
- Skill level, XP, Ascension, gear, and other progression are unaffected.
- Robux is not required to correct a mastery-tree choice.

---

# Combat Skills

## Melee

### Might
**Identity:** Heavy hitter

Focuses on raw melee damage and stronger individual strikes.

### Tempo
**Identity:** Fast fighter

Focuses on attack speed and reduced time between melee attacks.

### Cleave
**Identity:** Crowd fighter

Focuses on performance against multiple nearby enemies and group farming without becoming the strongest single-target boss path.

---

## Defense

### Fortitude
**Identity:** Health tank

Focuses on maximum health and total survivability.

### Bulwark
**Identity:** Damage tank

Focuses on direct incoming-damage reduction.

### Resilience
**Identity:** Recovery tank

Focuses on recovery and resistance to disruptive enemy/boss effects without adding an active blocking control scheme.

---

## Ranged

### Marksman
**Identity:** Heavy shot

Focuses on raw ranged damage and strong individual attacks.

### Rapid Fire
**Identity:** Fast attacker

Focuses on attack speed and sustained ranged DPS.

### Volley
**Identity:** Multi-target hunter

Focuses on piercing, secondary projectile behavior, and/or group damage.

---

## Magic

### Destruction
**Identity:** Powerful caster

Focuses on raw Magic damage and single-target power.

### Channeling
**Identity:** Fast caster

Focuses on cast/attack speed and sustained magical damage.

### Arcane Reach
**Identity:** Area caster

Focuses on splash, chaining, and/or other multi-target magical behavior.

Magic does not require a full mana-management subsystem at V1.

---

# Gathering Skills

## Mining

### Excavation
**Identity:** Fast miner

Focuses on reducing gathering time.

### Extraction
**Identity:** High-yield miner

Focuses on producing additional primary ore/material output.

### Prospecting
**Identity:** Rare-resource miner

Focuses on gems, crystals, essence, and other uncommon magical resources.

---

## Woodcutting

### Lumberjack
**Identity:** Fast cutter

Focuses on reducing Woodcutting action time.

### Harvesting
**Identity:** High-yield cutter

Focuses on additional normal logs and common timber.

### Heartwood
**Identity:** Rare-resource cutter

Focuses on rare woods and special natural materials.

Woodcutting intentionally mirrors Mining structurally for readability and implementation reuse.

---

# Production Skills

## Smithing

### Smelter
**Identity:** Processing specialist

Focuses on faster and/or more efficient ore-to-bar processing.

### Forgemaster
**Identity:** Equipment specialist

Focuses on faster and/or more material-efficient finished equipment and tool production.

### Merchant Smith
**Identity:** Economic specialist

Focuses on improved NPC sale value or profitability from personally forged goods.

This branch does not create randomized superior equipment stats.

---

## Fletching

### Bowyer
**Identity:** Equipment specialist

Focuses on bows, staff bodies, and other major wooden equipment/components.

### Efficient Fletcher
**Identity:** Resource specialist

Focuses on material efficiency and improved component output.

### Master Craftsman
**Identity:** Economic specialist

Focuses on improved NPC sale value or profitability from personally produced Fletching goods.

Fletching remains useful beyond Ranged because wooden components feed Magic and other production chains.

---

## Arcana

### Refinement
**Identity:** Magical processor

Focuses on faster processing of raw magical resources into usable components.

### Conservation
**Identity:** Efficient enchanter

Focuses on reduced consumption of valuable magical materials.

### Infusion
**Identity:** Enhancement specialist

Focuses on the effectiveness of curated magical upgrades and enchantments.

Arcana should eventually enhance equipment across Melee, Ranged, and Magic so it does not become a Mage-only production path.

---

## Implementation Principle

These are nine content configurations of **one reusable mastery-tree system**, not nine bespoke software systems.

Exact node effects and numerical values should be balanced during implementation/playtesting while preserving the shared 3-branch / 4-node / 8-point structure unless testing reveals a clear structural problem.
