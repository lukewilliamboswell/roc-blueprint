#!/usr/bin/env bash
# Real Nix execution for imported task argv and noncommutative scoped overlays.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Reuse existing resolved fixture pins; do not update any repository lock.
mkdir -p "$WORK/pinned" "$WORK/composed" "$WORK/overlays"
cp "$ROOT/blueprint-nix/tests/sample.golden.nix" "$WORK/pinned/flake.nix"
cp "$ROOT/fixtures/consumer/inputs.lock" "$WORK/pinned/flake.lock"
python3 - "$ROOT" "$WORK" <<'PY'
import json
import os
from pathlib import Path
import sys

root, work = map(Path, sys.argv[1:])
lock = json.loads((root / 'fixtures/consumer/inputs.lock').read_text())
pin = lock['nodes']['nixpkgs']['locked']
assert pin['type'] == 'github'
pkgs_ref = f"github:{pin['owner']}/{pin['repo']}/{pin['rev']}"
platform = root / 'blueprint-platform/main.roc'
composed = work / 'composed'
source = (root / 'examples/composition/Blueprint.roc').read_text()
source = source.replace('../../blueprint-platform/main.roc',
                        os.path.relpath(platform, composed))
# The reusable module is unchanged. Supply the fixture's already-resolved set.
source = source.replace(
    'Name("composed"),',
    f'Name("composed"), Packages("default", From(NixPackages("{pkgs_ref}"))),',
)
(composed / 'Blueprint.roc').write_text(source)
(composed / 'ProjectTasks.roc').write_bytes(
    (root / 'examples/composition/ProjectTasks.roc').read_bytes())

project = work / 'overlays'
first = project / 'first'
patch = project / 'patch'
unused = project / 'unused'
for directory in (first, patch, unused):
    directory.mkdir()
(first / 'flake.nix').write_text('''{
  outputs = { self }: {
    overlays.default = final: prev: {
      fixtureTool = prev.writeShellScriptBin "fixture-tool" "printf 'base\\n'";
    };
  };
}
''')
(patch / 'flake.nix').write_text('''{
  outputs = { self }: {
    overlays.default = final: prev: {
      fixtureTool = prev.writeShellScriptBin "fixture-tool" ''
        printf 'patch:'
        exec ${prev.fixtureTool}/bin/fixture-tool
      '';
    };
  };
}
''')
(unused / 'flake.nix').write_text('{ outputs = _: throw "unused overlay evaluated"; }\n')
(project / 'Blueprint.roc').write_text(f'''app [config] {{ pf: platform "{os.path.relpath(platform, project)}" }}
config = [
    Name("overlay-execution"),
    Systems(["x86_64-linux"]),
    Packages("default", From(NixPackages("{pkgs_ref}"))),
    Overlay("first", "path:./first"),
    Overlay("patch", "path:./patch"),
    Overlay("unused", "path:./unused"),
    Environment("base", [Tools(["fixtureTool"]), Overlays(["first"])]),
    Environment("patched", [Extend("base"), Tools(["fixtureTool"]), Overlays(["first", "patch"])]),
    Environment("reverse", [Tools(["fixtureTool"]), Overlays(["patch", "first"])]),
    Environment("plain", [Tools(["fixtureTool"])]),
    Task("base", [Use("base"), Run(["fixture-tool"])]),
    Task("patched", [Use("patched"), Run(["fixture-tool"])]),
    Task("reverse", [Use("reverse"), Run(["fixture-tool"])]),
    Task("plain", [Use("plain"), Run(["fixture-tool"])]),
]
''')
PY

# Only explicit update resolves pins. The throwing unused overlay must remain
# unevaluated during both update and every selected request that follows.
for project in composed overlays; do
    (cd "$WORK/$project" && "$ROOT/blueprint" update)
    cp "$WORK/$project/Blueprint.lock" "$WORK/$project.lock.before"
    chmod a-w "$WORK/$project/Blueprint.lock"
done
(cd "$WORK/composed" && "$ROOT/blueprint" run args -- 'two words' '' '--literal') > "$WORK/args.out"
cmp "$WORK/composed.lock.before" "$WORK/composed/Blueprint.lock"
printf '%s\n' '["configured argument", "two words", "", "--literal"]' > "$WORK/args.expected"
cmp "$WORK/args.expected" "$WORK/args.out"

for task in base patched reverse; do
    (cd "$WORK/overlays" && "$ROOT/blueprint" run "$task") > "$WORK/$task.out"
    cmp "$WORK/overlays.lock.before" "$WORK/overlays/Blueprint.lock"
done
printf 'base\n' > "$WORK/base.expected"
printf 'patch:base\n' > "$WORK/patched.expected"
cmp "$WORK/base.expected" "$WORK/base.out"
cmp "$WORK/patched.expected" "$WORK/patched.out"
cmp "$WORK/base.expected" "$WORK/reverse.out"

# Declared but unselected overlays cannot supply this environment's package.
if (cd "$WORK/overlays" && "$ROOT/blueprint" run plain) > "$WORK/plain.out" 2> "$WORK/plain.err"; then
    echo 'unselected overlay unexpectedly supplied fixtureTool' >&2
    exit 1
fi
grep -qF "attribute 'fixtureTool' missing" "$WORK/plain.err"
cmp "$WORK/overlays.lock.before" "$WORK/overlays/Blueprint.lock"
# Stable input declarations keep lock identity across requests. Only outputs
# select/evaluate overlays; plain must import its tools with an empty stack.
python3 - "$WORK/overlays/.blueprint/flake.nix" <<'PY'
from pathlib import Path
import sys

outputs = Path(sys.argv[1]).read_text().split('  outputs =', 1)[1]
assert 'unused' not in outputs, 'unused overlay entered the requested closure'
assert 'overlays = [  ];' in outputs, 'plain selected an overlay stack'
assert '.overlays.default' not in outputs, 'plain selected a declared overlay'
PY
cmp "$ROOT/fixtures/consumer/inputs.lock" "$WORK/pinned/flake.lock"
echo 'B1 Nix: argv, scoped overlays, native failure, immutable locks passed'
