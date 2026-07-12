#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

ROC_BIN="${ROC:-roc}"
tmp_base="${ROC_BLUEPRINT_TMPDIR:-${TMPDIR:-/tmp}/roc-blueprint}"
work_dir="$tmp_base/nix-example"

rm -rf "$work_dir"
mkdir -p "$work_dir"

"$ROC_BIN" examples/dev-shell.roc > "$work_dir/flake.nix"
"$ROC_BIN" examples/dev-shell.roc > "$work_dir/flake.second.nix"

cmp examples/dev-shell.golden.nix "$work_dir/flake.nix"
cmp "$work_dir/flake.nix" "$work_dir/flake.second.nix"

cp flake.lock "$work_dir/flake.lock"
nix flake lock "$work_dir"
cmp flake.lock "$work_dir/flake.lock"
nix flake check "$work_dir" --no-write-lock-file
nix develop "$work_dir#default" --command rustc --version
