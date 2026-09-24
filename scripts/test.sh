#!/usr/bin/env bash
# Everything CI checks. Needs roc (or $ROC), zig 0.16 and nix.
set -euo pipefail
cd "$(dirname "$0")/.."
export ROC="${ROC:-roc}"
ROOT="$PWD"

step() { printf '\n==> %s\n' "$*"; }

step "Formatting"
"$ROC" fmt --check blueprint-ir-package blueprint-ir-platform blueprint-nix-package blueprint-cli fixtures examples

step "roc-blueprint-ir tests"
"$ROC" test blueprint-ir-package/main.roc

step "Build the platform host"
(cd blueprint-ir-platform && zig build)

step "Compile-time configuration validation"
scripts/test-config.sh
"$ROC" check examples/all-settings/Blueprint.roc

step "CLI tests"
scripts/prepare-basic-cli.sh
"$ROC" test blueprint-cli/main.roc

step "Build the blueprint CLI"
"$ROC" build blueprint-cli/main.roc --output=./blueprint

step "Independent library consumer"
scripts/test-consumer.sh

step "CLI argument and validation regressions"
python3 scripts/test-cli.py

step "blueprint against examples/all-settings/Blueprint.roc"
(
	cd examples/all-settings
	"$ROOT/blueprint" check
	"$ROOT/blueprint" tasks
	"$ROOT/blueprint" --help >/dev/null
	"$ROOT/blueprint" run --help | grep -q ci-hello
	"$ROOT/blueprint" run ci-hello
	"$ROOT/blueprint" run hello
)

step "Golden flakes parse as Nix"
for f in blueprint-nix-package/tests/*.golden.nix; do nix-instantiate --parse "$f" >/dev/null; done

step "Extensions example: the platform emits them, this blueprint refuses them clearly"
"$ROC" check examples/extensions/Blueprint.roc
(cd examples/extensions && "$ROC" Blueprint.roc | grep -qF '(kind "services")')
out="$(cd examples/extensions && "$ROOT/blueprint" check 2>&1 || true)"
grep -qF "needs features: extensions" <<<"$out" || { echo "expected a 'needs features' error, got: $out" >&2; exit 1; }

step "Nix flake: blueprint builds with the pinned Roc"
nix build .#blueprint --no-link
nix develop . -c blueprint --version

step "Nix flake: every system's outputs evaluate (no build)"
for system in x86_64-linux aarch64-darwin; do
	nix eval --raw ".#packages.$system.blueprint.drvPath" >/dev/null
	nix eval --raw ".#devShells.$system.default.drvPath" >/dev/null
done

step "Bundle ir and the platform against it"
scripts/bundle.sh platform

if [[ -f blueprint-ir-platform/ir-release ]]; then
	step "Bundle the platform against the pinned ir release"
	scripts/bundle.sh platform "$(cat blueprint-ir-platform/ir-release)"
fi

step "Fuzz smoke test"
scripts/fuzz.sh
