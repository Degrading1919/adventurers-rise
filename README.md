# Adventurer's Rise

**Adventurer's Rise** is a Roblox lite-MMORPG built on simulator and tycoon progression logic: one persistent adventurer trains interconnected skills, develops a visible personal plot, gathers and crafts equipment, hunts shared bosses, and permanently Ascends from grounded medieval adventure into high fantasy.

## Project Status

**Pre-production / core design. Implementation has not begun.**

The current goal is to finish the smallest coherent V1 design that can support a strong 1–2 hour first session, meaningful long-term progression, and repeat play while remaining practical to build primarily through an AI-orchestrated Roblox Studio workflow.

## Current Design at a Glance

- One persistent character with no permanent class lock
- Starter combat identity through Sword, Bow, or Staff
- 9 launch skills: Melee, Defense, Ranged, Magic, Mining, Woodcutting, Smithing, Fletching, Arcana
- Lightweight mastery tree for every skill
- Skill cap 60
- 6 permanent Ascensions from Adept through Ascendant, with Adventurer as the starting state
- Classic medieval-adventure setting that escalates from grounded fantasy into high fantasy
- Central hub + 3 compact, soft-gated progression regions
- 12 working standard enemy archetypes + 6 shared-server bosses
- Mostly automatic targeting and hold-to-attack combat designed for Roblox/mobile usability
- Persistent simulator-style Mining and Woodcutting nodes
- Interconnected crafting with simple intermediate production chains
- Visible shared player plots with upgradeable combat training stations and later personal production stations
- Direct capped offline combat-skill training through plot stations
- Linear early equipment progression, with curated set bonuses and unique boss gear becoming important later
- One soft currency: Gold Coins
- NPC selling makes gathering, crafting, and combat all viable economic paths
- PvP, tournaments, trading, guilds, raids, dungeons, pets, and other larger systems deferred from V1

## Design Documentation

The repository documentation is intentionally lightweight. These files are the current project design record:

- [`docs/DESIGN_SOURCE_OF_TRUTH.md`](docs/DESIGN_SOURCE_OF_TRUTH.md) — authoritative current game design and open items
- [`docs/V1_SCOPE.md`](docs/V1_SCOPE.md) — agreed launch boundary, first-session targets, and explicit deferrals
- [`docs/MASTERY_TREES.md`](docs/MASTERY_TREES.md) — reusable mastery-tree framework and all nine skill branch identities
- [`docs/DECISION_LOG.md`](docs/DECISION_LOG.md) — major decisions, superseded ideas, and current project status

When documents conflict, **`DESIGN_SOURCE_OF_TRUTH.md` takes precedence**, followed by the most recent explicit project-owner decision.

## Development Direction

The intended implementation workflow remains:

- Astra Extra High as primary orchestrator
- Roblox Studio
- Roblox Studio MCP
- Git + GitHub
- Roblox Script Sync where useful
- Tripo3D with Blender cleanup/optimization where appropriate

Development should favor short specifications, reusable systems, small implementation tasks, rapid playtesting, source control, and reversible changes. The first priority is proving that the progression loop is fun; the second is proving that Astra can build and iterate on it reliably.
