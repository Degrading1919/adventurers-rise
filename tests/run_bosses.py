"""Run server Boss participation/reward modules against Enemies, Combat, Economy, Inventory, and Ascension."""

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

    shared_modules = ["EnemyIds", "EquipmentSlots", "ItemDefinitions", "SkillIds", "ProgressionFlagIds", "AscensionIds"]
    modules = {
        "EnemyIds": root / "src/Shared/EnemyIds.luau",
        "EquipmentSlots": root / "src/Shared/EquipmentSlots.luau",
        "ItemDefinitions": root / "src/Shared/ItemDefinitions.luau",
        "SkillIds": root / "src/Shared/SkillIds.luau",
        "ProgressionFlagIds": root / "src/Shared/ProgressionFlagIds.luau",
        "AscensionIds": root / "src/Shared/AscensionIds.luau",
        "EnemyDefinitions": root / "src/Server/Enemies/Definitions.luau",
        "EnemiesService": root / "src/Server/Enemies/Service.luau",
        "SkillDefinitions": root / "src/Server/Skills/Definitions.luau",
        "SkillsService": root / "src/Server/Skills/Service.luau",
        "EquipmentService": root / "src/Server/Equipment/Service.luau",
        "CombatService": root / "src/Server/Combat/Service.luau",
        "InventoryService": root / "src/Server/Inventory/Service.luau",
        "ShopCatalog": root / "src/Server/Economy/ShopCatalog.luau",
        "EconomyService": root / "src/Server/Economy/Service.luau",
        "AscensionDefinitions": root / "src/Server/Ascension/Definitions.luau",
        "AscensionService": root / "src/Server/Ascension/Service.luau",
        "BossDefinitions": root / "src/Server/Bosses/Definitions.luau",
        "BossService": root / "src/Server/Bosses/Service.luau",
    }
    wrappers = ["local loaders = {}"]
    for name, path in modules.items():
        wrappers.append(f'loaders["{name}"] = function(script, game, require)\n{path.read_text(encoding="utf-8")}\nend')
    shared_table = ", ".join(f'{name} = "{name}"' for name in shared_modules)
    wrappers.append(f'''
local siblings = {{}}
for name in loaders do siblings[name] = name end
local scripts = {{
    EnemiesService = {{ Parent = {{ Definitions = "EnemyDefinitions" }} }},
    SkillsService = {{ Parent = {{ Definitions = "SkillDefinitions" }} }},
    EconomyService = {{ Parent = {{ ShopCatalog = "ShopCatalog" }} }},
    AscensionService = {{ Parent = {{ Definitions = "AscensionDefinitions" }} }},
    BossDefinitions = {{ Parent = {{ Parent = {{ Enemies = {{ Definitions = "EnemyDefinitions" }} }} }} }},
    BossService = {{ Parent = {{ Definitions = "BossDefinitions" }} }},
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
    wrappers.append((root / "tests/Bosses.spec.luau").read_text(encoding="utf-8"))
    wrappers.append("end\nrunTests(moduleRequire)\n")

    with tempfile.TemporaryDirectory(prefix=".bosses-", dir=root / "tests") as directory:
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
            if name == "EnemiesService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./EnemyDefinitions")')
            elif name == "SkillsService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./SkillDefinitions")')
            elif name == "EconomyService":
                source = source.replace('require(script.Parent.ShopCatalog)', 'require("./ShopCatalog")')
            elif name == "AscensionService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./AscensionDefinitions")')
            elif name == "BossDefinitions":
                source = source.replace('require(script.Parent.Parent.Enemies.Definitions)', 'require("./EnemyDefinitions")')
            elif name == "BossService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./BossDefinitions")')
            target = temporary / f"{name}.luau"
            target.write_text(source, encoding="utf-8")
            adapted.append(str(target))
        subprocess.run([args.analyzer, *adapted], check=True, cwd=root)
        bundle = temporary / "behavior.luau"
        bundle.write_text("\n".join(wrappers), encoding="utf-8")
        subprocess.run([args.luau, str(bundle)], check=True, cwd=root)


if __name__ == "__main__":
    main()
