#!/usr/bin/env bash
# Real Nix execution for imported task argv and noncommutative scoped overlays.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Reuse existing resolved fixture pins; do not update any repository lock.
mkdir -p "$WORK/pinned" "$WORK/composed" "$WORK/overlays"
cp "$ROOT/blueprint-nix-package/tests/sample.golden.nix" "$WORK/pinned/flake.nix"
cp "$ROOT/fixtures/consumer/inputs.lock" "$WORK/pinned/flake.lock"
PKGS="$(nix eval --offline --impure --raw --expr "(builtins.getFlake \"path:$WORK/pinned\").inputs.nixpkgs.outPath")"
python3 - "$ROOT" "$WORK" "$PKGS" <<'PY'
import os
from pathlib import Path
import sys

root, work, pkgs = map(Path, sys.argv[1:])
platform = root / 'blueprint-ir-platform/main.roc'
composed = work / 'composed'
source = (root / 'examples/composition/Blueprint.roc').read_text()
source = source.replace('../../blueprint-ir-platform/main.roc',
                        os.path.relpath(platform, composed))
# The reusable module is unchanged. Supply the fixture's already-resolved set.
source = source.replace('Name("composed"),',
                        f'Name("composed"), Packages("default", From(NixPackages("path:{pkgs}"))),')
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
    Packages("default", From(NixPackages("path:{pkgs}"))),
    Overlay("first", "path:{first}"),
    Overlay("patch", "path:{patch}"),
    Overlay("unused", "path:{unused}"),
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

(cd "$WORK/composed" && "$ROOT/blueprint" run args -- 'two words' '' '--literal') > "$WORK/args.out"
printf '%s\n' '["configured argument", "two words", "", "--literal"]' > "$WORK/args.expected"
cmp "$WORK/args.expected" "$WORK/args.out"

for task in base patched reverse; do
    (cd "$WORK/overlays" && "$ROOT/blueprint" run "$task") > "$WORK/$task.out"
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
if grep -qF 'unused' "$WORK/overlays/.blueprint/flake.nix"; then
    echo 'unused overlay was emitted into the requested closure' >&2
    exit 1
fi
cmp "$ROOT/fixtures/consumer/inputs.lock" "$WORK/pinned/flake.lock"
echo 'B1 real Nix: composed argv bytes, ordered/inherited/scoped overlays and native failure passed'
