"""Run the pure enemy movement/behaviour state-machine (World/EnemyAI) behaviour checks.

EnemyAI owns no Roblox instances -- it is a deterministic decision function -- so it is fully testable
headlessly. Its syntax is covered by the whole-source luau-compile below; the behaviour is exercised by
EnemyAI.spec against a tiny Vector3 stub, the same style used for the other extracted-pure modules.
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
        "EnemyAI": root / "src/Server/World/EnemyAI.luau",
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
    wrappers.append((root / "tests/EnemyAI.spec.luau").read_text(encoding="utf-8"))
    wrappers.append("end\nrunTests(moduleRequire)\n")

    with tempfile.TemporaryDirectory(prefix=".enemyai-", dir=root / "tests") as directory:
        temporary = Path(directory)
        assert temporary.resolve().is_relative_to(root / "tests")
        bundle = temporary / "behavior.luau"
        bundle.write_text("\n".join(wrappers), encoding="utf-8")
        subprocess.run([args.luau, str(bundle)], check=True, cwd=root)


if __name__ == "__main__":
    main()
