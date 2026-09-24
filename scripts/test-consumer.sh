#!/usr/bin/env bash
# Compile an independent consumer and assert its generated files byte-for-byte.
set -euo pipefail
cd "$(dirname "$0")/.."
ROC="${ROC:-roc}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$ROC" check fixtures/consumer/main.roc
"$ROC" test fixtures/consumer/main.roc
"$ROC" build fixtures/consumer/main.roc --output="$work/consumer"
"$work/consumer" > "$work/actual"
{
    printf '# /consumer/work/generated/flake.nix\n'
    cat blueprint-nix-package/tests/sample.golden.nix
    printf '# /consumer/work/generated/flake.lock\n'
    cat fixtures/consumer/inputs.lock
} > "$work/expected"
cmp "$work/expected" "$work/actual"
# Nix accepts the supplied pins without rewriting the derivative lock.
cp blueprint-nix-package/tests/sample.golden.nix "$work/flake.nix"
cp fixtures/consumer/inputs.lock "$work/flake.lock"
nix flake metadata --offline --no-update-lock-file "path:$work" >/dev/null
cmp fixtures/consumer/inputs.lock "$work/flake.lock"

# Alias and task entry share one real Nix environment, without lock mutation.
ref="path:$work#devShells.x86_64-linux"
alias_drv="$(nix eval --offline --no-update-lock-file --raw "$ref.ci.drvPath")"
env_drv="$(nix eval --offline --no-update-lock-file --raw \
    "$ref.blueprint-env-base.drvPath")"
test "$alias_drv" = "$env_drv"
test -n "$alias_drv"
cmp fixtures/consumer/inputs.lock "$work/flake.lock"

# Evaluate the generated overlay scope with the real locked package set and
# a deterministic overlay. Only dev selects roc; base/ci must retain native git.
nix eval --offline --impure --json --expr "
  let
    source = builtins.getFlake \"path:$work\";
    rendered = (import $work/flake.nix).outputs {
      self = {};
      nixpkgs = source.inputs.nixpkgs;
      roc.overlays.default = final: prev: { git = prev.hello; };
    };
    shells = rendered.devShells.x86_64-linux;
    names = shell: map (p: p.pname or p.name) shell.nativeBuildInputs;
  in { base = names shells.ci; dev = names shells.default; }
" > "$work/scope.json"
python3 - "$work/scope.json" <<'PY'
import json, sys
from pathlib import Path
scope = json.loads(Path(sys.argv[1]).read_text())
assert 'git' in scope['base'] and 'hello' not in scope['base'], scope
assert 'hello' in scope['dev'] and 'git' not in scope['dev'], scope
PY
cmp fixtures/consumer/inputs.lock "$work/flake.lock"

# The native missing-attribute failure must survive, not be filtered away.
python3 - "$work/flake.nix" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace('"git"', '"blueprintMissingNativePackage"'))
PY
if nix eval --offline --no-update-lock-file --raw "$ref.ci.drvPath" \
    >"$work/missing.out" 2>"$work/missing.err"; then
    echo 'missing native package unexpectedly evaluated' >&2
    exit 1
fi
grep -F "attribute 'blueprintMissingNativePackage' missing" "$work/missing.err"
cmp fixtures/consumer/inputs.lock "$work/flake.lock"

# Evaluation-only target check: Linux headers must not vanish on Darwin.
python3 - "$work/flake.nix" <<'PY'
from pathlib import Path
import sys
source = Path('blueprint-nix-package/tests/sample.golden.nix').read_text()
Path(sys.argv[1]).write_text(source.replace('"git"', '"linuxHeaders"'))
PY
if nix eval --offline --no-update-lock-file --raw \
    "path:$work#devShells.aarch64-darwin.ci.drvPath" \
    >"$work/target.out" 2>"$work/target.err"; then
    echo 'unsupported native package unexpectedly evaluated' >&2
    exit 1
fi
grep -F 'not available on the requested hostPlatform' "$work/target.err"
cmp fixtures/consumer/inputs.lock "$work/flake.lock"
