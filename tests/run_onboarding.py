"""Run the Onboarding ModuleScript against minimal trusted PlayerData/Skills/Economy doubles."""

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

    shared_modules = ["SkillIds", "EnemyIds", "AscensionIds", "ProgressionFlagIds"]
    modules = {name: root / f"src/Shared/{name}.luau" for name in shared_modules}
    modules.update({
        "OnboardingDefinitions": root / "src/Server/Onboarding/Definitions.luau",
        "OnboardingService": root / "src/Server/Onboarding/Service.luau",
    })

    wrappers = ["local loaders = {}"]
    for name, path in modules.items():
        wrappers.append(f'loaders["{name}"] = function(script, game, require)\n{path.read_text(encoding="utf-8")}\nend')
    shared_table = ", ".join(f'{name} = "{name}"' for name in shared_modules)
    wrappers.append(f'''
local siblings = {{}}
for name in loaders do siblings[name] = name end
local scripts = {{
    OnboardingService = {{ Parent = {{ Definitions = "OnboardingDefinitions" }} }},
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
    wrappers.append((root / "tests/Onboarding.spec.luau").read_text(encoding="utf-8"))
    wrappers.append("end\nrunTests(moduleRequire)\n")

    with tempfile.TemporaryDirectory(prefix=".onboarding-", dir=root / "tests") as directory:
        temporary = Path(directory)
        assert temporary.resolve().is_relative_to(root / "tests")
        adapted = []
        for name, path in modules.items():
            source = path.read_text(encoding="utf-8")
            source = source.replace('local Shared = game:GetService("ReplicatedStorage").Shared\n', '')
            for shared_name in shared_modules:
                source = source.replace(f'require(Shared.{shared_name})', f'require("./{shared_name}")')
                source = source.replace(f'require(game:GetService("ReplicatedStorage").Shared.{shared_name})', f'require("./{shared_name}")')
            if name == "OnboardingService":
                source = source.replace('require(script.Parent.Definitions)', 'require("./OnboardingDefinitions")')
            target = temporary / f"{name}.luau"
            target.write_text(source, encoding="utf-8")
            adapted.append(str(target))
        subprocess.run([args.analyzer, *adapted], check=True, cwd=root)
        bundle = temporary / "behavior.luau"
        bundle.write_text("\n".join(wrappers), encoding="utf-8")
        subprocess.run([args.luau, str(bundle)], check=True, cwd=root)


if __name__ == "__main__":
    main()
