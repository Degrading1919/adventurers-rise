# Equipment foundation

`src/Server/Equipment/Service.luau` is a trusted-server-only boundary over `PlayerData`. It owns the current V1 `Equipment` map while `Inventory.Items` remains the source of discrete-item ownership. There are no remotes, visual attachments, combat calculations, gathering calculations, requirements, or item grants.

The current slot IDs are stable internal IDs: `slot_weapon` and `slot_tool`. `src/Shared/ItemDefinitions.luau` maps starter/upgraded swords to `slot_weapon` and basic/upgraded pickaxes to `slot_tool`. Each has a provisional normalized `EffectivenessTier` of 1 or 2 so later combat and gathering systems can distinguish relative effectiveness without coupling to final balance values.

| API | Result |
| --- | --- |
| `GetSnapshot(userId)` | Copy of equipped item records keyed by slot |
| `GetEquippedItem(userId, slotId)` | Copy of one equipped item record |
| `Equip(userId, slotId, instanceId)` | Validates owned discrete item and definition slot, then writes the instance ID through `PlayerData.Update` |
| `Unequip(userId, slotId)` | Removes a valid equipped reference through `PlayerData.Update` |

An equipped instance cannot be removed through `Inventory.RemoveDiscreteItem`; the inventory service rejects it with `ItemEquipped`. Equipment reads are constructed from copies, and malformed or dangling saved equipment is rejected without guessing or repairing it.

Run repository checks with the official Luau CLI:

```powershell
python tests/run_equipment.py --luau <path-to-luau> --compiler <path-to-luau-compile> --analyzer <path-to-luau-analyze>
```
