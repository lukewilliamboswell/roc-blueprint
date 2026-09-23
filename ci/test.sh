#!/usr/bin/env bash
# Everything CI checks. Needs roc (or $ROC), zig 0.16 and nix.
set -euo pipefail
cd "$(dirname "$0")/.."
export ROC="${ROC:-roc}"

step() { printf '\n==> %s\n' "$*"; }

step "Formatting"
"$ROC" fmt --check ir platform cli Blueprint.roc

step "roc-blueprint-ir tests"
"$ROC" test ir/main.roc

step "Build the platform host"
zig build

step "Check Blueprint.roc"
"$ROC" check Blueprint.roc

step "CLI tests"
"$ROC" test cli/main.roc

step "Build the blueprint CLI"
"$ROC" build cli/main.roc --output=./blueprint

step "blueprint check"
./blueprint check

step "Generated flake and Blueprint.lock are up to date"
./blueprint gen
git diff --exit-code Blueprint.lock

step "ci dev shell builds"
nix develop path:.blueprint#ci -c git --version

step "Bundle ir and the platform against it"
scripts/bundle.sh platform

if [[ -f platform/ir-release ]]; then
	step "Bundle the platform against the pinned ir release"
	scripts/bundle.sh platform "$(cat platform/ir-release)"
fi
