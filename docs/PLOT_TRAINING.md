# Plot and combat-training foundation

`src/Shared/PlotSockets.luau` defines the fixed stable socket IDs for the plot layout: Melee, Defense, Ranged, Magic, Forge, Fletching, and Arcana. This repository foundation creates no physical plots, instances, models, prompts, UI, or plot assignment.

`src/Server/Plots/StationDefinitions.luau` currently defines only `station_training_melee` and `station_training_defense`. Each definition maps one socket to one skill and contains its ordered tier data. Tier 1 is the implicit default, while the current tier-2 cost and XP-per-second rate are clearly provisional. Add later station types or tiers through definitions rather than station-specific code; this does not establish the final six-tier launch balance.

`PlayerData.Plot.Stations` stores upgraded station records as `{ Tier = number }`, keyed by stable station ID. An absent record resolves to tier 1 without a write. The existing PlayerData v2 container supports this record, so no schema migration is required. Shared-server plot assignment and transient training state remain outside this foundation.

| API | Result |
| --- | --- |
| `GetStation(userId, stationId)` | Copy-like resolved state for the user-owned station, including its next upgrade cost when configured |
| `UpgradeStation(userId, stationId)` | Validates state and debits Gold while changing the saved tier in one `PlayerData.Update` callback |
| `AwardTrainingForElapsed(userId, stationId, elapsedSeconds)` | Converts a trusted server timer interval and configured rate into Skill/XP award for the station skill |

Station upgrades use the existing persisted Gold rules but must update Gold and `Plot.Stations` in one PlayerData mutation; calling a separate Gold debit API would permit partial state. Training accepts a bounded, finite positive elapsed interval for later server-timer composition and persists neither sessions nor timers. There are no remotes, offline gains, combat, production stations, Ranged/Magic content, or final balance values.

Run repository checks with the official Luau CLI:

```powershell
python tests/run_plot_training.py --luau <path-to-luau> --compiler <path-to-luau-compile> --analyzer <path-to-luau-analyze>
```
