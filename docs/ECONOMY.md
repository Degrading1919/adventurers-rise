# Economy and shop foundation

`src/Server/Economy/Service.luau` is a trusted-server-only boundary over `PlayerData.Gold`, `Inventory`, and `Equipment`. It has no remotes, shop UI, NPC world objects, starter grants, enemy rewards, boss rewards, crafting, gathering, combat, or monetization.

| API | Result |
| --- | --- |
| `GetGold(userId)` | Current persisted Gold |
| `CreditGold` / `DebitGold` | Validated positive whole-Gold mutation through `PlayerData.Update` |
| `PurchaseStack` / `SellStack` | Atomically changes Gold and a stackable inventory count |
| `PurchaseDiscrete` / `SellDiscrete` | Atomically changes Gold and an owned discrete-item record |

`ShopCatalog.luau` is the centralized, provisional catalog. It uses stable shop and item-definition IDs, and each entry independently declares optional buy and sell prices. The current hub catalog buys/sells iron ore, only sells iron bars, and buys/sells the upgraded sword; unlisted definitions are not implicitly tradeable. Direct shop resale prices are lower than buy prices, so a direct NPC buy → sell loop cannot produce Gold.

Every inventory-and-Gold transaction performs all validation and both mutations in one `PlayerData.Update` callback. Failed ownership, equipment, balance, capacity, or Gold-bound checks leave both values unchanged. Selling an equipped discrete item is rejected with `ItemEquipped`.

The existing PlayerData v2 `Gold`, `Inventory`, and `Equipment` fields already support these operations, so no schema migration is required. Crafting profitability is intentionally not evaluated here because recipes and production prices do not exist yet; validate crafting input/output resale paths when the crafting system is added.

Run repository checks with the official Luau CLI:

```powershell
python tests/run_economy.py --luau <path-to-luau> --compiler <path-to-luau-compile> --analyzer <path-to-luau-analyze>
```
