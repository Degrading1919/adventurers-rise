# Item and inventory foundation

`src/Shared/ItemDefinitions.luau` is the central stable-ID catalog for the current slice items. Iron ore and iron bar are `Stackable`; the two swords and two pickaxes are `Discrete`. The four discrete definitions also state their V1 equipment slot and a provisional normalized effectiveness tier. Names, final stats, requirements, and effects remain later work.

`src/Server/Inventory/Service.luau` is a trusted-server-only boundary over PlayerData. It has no remotes, starter grants, rewards, drops, crafting, gathering, shops, or equip operations.

| API | Result |
| --- | --- |
| `GetSnapshot(userId)` | Copy of `{ Stacks, Items }` |
| `GetStackCount(userId, definitionId)` | Current count for a defined stackable item |
| `AddStack` / `RemoveStack` | Adds or removes a positive whole count; removal deletes an empty entry |
| `AddDiscreteItem` | Validates a discrete definition and saves a server-generated instance ID |
| `GetDiscreteItem` / `RemoveDiscreteItem` | Queries or removes one owned instance; removal rejects an equipped instance |

All mutation APIs validate item kind, IDs, amounts, ownership, and the safe whole-number limit before publishing through `PlayerData.Update`. Reads and returned discrete-item records are copies. The caller supplies `NewInstanceId` when constructing the service; future bootstrap composition must use a server GUID generator. An instance ID collision is rejected, never overwritten.

PlayerData v2 stores stackable counts by definition ID and discrete records by instance ID. `Equipment` remains a separate save boundary. Inventory does not apply stats or decide what is equipped, but preserves equipment references by refusing to remove an equipped discrete instance.

Adding an item normally means adding an immutable definition. Adding fields to stored discrete records, changing their representation, or adding a new inventory container is a PlayerData schema change with a migration. Removing or reclassifying a persisted definition requires an explicit migration plan; the service will reject inconsistent stored inventory rather than guessing.
