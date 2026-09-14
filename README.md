# Adventurer's Rise

**Adventurer's Rise** is a Roblox lite-MMORPG built on simulator and tycoon progression logic: one persistent adventurer trains interconnected skills, develops a visible personal plot, gathers and crafts equipment, hunts shared bosses, and permanently Ascends from grounded medieval adventure into high fantasy.

## Project Status

**PlayerData foundation. Core design and the first vertical slice are defined. Server/client bootstraps and versioned server persistence exist; gameplay implementation has not begun.**

The project is ready to begin narrow, source-controlled vertical-slice engineering tasks. The immediate goal is to prove the complete progression loop and reusable architecture before expanding toward full V1 content.

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
- Persistent player save data for permanent progression
- Persistent simulator-style Mining and Woodcutting nodes
- Interconnected crafting with simple intermediate production chains
- Visible shared player plots with upgradeable combat training stations and later personal production stations
- Direct capped offline combat-skill training through plot stations
- Linear early equipment progression, with curated set bonuses and unique boss gear becoming important later
- One soft currency: Gold Coins
- NPC selling makes gathering, crafting, and combat all viable economic paths
- PvP, tournaments, trading, guilds, raids, dungeons, pets, and other larger systems deferred from V1

## Design Documentation

The repository documentation is intentionally lightweight. These files are the current project record:

### Core design

- [`docs/DESIGN_SOURCE_OF_TRUTH.md`](docs/DESIGN_SOURCE_OF_TRUTH.md) — authoritative current game design and open balance/content items
- [`docs/V1_SCOPE.md`](docs/V1_SCOPE.md) — agreed launch boundary, first-session targets, success criteria, and explicit deferrals
- [`docs/DECISION_LOG.md`](docs/DECISION_LOG.md) — major design decisions, superseded ideas, and the reasoning trail from the original brief

### System specifications

- [`docs/MASTERY_TREES.md`](docs/MASTERY_TREES.md) — reusable mastery-tree framework and all nine skill branch identities
- [`docs/PLOT_PROGRESSION.md`](docs/PLOT_PROGRESSION.md) — fixed plot layout, combat-station progression, personal production infrastructure, and plot end state
- [`docs/ONBOARDING_UI.md`](docs/ONBOARDING_UI.md) — first-session objective flow, HUD/menu philosophy, interaction UI, boss/loot presentation, and mobile-first rules

### Engineering and implementation handoff

- [`docs/TECHNICAL_ARCHITECTURE.md`](docs/TECHNICAL_ARCHITECTURE.md) — server authority, data-driven content, stable IDs, versioned saves, system boundaries, networking, performance, and Codex/Astra responsibilities
- [`docs/VERTICAL_SLICE.md`](docs/VERTICAL_SLICE.md) — exact first implementation target, exclusions, dependency order, and acceptance criteria before V1 expansion
- [`docs/PLAYER_DATA.md`](docs/PLAYER_DATA.md), [`docs/SKILL_XP.md`](docs/SKILL_XP.md), [`docs/ITEM_INVENTORY.md`](docs/ITEM_INVENTORY.md), [`docs/EQUIPMENT.md`](docs/EQUIPMENT.md), [`docs/ECONOMY.md`](docs/ECONOMY.md), and [`docs/PLOT_TRAINING.md`](docs/PLOT_TRAINING.md) — implemented persistence, Skill/XP, inventory, equipment, economy, and plot/training boundaries
- [`docs/PLATFORM_REQUIREMENTS.md`](docs/PLATFORM_REQUIREMENTS.md) — persistent-save, mobile, presentation, and production requirements retained from the original brief

When documents conflict, **`DESIGN_SOURCE_OF_TRUTH.md` takes precedence**, followed by the most recent explicit project-owner decision. Dedicated agreed specifications elaborate the source-of-truth design and should be followed for their respective domains. `PLATFORM_REQUIREMENTS.md` records inherited requirements that remain valid where newer documents are silent.

