#!/usr/bin/env bash
# Stand-in for the kai CLI. Runs Kaifile.roc to render .kai/flake.nix and
# keeps the lock at Kaifile.lock.
#
# Usage (from the project directory; installed as kai2):
#   kai.sh              render .kai/flake.nix and update Kaifile.lock
#   kai.sh shell [env]  render, then enter the dev shell (default: default)
set -euo pipefail

project_dir="$PWD"
command="${1:-}"
case "$command" in
    "" | shell) ;;
    *)
        echo "Unknown command: $command (expected: shell)" >&2
        exit 2
        ;;
esac
if [[ ! -f "$project_dir/Kaifile.roc" ]]; then
    echo "No Kaifile.roc in $project_dir" >&2
    exit 1
fi
kai_dir="$project_dir/.kai"
roc_bin="${ROC:-roc}"

mkdir -p "$kai_dir"
# Kaifile.roc is an app on the roc-blueprint platform, which prints the flake.
if ! "$roc_bin" "$project_dir/Kaifile.roc" > "$kai_dir/flake.nix.tmp"; then
    rm -f "$kai_dir/flake.nix.tmp"
    exit 1
fi
mv "$kai_dir/flake.nix.tmp" "$kai_dir/flake.nix"

if [[ -f "$project_dir/Kaifile.lock" ]]; then
    cp "$project_dir/Kaifile.lock" "$kai_dir/flake.lock"
fi
nix flake lock "path:$kai_dir"
cp "$kai_dir/flake.lock" "$project_dir/Kaifile.lock"

if [[ "$command" == shell ]]; then
    exec nix develop "path:$kai_dir#${2:-default}"
fi
