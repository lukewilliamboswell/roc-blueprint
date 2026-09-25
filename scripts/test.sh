#!/usr/bin/env bash
# Everything CI checks. Needs roc (or $ROC), zig 0.16 and nix.
set -euo pipefail
cd "$(dirname "$0")/.."
export ROC="${ROC:-roc}"
ROOT="$PWD"

step() { printf '\n==> %s\n' "$*"; }

step "Formatting"
"$ROC" fmt --check blueprint-core blueprint-platform blueprint-nix blueprint-cli fixtures examples

step "The CLI reaches providers only through the Provider contract"
# docs/architecture.adoc invariant 7: one selection site, no provider internals.
imports="$(grep -E '^import nix\.' blueprint-cli/main.roc)"
refs="$(grep -oE '\bNix[A-Za-z]*\.|\bLocks\.' blueprint-cli/main.roc | sort | uniq -c | tr -s ' ')"
if [[ "$imports" != "import nix.NixProvider" || "$refs" != " 1 NixProvider." ]]; then
	echo "blueprint-cli/main.roc must use only provider.* (found: $imports / $refs)" >&2
	exit 1
fi
if grep -n '"nix"' blueprint-cli/main.roc; then
	echo "blueprint-cli/main.roc must not run provider tools itself" >&2
	exit 1
fi

step "roc-blueprint-core tests"
"$ROC" test blueprint-core/main.roc

step "Build the platform host"
(cd blueprint-platform && zig build)

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

step "Explicit update source safety and concurrent authority publication"
python3 scripts/test-update.py

step "blueprint against examples/all-settings/Blueprint.roc"
(
	cd examples/all-settings
	"$ROOT/blueprint" check
	"$ROOT/blueprint" tasks
	"$ROOT/blueprint" --help >/dev/null
	"$ROOT/blueprint" run --help | grep -q ci-hello
	"$ROOT/blueprint" update
	"$ROOT/blueprint" run ci-hello
	"$ROOT/blueprint" run hello
)

step "B1 composed tasks and scoped overlays through real Nix"
scripts/test-b1.sh

step "B2 sandboxed artifacts, isolation, sources and immutable locks"
python3 scripts/test-b2.py

step "B3 ordered workflows, failure propagation and fresh build operations"
python3 scripts/test-b3.py

step "Golden flakes parse as Nix"
for f in blueprint-nix/tests/*.golden.nix; do nix-instantiate --parse "$f" >/dev/null; done

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

step "Bundle core and the platform against it"
scripts/bundle.sh platform

if [[ -f blueprint-platform/core-release ]]; then
	step "Bundle the platform against the pinned core release"
	scripts/bundle.sh platform "$(cat blueprint-platform/core-release)"
fi

step "Fuzz smoke test"
scripts/fuzz.sh
