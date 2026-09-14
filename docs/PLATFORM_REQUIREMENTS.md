# Adventurer's Rise — Platform Requirements

**Status:** Inherited V1 requirements from the original project brief that remain valid and were not superseded during design discussion.

These requirements complement `DESIGN_SOURCE_OF_TRUTH.md` and `V1_SCOPE.md`.

## Persistence

V1 requires persistent player save data for permanent progression, including at minimum:

- skill levels and XP,
- Mastery Point allocations,
- Ascension rank/progress,
- Gold Coins,
- inventory/resources,
- equipment and unique drops,
- plot ownership/state,
- combat-station upgrades,
- personal production-station ownership/upgrades,
- other permanent unlocks introduced during implementation.

Offline-training calculations must integrate safely with persistent save data rather than relying on the player remaining connected.

## Roblox / Mobile Usability

V1 must support Roblox mobile play as a first-class control target.

- No precision third-person aiming requirement.
- Hold Attack rather than tap/click spam.
- Mostly automatic targeting with optional manual override.
- UI controls must remain readable and usable on mobile screens.
- Core progression must not depend on keyboard-only shortcuts.
- Onboarding should be brief and immediately actionable rather than dialogue/tutorial heavy.

## Presentation

The project retains the original brief's stylized/readable art philosophy:

- strong silhouettes,
- clear visual hierarchy,
- readable combat and boss effects,
- low-to-moderate asset complexity,
- aggressive reuse of models and modular variations,
- clear visual differentiation between progression tiers,
- grounded medieval-adventure presentation that escalates into high fantasy.

Normal equipment tiers should primarily reuse meshes through texture/material/paint/emissive/effect changes. Unique meshes should be reserved for content where uniqueness creates real value, especially boss uniques and prestige rewards.

## Production Constraints

- Persistent source control through Git/GitHub.
- Roblox Studio is the target engine.
- Roblox Studio MCP is part of the intended AI-driven workflow.
- Astra Extra High is the intended primary implementation orchestrator.
- Roblox Script Sync may be used where useful.
- Tripo3D and Blender cleanup/optimization may be used for 3D asset production.
- Prefer reusable systems, data-driven content, short specifications, small implementation tasks, rapid playtesting, and reversible changes.

Implementation has not begun; these are design/production requirements for V1 planning.
