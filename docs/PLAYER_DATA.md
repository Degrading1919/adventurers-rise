# PlayerData foundation

`src/Server/PlayerData` owns saves and the private session cache. `Bootstrap.server.luau` creates one service and starts it. Future server modules receive that instance through explicit bootstrap wiring. Shared ID/config modules contain no trusted player state; there are no PlayerData remotes or client writes.

## Schema version 2

| Field | Initial value / meaning |
| --- | --- |
| `SchemaVersion` | `2` |
| `Gold` | `0`; nonnegative whole number |
| `SkillXP` | Zero XP for `skill_melee`, `skill_defense`, `skill_mining`, `skill_smithing`; levels are derived later |
| `Ascension` | `RankId = "ascension_adventurer"`, empty boolean `Flags` keyed by stable IDs |
| `Inventory.Stacks` | Empty dictionary of stackable item-definition IDs to positive whole counts |
| `Inventory.Items` | Empty dictionary of server-generated instance IDs to `{ DefinitionId }` records for discrete items |
| `Equipment` | Empty dictionary of slot IDs to owned item instance IDs |
| `Plot.Stations` | Empty dictionary of station IDs to saved records; no world plot assignment is persisted |
| `ProgressionFlags` | Empty dictionary of flag IDs to booleans |
| `MasterySelections` | Empty dictionary of selected node IDs to booleans for each slice skill |
| `LastSessionAt` | `0` until the first successful checkpoint/release, then server Unix seconds |

Every new profile gets independent tables. Records use string-keyed dictionaries and finite JSON primitives, with no Instances, functions, metatables, cycles, arrays, or derived skill levels. Inventory classification and mutation remain the responsibility of the inventory subsystem; future item-record fields require migrations. No starting items, selection rewards, offline calculations, or gameplay behavior are provided.

## Persistence and server access

- One key, `player_<UserId>`, in `AdventurersRise_PlayerData`; Studio runtime selects the separate `AdventurersRise_PlayerData_Development` store. Store names do not change with schema versions. There is no in-memory fallback on API failure.
- The stored envelope is `{ Data, Session?, LastWriteId? }`. `Data` is the versioned schema; session tokens/expiry and retry receipts are persistence metadata. Existing DataStore key metadata and associated user IDs are preserved.
- Load atomically acquires a unique token and 180-second lease with `UpdateAsync`. Only a missing key creates defaults. Invalid records, future schemas, missing migrations, and active foreign leases cancel the write and reject the player session.
- Saves verify the token and unexpired lease inside `UpdateAsync`. Autosave runs every 60 seconds and renews the lease. Each request gets at most three attempts, with 1- and 2-second retry delays. The callback does not yield. A write ID makes retries after lost responses idempotent, including final release.
- Join loads before exposing data. Leave saves a final snapshot and releases ownership, including when leaving during a load/autosave. Shutdown closes sessions concurrently and waits up to 25 seconds. Failed final writes are reported; interrupted servers rely on lease expiry. Outages or forced termination can lose changes since the last successful checkpoint.
- `GetSnapshot(userId)` returns a copy or `nil` while unavailable/closing/expired. `Update(userId, callback)` edits a copy synchronously, validates it, and publishes another copy to the server cache. It returns `(success, reason)`; it is **not an immediate durable save**. The callback must not yield, perform side effects, or recursively call PlayerData. PlayerData owns `SchemaVersion` and `LastSessionAt`.

Keep future client requests behind their owning server system's validation. A valid schema is not permission to grant Gold, XP, items, or progression. Pass stable IDs; do not rename stored IDs to match display text. `LastSessionAt` is the last saved session checkpoint, not an offline reward calculation or a guaranteed exact logout time.

The storage boundaries follow Roblox's [UpdateAsync and metadata guidance](https://create.roblox.com/docs/cloud-services/data-stores) and [30-second shutdown limit](https://create.roblox.com/docs/reference/engine/classes/DataModel#BindToClose). The 25-second local wait leaves a small margin; it cannot cancel a stalled platform request.

## Schema changes

Version 1 was the initial format; unversioned records have no implicit migration. The v1 → v2 migration converts only an empty inventory placeholder into the explicit `Stacks`/`Items` containers. Any non-empty v1 inventory fails migration and is left untouched because its intended stack or discrete representation cannot be inferred safely.

For each persisted schema change, increment `Schema.Version`, update defaults/types/validation, and add `steps[N]` in `Migrations.luau` to transform version N into N+1. Each step must be deterministic, non-yielding, preserve unrelated data, and explicitly set `SchemaVersion = N + 1`. Never reset a failed migration to defaults. Add a fixture from every supported old version; exercise the complete chain and failure cases. `Migrations.Run` exposes the same sequential runner for synthetic forward-migration tests.

## Repository verification

With Python 3.9+ and the official [Luau CLI release](https://github.com/luau-lang/luau/releases) available locally (verified with 0.738):

```powershell
python tests/run_player_data.py --luau <path-to-luau> --compiler <path-to-luau-compile> --analyzer <path-to-luau-analyze>
python tests/run_inventory.py --luau <path-to-luau> --compiler <path-to-luau-compile> --analyzer <path-to-luau-analyze>
git diff --check
```

The stdlib-only runner compiles every source file, type-checks PlayerData/SkillIds with only their require paths adapted for the CLI, and executes the unchanged modules against DataStore/clock/player-event doubles. It covers schema/migration failures, metadata, locks, lost responses, mutation isolation, join/leave races, autosave, and bounded shutdown. Temporary test files stay inside the repo and are removed afterward.

Studio Play, native Sync, Roblox engine type analysis, live DataStore permissions/throttling, and real cross-server/rejoin behavior remain deferred to an authorized runtime task. No Studio or place inspection is needed for these repository checks.
