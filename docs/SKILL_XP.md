# Skill and XP foundation

`src/Server/Skills` is the server-only boundary for reading a skill level and awarding XP. It owns no triggers, remotes, mastery effects, offline gains, UI state, or save lifecycle. A later server system calls it only after validating the gameplay event that earned XP.

`Definitions.luau` currently describes Melee, Defense, Mining, and Smithing using their immutable IDs from `src/Shared/SkillIds.luau`. Every definition references a curve ID. Adding a skill is a definition/data change plus the corresponding versioned `PlayerData.SkillXP` key; the level and awarding logic do not change.

## Curves and cap

The project-wide cap is 60. `Service.New(playerData, configuration)` requires one curve for every referenced curve ID:

```luau
{
	Curves = {
		curve_standard = {
			MaximumXP = 999999,
			Thresholds = { [1] = 0, [2] = 100, -- through [60] },
		},
	},
}
```

This is an interface example, not an approved balance curve. No production thresholds are shipped by this foundation. Every curve must contain strictly increasing finite thresholds for levels 1 through 60, start level 1 at zero, and set a finite `MaximumXP` at or above the level-60 threshold. Future balance work supplies or replaces this configuration during server composition without changing the service.

`GetState(userId, skillId)` returns a copy-like state value containing XP, derived level, current threshold, and next threshold when one exists. `AwardXP(userId, skillId, amount)` calls trusted `PlayerData.Update` and changes only that skill's XP. It rejects unknown IDs, invalid user IDs, non-finite/zero/negative amounts, pre-existing out-of-bounds XP, overflow, and awards beyond the configured maximum. The operation is not client-accessible and does not force an immediate DataStore write; PlayerData remains responsible for durable checkpoints.

Skill level is never stored in PlayerData. If a future curve lowers its maximum below valid existing XP, migration/balance work must address that state before enabling the curve; the skill service fails closed instead of silently truncating progress.