## Development Direction

### Source foundation

Both entry points load the shared, immutable project name and report startup in Output. The server also starts versioned PlayerData loading, autosave, and session cleanup. Server-only Skill/XP, Inventory, Equipment, Economy, and Plot/Training modules await explicit composition by their future gameplay tasks; they add no XP/item triggers, client access, combat, gathering, or visuals. See [`docs/PLAYER_DATA.md`](docs/PLAYER_DATA.md), [`docs/SKILL_XP.md`](docs/SKILL_XP.md), [`docs/ITEM_INVENTORY.md`](docs/ITEM_INVENTORY.md), [`docs/EQUIPMENT.md`](docs/EQUIPMENT.md), [`docs/ECONOMY.md`](docs/ECONOMY.md), and [`docs/PLOT_TRAINING.md`](docs/PLOT_TRAINING.md) for their boundaries and repository checks. No system loader, remotes, gameplay, or external dependencies are installed.

The source maps to three **Folder** instances through native [Script Sync](https://create.roblox.com/docs/scripting/sync):

| Repository directory | Studio folder | Current script |
| --- | --- | --- |
| `src/Server` | `ServerScriptService.Server` | `Bootstrap.server.luau` → `Bootstrap` (Script, RunContext **Server**) |
| `src/Client` | `StarterPlayer.StarterPlayerScripts.Client` | `Bootstrap.local.luau` → `Bootstrap` (**LocalScript**) |
| `src/Shared` | `ReplicatedStorage.Shared` | `Project.luau` / `SkillIds.luau` → ModuleScripts |

Keep the client entry point as `.local.luau` (LocalScript); `.client.luau` means a Script with Client RunContext in native Sync. Shared modules return configuration tables or reusable functions and are visible to clients. `Project.luau` demonstrates a frozen configuration table consumed by both entry points. Future content definitions use stable internal IDs and reusable consumers; server-only logic and trusted state belong under `src/Server`.

For a later authorized Studio setup, create the folders above, select them in Explorer, and use **Script Sync → Sync to…** with the checkout's **`src` parent directory**. Studio appends each folder's name; selecting `src/Server` would create an extra `Server` directory. Review conflicts and choose **Disk version → Keep Disk version** for the reviewed source, preserving wanted Studio edits in Git first. Stop Play before branch switches and reconcile bidirectional Sync edits before committing.

Local place files under `studio/` and their locks are ignored by Git. Studio owns scene saving and local Sync bindings. The repository does not rebuild terrain or world assets. Repository-only tasks must not open or modify the place.

Repository checks: verify script suffixes and paths against the mapping, resolve module references, review strict Luau source, run the [PlayerData checks](docs/PLAYER_DATA.md#repository-verification), run `git diff --check`, and inspect the complete diff. The checks use the official Luau CLI; no runtime or testing framework is vendored.

When runtime testing is authorized, use **Play** with a client session. Expect `[Adventurer's Rise] Server bootstrap ready` and `[Adventurer's Rise] Client bootstrap ready` once each, with no introduced errors or infinite-yield warnings, then stop Play. The LocalScript runs from the player's copied `PlayerScripts.Client` folder. Report runtime validation separately from repository checks.

The intended implementation workflow is:

- Astra Extra High as primary orchestrator
- Roblox Studio
- Roblox Studio MCP
- Git + GitHub
- Roblox Script Sync where useful
- Codex for repository-first engineering tasks
- Tripo3D with Blender cleanup/optimization where appropriate

Implementation should favor narrow specifications, reusable systems, data-driven content, small feature branches/PRs, explicit acceptance criteria, rapid playtesting, source control, and reversible changes.

Do **not** ask an implementation agent to build the entire V1 at once. Start from [`docs/VERTICAL_SLICE.md`](docs/VERTICAL_SLICE.md), assign bounded tasks in dependency order, and validate the slice before adding content breadth.
