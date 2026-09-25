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
cp fixtures/consumer/authority.lock "$work/authority.before"
cp fixtures/consumer/inputs.lock "$work/native.before"
# Planning uses embedded supplied data, not cwd, PATH, Nix, or real layout dirs.
(cd "$work"; PATH= "$work/consumer") > "$work/actual"
python3 - "$work" <<'PY'
import json
import re
import sys
from pathlib import Path

work = Path(sys.argv[1])
authority = json.loads(work.joinpath('authority.before').read_bytes())
seed = json.loads(work.joinpath('native.before').read_bytes())
# B2's stable input set adds unused Auto, sharing the existing nixpkgs pin.
seed['nodes']['root']['inputs'] = {
    'default': 'nixpkgs', **seed['nodes']['root']['inputs'],
}
assert authority['nix'] == seed, 'conversion changed supplied pins'

# Keep the B1 golden body; B2 declares stable inputs with explicit flake kinds.
flake = Path('blueprint-nix-package/tests/sample.golden.nix').read_text()
flake = re.sub(r'"(nixpkgs|roc)"\.url = ("[^"]*");',
               r'"\1" = { url = \2; flake = true; };', flake)
flake = flake.replace('  inputs = {\n', '  inputs = {\n'
    '    "default" = { url = "github:NixOS/nixpkgs/nixos-unstable"; '
    'flake = true; };\n')
lock = json.dumps(authority['nix'], separators=(',', ':')) + '\n'
flake_header = b'# /consumer/work/generated/flake.nix\n'
lock_header = b'# /consumer/work/generated/flake.lock\n'
work.joinpath('expected').write_bytes(
    flake_header + flake.encode() + lock_header + lock.encode())

# Stage the consumer's actual output, not the expected/golden files.
actual = work.joinpath('actual').read_bytes()
assert actual.startswith(flake_header)
actual_flake, actual_lock = actual[len(flake_header):].split(lock_header)
work.joinpath('flake.nix').write_bytes(actual_flake)
work.joinpath('flake.lock').write_bytes(actual_lock)
work.joinpath('flake.before').write_bytes(actual_flake)
work.joinpath('lock.before').write_bytes(actual_lock)
PY
cmp "$work/expected" "$work/actual"
# Nix accepts the supplied pins without rewriting the derivative lock.
nix flake metadata --offline --no-update-lock-file --no-write-lock-file \
    "path:$work" >/dev/null
cmp "$work/lock.before" "$work/flake.lock"

# Alias and task entry share one real Nix environment, without lock mutation.
ref="path:$work#devShells.x86_64-linux"
alias_drv="$(nix eval --offline --no-update-lock-file --no-write-lock-file \
    --raw "$ref.ci.drvPath")"
env_drv="$(nix eval --offline --no-update-lock-file --no-write-lock-file \
    --raw "$ref.blueprint-env-base.drvPath")"
test "$alias_drv" = "$env_drv"
test -n "$alias_drv"
cmp "$work/lock.before" "$work/flake.lock"

# Evaluate the generated overlay scope with the real locked package set and
# a deterministic overlay. Only dev selects roc; base/ci must retain native git.
nix eval --offline --impure --json --expr "
  let
    source = builtins.getFlake \"path:$work\";
    rendered = (import $work/flake.nix).outputs {
      self = {};
      default = source.inputs.default;
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
cmp "$work/lock.before" "$work/flake.lock"

# The native missing-attribute failure must survive, not be filtered away.
python3 - "$work/flake.nix" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace(
    '"git"', '"blueprintMissingNativePackage"'))
PY
if nix eval --offline --no-update-lock-file --no-write-lock-file \
    --raw "$ref.ci.drvPath" \
    >"$work/missing.out" 2>"$work/missing.err"; then
    echo 'missing native package unexpectedly evaluated' >&2
    exit 1
fi
grep -F "attribute 'blueprintMissingNativePackage' missing" "$work/missing.err"
cmp "$work/lock.before" "$work/flake.lock"

# Evaluation-only target check: Linux headers must not vanish on Darwin.
python3 - "$work/flake.nix" "$work/flake.before" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[2]).read_text()
Path(sys.argv[1]).write_text(source.replace('"git"', '"linuxHeaders"'))
PY
if nix eval --offline --no-update-lock-file --no-write-lock-file --raw \
    "path:$work#devShells.aarch64-darwin.ci.drvPath" \
    >"$work/target.out" 2>"$work/target.err"; then
    echo 'unsupported native package unexpectedly evaluated' >&2
    exit 1
fi
grep -F 'not available on the requested hostPlatform' "$work/target.err"
cmp "$work/lock.before" "$work/flake.lock"
# Neither conversion, planning, nor real Nix evaluation mutates supplied data.
cmp "$work/authority.before" fixtures/consumer/authority.lock
cmp "$work/native.before" fixtures/consumer/inputs.lock
