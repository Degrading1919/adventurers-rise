# Adventurer's Rise — Onboarding and UI Flow

**Status:** Agreed pre-implementation design direction. Exact visual layout remains iterative.

The onboarding philosophy is **learn by doing**. The game should not front-load systems through long dialogue or tutorial pages.

## Onboarding Rule

The player should never have to read several screens before being allowed to play.

Every onboarding step should follow:

> Do something → understand why it mattered → reveal the next thing.

By roughly 20–25 minutes, the player should have experienced the miniature form of the full game loop:

> train → fight → earn → gather → produce/buy → improve → boss → Ascend

## First Spawn

The player spawns directly at their plot.

A simple starter selection appears:

- Sword
- Bow
- Staff

The UI must clearly state that this is an initial combat focus, **not a permanent class choice**.

After selection, the weapon equips immediately and the matching combat station is emphasized.

### First Objective

> Train your chosen combat skill to Level 2.

The player should immediately see:

- XP gains,
- skill progress,
- station feedback,
- level-up feedback.

## Guided Objective Chain

### Phase 1 — Your Plot

1. Choose Sword, Bow, or Staff.
2. Reach Level 2 in the selected combat skill.
3. Train Defense to Level 2.
4. Receive a small Gold reward.

This teaches the plot, combat training, Defense, and basic rewards.

### Phase 2 — Leave the Plot

Objectives introduce roaming combat, for example:

> Defeat 3 enemies in the Borderlands.

Then:

> Earn 100 Gold.

Exact values are balance placeholders.

The player learns:

- automatic targeting,
- Hold Attack,
- enemy health/levels,
- Gold and drops,
- passive Defense XP during meaningful combat.

### Phase 3 — Gathering

Introduce one action at a time:

> Mine your first ore.

Then:

> Cut your first log.

The node UI itself should communicate level/tool requirements without a separate tutorial screen.

### Phase 4 — Production and Acquisition Choice

Next objectives introduce the hub stations and equipment progression:

> Smelt your ore at the town Forge.

Then:

> Craft or purchase your first equipment upgrade.

The onboarding should establish early that crafting and buying are both legitimate acquisition routes.

### Phase 5 — First Boss

The Goblin Chieftain should be visible or otherwise noticeable before the player is ready to fight it.

When appropriate, the objective becomes:

> Defeat the Goblin Chieftain.

The player experiences:

- shared boss combat,
- personal RNG loot,
- boss progression,
- progress toward Ascension I.

### Phase 6 — First Ascension

Final required onboarding objective:

> Become an Adept.

The Ascension interface clearly shows any remaining requirements.

After Ascension I, mandatory onboarding ends. The objective system becomes suggested goals rather than a linear tutorial chain.

## Main HUD

The HUD should feel like a Roblox simulator first, not a dense traditional MMO interface.

Always-visible information should stay limited to high-value information such as:

- Gold Coins,
- current Ascension rank,
- health,
- contextual Attack/interact controls,
- compact current objective,
- minimal menu access.

All nine skill levels should **not** permanently occupy the HUD.

## Core Menu

Use large, mobile-friendly sections.

### Character

Shows:

- equipped gear,
- current Ascension rank,
- relevant combat information,
- current weapon/style.

### Skills

Displays all nine skills clearly.

Each skill page should show:

- current level,
- XP progress,
- next important unlock(s),
- access to that skill's mastery tree.

The **Next Unlock** should be visually prominent to preserve simulator-style goal clarity.

### Inventory

Use simple sections for:

- Resources
- Equipment
- Special/Rare loot

The inventory is simulator-style with highly stackable resources and minimal management friction.

### Mastery

Mastery is accessed through the relevant skill page rather than requiring a separate dense top-level interface.

### Ascension

Shows:

- current rank,
- next rank,
- each requirement and current progress,
- rewards/unlocks.

The player should always be able to tell exactly what remains before the next Ascension.

## Combat Station UI

Approaching a station presents a simple interaction such as:

> Train Melee

The station panel should show:

- station tier,
- current skill level,
- current training effectiveness,
- upgrade availability/cost,
- next upgrade benefit.

Training should not require repeated clicking.

For mobile, station training may continue after a clear Train activation rather than requiring a touchscreen button to be held indefinitely.

Combat itself still uses **Hold Attack**.

## Production UI

Forge, Fletching, and Arcana use one shared interaction pattern.

The interface should expose:

- recipe/category selection,
- skill requirement,
- required materials,
- quantity,
- action duration where useful,
- Craft 1 / Craft 5 / Craft Max or equivalent batch controls.

Once started, crafting repeats automatically for the chosen quantity.

Hub and personal production stations use the same interface. Personal upgraded stations are simply faster/more convenient.

## Gathering UI

Gathering is intentionally minimal.

A resource node shows:

- resource name,
- required skill level,
- player's current skill level,
- relevant equipped tool/tier where useful.

Interact once to begin continuous gathering.

Display:

- action progress,
- XP gains,
- materials gained.

Moving away or cancelling stops the action.

## Combat UI

Automatic targeting must be visually legible without requiring tutorial explanation.

The current target receives a subtle readable marker/outline plus:

- enemy name,
- enemy level,
- health.

### Mobile

- movement joystick on left,
- large Attack control on right,
- optional tap-on-enemy target preference,
- no precision aiming joystick.

### PC

- normal movement/camera controls,
- natural Attack input,
- optional direct enemy selection as target preference.

Ranged and Magic must not require pixel-precise third-person aiming.

## Enemy Difficulty Readability

Enemy level and presentation should make danger understandable immediately.

Enemies do not scale to the player. A strong player returning to an early region should visibly overpower former threats.

## Boss UI

Boss encounters should provide:

- large readable boss health,
- boss name/tier or level,
- clear telegraphs,
- optional participant information where useful.

After defeat, each eligible player gets a dedicated **Your Loot** presentation for the personal RNG roll.

Rare drops receive stronger presentation than common drops. Particularly prestigious drops may later support a small server announcement.

## Offline Return Flow

After meaningful offline time, show a concise return summary such as:

**While You Were Away**

- Melee XP gained
- Defense XP gained
- Ranged XP gained
- Magic XP gained

If offline progression caused a level-up, immediately show the important unlock that resulted.

The desired return reaction is:

> I gained progress while away; what can I unlock or work toward now?

## Notifications

Avoid popup spam.

Use brief toasts or equivalent presentation for:

- skill level-up,
- new unlock,
- Mastery Point earned,
- rare drop,
- station upgrade availability,
- Ascension requirement completion.

## Mobile-First Acceptance Principle

UI and interaction are not accepted merely because they work on PC.

Every major interaction must remain usable on mobile, particularly:

- combat,
- training,
- crafting quantities,
- inventory,
- skill/mastery navigation,
- equipment,
- Ascension,
- boss encounters.

Exact layouts, colors, iconography, and final visual hierarchy should be iterated in Roblox Studio rather than over-specified before implementation.