"""Run the full vertical-slice composition (every server module) with Roblox boundary doubles."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--luau", required=True, help="Path to the official Luau CLI")
    parser.add_argument("--compiler", required=True, help="Path to luau-compile")
    parser.add_argument("--analyzer", required=True, help="Path to luau-analyze")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    sources = sorted((root / "src").rglob("*.luau"))
    assert all(path.read_text(encoding="utf-8").startswith("--!strict\n") for path in sources)
    subprocess.run([args.compiler, "--null", *map(str, sources)], check=True, cwd=root)

    shared_modules = [
        "SkillIds", "PlotSockets", "EquipmentSlots", "ItemDefinitions", "EnemyIds",
        "GatheringNodeIds", "RecipeIds", "AscensionIds", "ProgressionFlagIds", "MasteryIds",
        "RequestIds", "EventIds",
    ]
    modules = {name: root / f"src/Shared/{name}.luau" for name in shared_modules}
    modules.update({
        "PlayerDataSchema": root / "src/Server/PlayerData/Schema.luau",
        "PlayerDataMigrations": root / "src/Server/PlayerData/Migrations.luau",
        "PlayerDataStore": root / "src/Server/PlayerData/Store.luau",
        "PlayerDataService": root / "src/Server/PlayerData/Service.luau",
        "SkillDefinitions": root / "src/Server/Skills/Definitions.luau",
        "SkillCurves": root / "src/Server/Skills/Curves.luau",
        "SkillsService": root / "src/Server/Skills/Service.luau",
        "InventoryService": root / "src/Server/Inventory/Service.luau",
        "EquipmentService": root / "src/Server/Equipment/Service.luau",
        "ShopCatalog": root / "src/Server/Economy/ShopCatalog.luau",
        "EconomyService": root / "src/Server/Economy/Service.luau",
        "StationDefinitions": root / "src/Server/Plots/StationDefinitions.luau",
        "PlotsService": root / "src/Server/Plots/Service.luau",
        "EnemyDefinitions": root / "src/Server/Enemies/Definitions.luau",
        "EnemiesService": root / "src/Server/Enemies/Service.luau",
        "CombatService": root / "src/Server/Combat/Service.luau",
        "GatheringDefinitions": root / "src/Server/Gathering/Definitions.luau",
        "GatheringService": root / "src/Server/Gathering/Service.luau",
        "CraftingDefinitions": root / "src/Server/Crafting/Definitions.luau",
        "CraftingService": root / "src/Server/Crafting/Service.luau",
        "BossDefinitions": root / "src/Server/Bosses/Definitions.luau",
        "BossesService": root / "src/Server/Bosses/Service.luau",
        "AscensionDefinitions": root / "src/Server/Ascension/Definitions.luau",
        "AscensionService": root / "src/Server/Ascension/Service.luau",
        "MasteryDefinitions": root / "src/Server/Mastery/Definitions.luau",
        "MasteryService": root / "src/Server/Mastery/Service.luau",
        "OfflineTrainingDefinitions": root / "src/Server/OfflineTraining/Definitions.luau",
        "OfflineTrainingService": root / "src/Server/OfflineTraining/Service.luau",
        "PlayerHealthService": root / "src/Server/PlayerHealth/Service.luau",
        "CompositionGatheringSessions": root / "src/Server/Composition/GatheringSessions.luau",
        "CompositionTrainingSessions": root / "src/Server/Composition/TrainingSessions.luau",
        "CompositionCombatRewards": root / "src/Server/Composition/CombatRewards.luau",
        "CompositionEnemyCombat": root / "src/Server/Composition/EnemyCombat.luau",
        "CompositionPlayerEvents": root / "src/Server/Composition/PlayerEvents.luau",
        "CompositionReadModel": root / "src/Server/Composition/ReadModel.luau",
        "CompositionWorldAdapters": root / "src/Server/Composition/WorldAdapters.luau",
        "CompositionService": root / "src/Server/Composition/Service.luau",
    })

    wrappers = ["local loaders = {}"]
    for name, path in modules.items():
        wrappers.append(f'loaders["{name}"] = function(script, game, require)\n{path.read_text(encoding="utf-8")}\nend')
    shared_table = ", ".join(f'{name} = "{name}"' for name in shared_modules)
    wrappers.append(f'''
local siblings = {{}}
for name in loaders do siblings[name] = name end
local scripts = {{
    SkillCurves = {{ Parent = {{ Definitions = "SkillDefinitions" }} }},
    SkillsService = {{ Parent = {{ Definitions = "SkillDefinitions" }} }},
    EconomyService = {{ Parent = {{ ShopCatalog = "ShopCatalog" }} }},
    PlotsService = {{ Parent = {{ StationDefinitions = "StationDefinitions", Parent = {{ Economy = {{ Service = "EconomyService" }} }} }} }},
    EnemiesService = {{ Parent = {{ Definitions = "EnemyDefinitions" }} }},
    GatheringService = {{ Parent = {{ Definitions = "GatheringDefinitions" }} }},
    CraftingService = {{ Parent = {{ Definitions = "CraftingDefinitions" }} }},
    BossDefinitions = {{ Parent = {{ Parent = {{ Enemies = {{ Definitions = "EnemyDefinitions" }} }} }} }},
    BossesService = {{ Parent = {{ Definitions = "BossDefinitions" }} }},
    AscensionService = {{ Parent = {{ Definitions = "AscensionDefinitions" }} }},
    MasteryService = {{ Parent = {{ Definitions = "MasteryDefinitions" }} }},
    OfflineTrainingDefinitions = {{ Parent = {{ Parent = {{ Plots = {{ StationDefinitions = "StationDefinitions" }} }} }} }},
    OfflineTrainingService = {{ Parent = {{ Definitions = "OfflineTrainingDefinitions" }} }},
    PlayerDataMigrations = {{ Parent = {{ Schema = "PlayerDataSchema" }} }},
    PlayerDataStore = {{ Parent = {{ Schema = "PlayerDataSchema", Migrations = "PlayerDataMigrations" }} }},
    PlayerDataService = {{ Parent = {{ Schema = "PlayerDataSchema", Store = "PlayerDataStore" }} }},
    CompositionCombatRewards = {{ Parent = {{ Parent = {{ Enemies = {{ Definitions = "EnemyDefinitions" }} }} }} }},
    CompositionEnemyCombat = {{ Parent = {{ Parent = {{ Enemies = {{ Definitions = "EnemyDefinitions" }} }} }} }},
    CompositionReadModel = {{ Parent = {{ Parent = {{ Plots = {{ StationDefinitions = "StationDefinitions" }}, Economy = {{ ShopCatalog = "ShopCatalog" }} }} }} }},
    CompositionService = {{
        Parent = {{
            GatheringSessions = "CompositionGatheringSessions",
            TrainingSessions = "CompositionTrainingSessions",
            CombatRewards = "CompositionCombatRewards",
            EnemyCombat = "CompositionEnemyCombat",
            PlayerEvents = "CompositionPlayerEvents",
            ReadModel = "CompositionReadModel",
            Parent = {{
                Skills = {{ Curves = "SkillCurves", Service = "SkillsService" }},
                Inventory = {{ Service = "InventoryService" }},
                Equipment = {{ Service = "EquipmentService" }},
                Economy = {{ Service = "EconomyService" }},
                Plots = {{ Service = "PlotsService" }},
                Enemies = {{ Service = "EnemiesService" }},
                Combat = {{ Service = "CombatService" }},
                Gathering = {{ Service = "GatheringService" }},
                Crafting = {{ Service = "CraftingService" }},
                Bosses = {{ Service = "BossesService" }},
                Ascension = {{ Service = "AscensionService" }},
                Mastery = {{ Service = "MasteryService" }},
                OfflineTraining = {{ Service = "OfflineTrainingService" }},
                PlayerHealth = {{ Service = "PlayerHealthService" }},
            }},
        }},
    }},
}}
local fakeGame = {{
    GetService = function(_, name)
        assert(name == "ReplicatedStorage", "Unexpected module service: " .. name)
        return {{ Shared = {{ {shared_table} }} }}
    end,
}}
local loaded = {{}}
local function moduleRequire(name)
    assert(loaders[name], "Unresolved module: " .. tostring(name))
    if loaded[name] == nil then
        loaded[name] = loaders[name](scripts[name] or {{ Parent = siblings }}, fakeGame, moduleRequire)
    end
    return loaded[name]
end
local function runTests(require)
''')
    wrappers.append((root / "tests/Composition.spec.luau").read_text(encoding="utf-8"))
    wrappers.append("end\nrunTests(moduleRequire)\n")

    with tempfile.TemporaryDirectory(prefix=".composition-", dir=root / "tests") as directory:
        temporary = Path(directory)
        assert temporary.resolve().is_relative_to(root / "tests")
        adapted = []
        for name, path in modules.items():
            source = path.read_text(encoding="utf-8")
            source = source.replace('local ReplicatedStorage = game:GetService("ReplicatedStorage")\nlocal Shared = ReplicatedStorage.Shared\n', '')
            source = source.replace('local Shared = game:GetService("ReplicatedStorage").Shared\n', '')
            for shared_name in shared_modules:
                source = source.replace(f'require(Shared.{shared_name})', f'require("./{shared_name}")')
                source = source.replace(f'require(game:GetService("ReplicatedStorage").Shared.{shared_name})', f'require("./{shared_name}")')
            if name == "SkillCurves":
                source = source.replace('require(script.Parent.Definitions)', 'require("./SkillDefinitions")')
            elif name == "SkillsService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./SkillDefinitions")')
            elif name == "EconomyService":
                source = source.replace('require(script.Parent.ShopCatalog)', 'require("./ShopCatalog")')
            elif name == "PlotsService":
                source = source.replace('require(script.Parent.Parent.Economy.Service)', 'require("./EconomyService")')
                source = source.replace('require(script.Parent.StationDefinitions)', 'require("./StationDefinitions")')
            elif name == "EnemiesService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./EnemyDefinitions")')
            elif name == "GatheringService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./GatheringDefinitions")')
            elif name == "CraftingService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./CraftingDefinitions")')
            elif name == "BossDefinitions":
                source = source.replace('require(script.Parent.Parent.Enemies.Definitions)', 'require("./EnemyDefinitions")')
            elif name == "BossesService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./BossDefinitions")')
            elif name == "AscensionService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./AscensionDefinitions")')
            elif name == "MasteryService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./MasteryDefinitions")')
            elif name == "OfflineTrainingDefinitions":
                source = source.replace('require(script.Parent.Parent.Plots.StationDefinitions)', 'require("./StationDefinitions")')
            elif name == "OfflineTrainingService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./OfflineTrainingDefinitions")')
            elif name == "PlayerDataMigrations":
                source = source.replace('require(script.Parent.Schema)', 'require("./PlayerDataSchema")')
            elif name == "PlayerDataStore":
                source = source.replace('require(script.Parent.Schema)', 'require("./PlayerDataSchema")')
                source = source.replace('require(script.Parent.Migrations)', 'require("./PlayerDataMigrations")')
            elif name == "PlayerDataService":
                source = source.replace('require(script.Parent.Schema)', 'require("./PlayerDataSchema")')
                source = source.replace('require(script.Parent.Store)', 'require("./PlayerDataStore")')
            elif name == "CompositionCombatRewards":
                source = source.replace('require(script.Parent.Parent.Enemies.Definitions)', 'require("./EnemyDefinitions")')
            elif name == "CompositionEnemyCombat":
                source = source.replace('require(script.Parent.Parent.Enemies.Definitions)', 'require("./EnemyDefinitions")')
            elif name == "CompositionReadModel":
                source = source.replace('require(script.Parent.Parent.Plots.StationDefinitions)', 'require("./StationDefinitions")')
                source = source.replace('require(script.Parent.Parent.Economy.ShopCatalog)', 'require("./ShopCatalog")')
            elif name == "CompositionService":
                source = source.replace('require(script.Parent.Parent.Skills.Curves)', 'require("./SkillCurves")')
                source = source.replace('require(script.Parent.Parent.Skills.Service)', 'require("./SkillsService")')
                source = source.replace('require(script.Parent.Parent.Inventory.Service)', 'require("./InventoryService")')
                source = source.replace('require(script.Parent.Parent.Equipment.Service)', 'require("./EquipmentService")')
                source = source.replace('require(script.Parent.Parent.Economy.Service)', 'require("./EconomyService")')
                source = source.replace('require(script.Parent.Parent.Plots.Service)', 'require("./PlotsService")')
                source = source.replace('require(script.Parent.Parent.Enemies.Service)', 'require("./EnemiesService")')
                source = source.replace('require(script.Parent.Parent.Combat.Service)', 'require("./CombatService")')
                source = source.replace('require(script.Parent.Parent.Gathering.Service)', 'require("./GatheringService")')
                source = source.replace('require(script.Parent.Parent.Crafting.Service)', 'require("./CraftingService")')
                source = source.replace('require(script.Parent.Parent.Bosses.Service)', 'require("./BossesService")')
                source = source.replace('require(script.Parent.Parent.Ascension.Service)', 'require("./AscensionService")')
                source = source.replace('require(script.Parent.Parent.Mastery.Service)', 'require("./MasteryService")')
                source = source.replace('require(script.Parent.Parent.OfflineTraining.Service)', 'require("./OfflineTrainingService")')
                source = source.replace('require(script.Parent.Parent.PlayerHealth.Service)', 'require("./PlayerHealthService")')
                source = source.replace('require(script.Parent.GatheringSessions)', 'require("./CompositionGatheringSessions")')
                source = source.replace('require(script.Parent.TrainingSessions)', 'require("./CompositionTrainingSessions")')
                source = source.replace('require(script.Parent.CombatRewards)', 'require("./CompositionCombatRewards")')
                source = source.replace('require(script.Parent.EnemyCombat)', 'require("./CompositionEnemyCombat")')
                source = source.replace('require(script.Parent.PlayerEvents)', 'require("./CompositionPlayerEvents")')
                source = source.replace('require(script.Parent.ReadModel)', 'require("./CompositionReadModel")')
            target = temporary / f"{name}.luau"
            target.write_text(source, encoding="utf-8")
            adapted.append(str(target))
        subprocess.run([args.analyzer, *adapted], check=True, cwd=root)
        bundle = temporary / "behavior.luau"
        bundle.write_text("\n".join(wrappers), encoding="utf-8")
        subprocess.run([args.luau, str(bundle)], check=True, cwd=root)


if __name__ == "__main__":
    main()
