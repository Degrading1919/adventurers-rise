# Adventurer's Rise — Open-World RPG Mission (autonomous, multi-day)

> **Fresh context? Read this file, then PLAN.md, then PROGRESS.md. Then run the bootstrap below.**

## Mission
Transform Adventurer's Rise from a functional vertical slice into a **deep, cohesive, genuinely playable lightweight open-world Roblox RPG**. Experiential quality bar: RuneScape / RuneScape: Dragonwilds — but the game stays **original Adventurer's Rise** (no copied names/lore/assets from any game). This is a multi-day autonomous run: inspect → build the highest-value improvement → integrate in Studio → playtest → have an independent critic evaluate → fix → continue. A context/usage boundary is NOT permission to declare the mission done.

## Decisive insight (why the plan is what it is)
The game **already has a fully-specified V1 design** (see `docs/`) that is only ~1/3 built. The current place is a fragment of intended **"Region I: The Borderlands"** on a flat 320×320 grass plane. Intended V1 = 3 regions (Borderlands → Elderwood → Shattered Reach, grounded→high-fantasy), 9 skills (cap 60), a 7-band material/equipment ladder tied to 6 Ascensions, armor slots, 12 enemies, 6 bosses, soft-gated exploration — **all data-driven ("content not code")**. Those canon names are the project's own (Caelmor-safe). **Strategy: build out the game's OWN V1, Region I deep-first**, preserving the working slice and extending it as data.

## On-thesis identity (keep the surface simple)
"A Roblox lite-MMORPG on simulator/tycoon progression logic" — simulator simplicity first, RPG identity layered on top. Loop: **train → fight → earn → gather → produce/buy → improve → boss → Ascend**, then offline gains. Grounded medieval → high fantasy. Add breadth as *data behind reusable systems*, never bespoke per-item/enemy code.

## Definition of Done (experiential rubric — independent evaluator + fresh-player playtests must concur; grade 1–5)
A brand-new player can: (1) enter and know what to do without dev knowledge; (2) explore a world of **distinct places** (biomes, town, wilderness, landmarks) not empty terrain between markers; (3) meet **geographically coherent** enemies + resources on a **difficulty gradient**; (4) improve **multiple skills**; (5) acquire **better weapons AND armor tiers** that visibly ease/gate harder areas; (6) discover **goals/POIs/activities**; (7) fight enemies + **≥2 bosses**; (8) use **gathering + production** chains; (9) see **visible progress** (levels/gear/Ascension/map) with clear next goals; (10) get **convincing visual + audio feedback** even on placeholders; (11) survive extended play — no dead-ends, severe bugs, broken persistence, runaway perf, or authority breaks; (12) on **desktop AND a mobile-sized viewport**. Advance a phase only when its target criteria are ≥4 and nothing regressed.

## Hard guardrails
- **No regression.** All test suites green every checkpoint; playtest the existing loop each phase; critics verify. Learn a subsystem's contracts before changing it.
- **Server-authoritative + data-driven.** Extend `*/Definitions.luau` + `Shared/*Ids.luau` + the read-model/request boundary. Client = presentation/intent only. Remotes are requests, never trusted commands.
- **Versioned saves.** Any PlayerData schema change ships a deterministic, non-destructive migration.
- **Caelmor firewall.** Only Adventurer's Rise canon + generic fantasy. Zero Caelmor names/ids/lore/deps.
- **Placeholders with clean seams.** Primitives/Terrain/Studio-generative for props/creatures/materials; document each placeholder's replacement seam; don't over-polish soon-replaced art.
- **Mobile-first** is an acceptance gate. **Studio-owned** world changes tracked in PROGRESS + place saved; repo owns code/config/data.

## Independent evaluation loop (mission-critical)
After each slice, spawn an evaluator subagent that did NOT build it. Subagents can't drive the Studio MCP, so **I** run the live playtest and capture screenshots + runtime state + honest repro data; the evaluator grades code + that evidence vs the rubric and flags shallow/confusing/generic/broken/incoherent issues. Do not let evaluators rationalize shortcomings; feed findings into the next cycle. Periodically play as a fresh player: "better game, or just a bigger codebase?"

## Fresh-context BOOTSTRAP (run every new window)
1. Read `mission/MISSION.md`, `PLAN.md`, `PROGRESS.md` (and `DECISIONS.md` if needed).
2. `git log --oneline -15` and `git status`; confirm on branch `feature/open-world-rpg`.
3. Run suites: `for r in tests/run_*.py; do python "$r" --luau .validation/luau/luau.exe --compiler .validation/luau/luau-compile.exe --analyzer .validation/luau/luau-analyze.exe; done` (expect all green). Windows git-bash: use absolute exe paths via `ROOT=$(pwd -W)`.
4. If the current slice is world-facing, inspect Studio (`Roblox_Studio` MCP, place id 136843447225408, studio id 1e765b7b-6dd9-439b-bfcc-66b1688e4943) read-only.
5. Resume the single **NEXT ACTION** in PLAN.md.

## SHUTDOWN before a window ends
Commit stable work; update PLAN (NEXT ACTION), PROGRESS (checkpoint + defects + Studio state), DECISIONS (new calls); leave repo + Studio coherent so a fresh context resumes with zero human explanation.
