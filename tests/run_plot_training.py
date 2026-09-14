"""Run Plot and training ModuleScripts against a minimal trusted PlayerData boundary."""

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

    modules = {
        "SkillIds": root / "src/Shared/SkillIds.luau",
        "PlotSockets": root / "src/Shared/PlotSockets.luau",
        "EquipmentSlots": root / "src/Shared/EquipmentSlots.luau",
        "ItemDefinitions": root / "src/Shared/ItemDefinitions.luau",
        "ShopCatalog": root / "src/Server/Economy/ShopCatalog.luau",
        "EconomyService": root / "src/Server/Economy/Service.luau",
        "SkillDefinitions": root / "src/Server/Skills/Definitions.luau",
        "SkillsService": root / "src/Server/Skills/Service.luau",
        "StationDefinitions": root / "src/Server/Plots/StationDefinitions.luau",
        "PlotsService": root / "src/Server/Plots/Service.luau",
    }
    wrappers = ["local loaders = {}"]
    for name, path in modules.items():
        wrappers.append(f'loaders["{name}"] = function(script, game, require)\n{path.read_text(encoding="utf-8")}\nend')
    wrappers.append('''
local siblings = {}
for name in loaders do siblings[name] = name end
local scripts = {
    EconomyService = { Parent = { ShopCatalog = "ShopCatalog" } },
    SkillsService = { Parent = { Definitions = "SkillDefinitions" } },
    PlotsService = { Parent = { StationDefinitions = "StationDefinitions", Parent = { Economy = { Service = "EconomyService" } } } },
}
local fakeGame = {
    GetService = function(_, name)
        assert(name == "ReplicatedStorage", "Unexpected module service: " .. name)
        return { Shared = { SkillIds = "SkillIds", PlotSockets = "PlotSockets", EquipmentSlots = "EquipmentSlots", ItemDefinitions = "ItemDefinitions" } }
    end,
}
local loaded = {}
local function moduleRequire(name)
    assert(loaders[name], "Unresolved module: " .. tostring(name))
    if loaded[name] == nil then
        loaded[name] = loaders[name](scripts[name] or { Parent = siblings }, fakeGame, moduleRequire)
    end
    return loaded[name]
end
local function runTests(require)
''')
    wrappers.append((root / "tests/PlotTraining.spec.luau").read_text(encoding="utf-8"))
    wrappers.append("end\nrunTests(moduleRequire)\n")

    with tempfile.TemporaryDirectory(prefix=".plot-training-", dir=root / "tests") as directory:
        temporary = Path(directory)
        assert temporary.resolve().is_relative_to(root / "tests")
        adapted = []
        for name, path in modules.items():
            source = path.read_text(encoding="utf-8")
            source = source.replace('local ReplicatedStorage = game:GetService("ReplicatedStorage")\nlocal Shared = ReplicatedStorage.Shared\n', '')
            source = source.replace('local Shared = game:GetService("ReplicatedStorage").Shared\n', '')
            source = source.replace('require(Shared.SkillIds)', 'require("./SkillIds")')
            source = source.replace('require(Shared.PlotSockets)', 'require("./PlotSockets")')
            source = source.replace('require(Shared.ItemDefinitions)', 'require("./ItemDefinitions")')
            source = source.replace('require(script.Parent.ShopCatalog)', 'require("./ShopCatalog")')
            source = source.replace('require(script.Parent.Definitions)', 'require("./SkillDefinitions")')
            source = source.replace('require(script.Parent.StationDefinitions)', 'require("./StationDefinitions")')
            source = source.replace('require(script.Parent.Parent.Economy.Service)', 'require("./EconomyService")')
            source = source.replace('require(game:GetService("ReplicatedStorage").Shared.SkillIds)', 'require("./SkillIds")')
            source = source.replace('require(game:GetService("ReplicatedStorage").Shared.EquipmentSlots)', 'require("./EquipmentSlots")')
            target = temporary / f"{name}.luau"
            target.write_text(source, encoding="utf-8")
            adapted.append(str(target))
        subprocess.run([args.analyzer, *adapted], check=True, cwd=root)
        bundle = temporary / "behavior.luau"
        bundle.write_text("\n".join(wrappers), encoding="utf-8")
        subprocess.run([args.luau, str(bundle)], check=True, cwd=root)


if __name__ == "__main__":
    main()
