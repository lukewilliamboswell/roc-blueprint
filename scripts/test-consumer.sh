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
