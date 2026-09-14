# Implementation instructions

- Use narrow feature branches and reviewable PRs. `main` is accepted source of truth; merge only with project-owner authorization.
- Start with `README.md`, `docs/TECHNICAL_ARCHITECTURE.md`, and `docs/VERTICAL_SLICE.md`. Consult other design docs only when needed and within the task's reading boundary. Route design questions to `docs/DESIGN_SOURCE_OF_TRUTH.md` and dedicated specifications; follow README's conflict precedence. `docs/PLATFORM_REQUIREMENTS.md` applies where newer docs are silent.
- Preserve agreed design and system boundaries. Implement only assigned work. Avoid unrelated cleanup, speculative scaffolding, and unnecessary dependencies; justify any dependency addition.
- Progression, economy, combat outcomes, and persistent state are server-authoritative. Treat client remotes as validated requests. Clients own input/presentation; shared source must contain no secrets or trusted server state.
- Use reusable logic plus central definitions with stable internal IDs, not display-name identifiers. Version persistent schemas and migrate existing data. Prefer events/timers over unnecessary per-frame loops.
- GitHub owns Luau, configuration/definitions, schemas, and docs. Studio owns terrain, placed instances, assets, and scene presentation. Follow README's native Sync mapping and reconcile Studio code edits into Git. Inspect a place before changing it; coordinate subsystem ownership. Honor repository-only tasks without accessing Studio or place files.
- Use strict Luau and explicit requires for implemented modules. Add subsystem structure when the subsystem exists.
- Run appropriate source/behavior checks and inspect the final diff for scope drift. When Studio work is authorized, validate runtime changes with Play and server/client Output; evaluate interactions on PC/mobile. Report checks actually run, errors, and blockers; never claim unrun checks passed.
