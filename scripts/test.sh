#!/usr/bin/env bash
# Everything CI checks. Needs roc (or $ROC), zig 0.16 and nix.
set -euo pipefail
cd "$(dirname "$0")/.."
export ROC="${ROC:-roc}"
ROOT="$PWD"

step() { printf '\n==> %s\n' "$*"; }

step "Formatting"
"$ROC" fmt --check ir platform cli examples fuzz

step "roc-blueprint-ir tests"
"$ROC" test ir/main.roc

step "Build the platform host"
(cd platform && zig build)

step "Check examples/Blueprint.roc"
"$ROC" check examples/Blueprint.roc

step "CLI tests"
"$ROC" test cli/main.roc

step "Build the blueprint CLI"
"$ROC" build cli/main.roc --output=./blueprint

step "blueprint against examples/Blueprint.roc"
(
	cd examples
	"$ROOT/blueprint" check
	"$ROOT/blueprint" tasks
	"$ROOT/blueprint" --help >/dev/null
	"$ROOT/blueprint" run --help | grep -q ci-hello
	"$ROOT/blueprint" run ci-hello
	"$ROOT/blueprint" run hello
)

step "Nix flake: blueprint builds with the pinned Roc"
nix build .#blueprint --no-link
nix develop . -c blueprint --version

step "Bundle ir and the platform against it"
scripts/bundle.sh platform

if [[ -f platform/ir-release ]]; then
	step "Bundle the platform against the pinned ir release"
	scripts/bundle.sh platform "$(cat platform/ir-release)"
fi

step "Fuzz smoke test"
scripts/fuzz.sh
