"""Run World's pure target-selection behavior checks.

World is Studio-context: its module body references Roblox instance types (Players, Model, BasePart,
...), so it is not standalone type-analyzable (same reason it is excluded from the composition
analyzer set). Its syntax is still covered by the whole-source luau-compile below; only the pure,
Roblox-free World.SelectAttackTarget is exercised behaviorally here.
"""

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
        "WorldService": root / "src/Server/World/Service.luau",
    }
    wrappers = ["local loaders = {}"]
    for name, path in modules.items():
        wrappers.append(f'loaders["{name}"] = function(script, game, require)\n{path.read_text(encoding="utf-8")}\nend')
    wrappers.append('''
local siblings = {}
for name in loaders do siblings[name] = name end
local loaded = {}
local function moduleRequire(name)
    assert(loaders[name], "Unresolved module: " .. tostring(name))
    if loaded[name] == nil then
        loaded[name] = loaders[name]({ Parent = siblings }, nil, moduleRequire)
    end
    return loaded[name]
end
local function runTests(require)
''')
    wrappers.append((root / "tests/World.spec.luau").read_text(encoding="utf-8"))
    wrappers.append("end\nrunTests(moduleRequire)\n")

    with tempfile.TemporaryDirectory(prefix=".world-", dir=root / "tests") as directory:
        temporary = Path(directory)
        assert temporary.resolve().is_relative_to(root / "tests")
        bundle = temporary / "behavior.luau"
        bundle.write_text("\n".join(wrappers), encoding="utf-8")
        subprocess.run([args.luau, str(bundle)], check=True, cwd=root)


if __name__ == "__main__":
    main()
