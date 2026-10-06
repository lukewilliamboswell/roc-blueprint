#!/usr/bin/env bash
# Everything CI checks. Needs roc (or $ROC), zig 0.16, nix and curl.
set -euo pipefail
cd "$(dirname "$0")/.."
export ROC="${ROC:-roc}"
ROOT="$PWD"

step() { printf '\n==> %s\n' "$*"; }

step "Formatting"
"$ROC" fmt --check blueprint-core blueprint-platform blueprint-nix blueprint-cli fixtures examples scripts

step "No binary linker input is tracked"
# They are fetched by content from the release in link-inputs.lock.json.
tracked="$(git ls-files -- '*.o' '*.a' '*.lib')"
if [[ -n "$tracked" ]]; then
	printf 'object files, archives and import libraries must not be committed:\n%s\n' "$tracked" >&2
	exit 1
fi

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

step "The fetched compiler comes from the locked roc-overlay revision"
python3 - <<'PY'
import json, re, urllib.parse
locked = json.load(open("flake.lock"))["nodes"]["roc-overlay"]["locked"]
expected = "github:{owner}/{repo}/{rev}?narHash={hash}".format(
    hash=urllib.parse.quote(locked["narHash"], safe="-"), **locked)
actual = re.search(r'roc_overlay = "([^"]+)"', open("blueprint-nix/NixProvider.roc").read()).group(1)
assert actual == expected, f"update roc_overlay in NixProvider.roc to {expected}"
PY

step "roc-blueprint-core tests"
"$ROC" test blueprint-core/main.roc

step "Repository script tests"
"$ROC" test scripts/link_inputs.roc

step "Fetch and verify the platform's linker inputs"
# Unconditional: a restored cache is storage, not authority. The archive is
# rehashed against link-inputs.lock.json whether or not it was downloaded.
"$ROC" scripts/link_inputs.roc fetch

step "Build the platform host"
(cd blueprint-platform && zig build)

step "Compile-time configuration validation"
scripts/test-config.sh
"$ROC" check examples/all-settings/Blueprint.roc

step "CLI tests"
"$ROC" test blueprint-cli/main.roc

step "Build the blueprint CLI"
"$ROC" build blueprint-cli/main.roc --output=./blueprint

step "Independent library consumer"
scripts/test-consumer.sh

step "CLI argument and validation regressions"
python3 scripts/test-cli.py

step "Explicit update source safety and concurrent authority publication"
python3 scripts/test-update.py

step "Build snapshots, mode normalization and the isolation witness"
python3 scripts/test-snapshot.py

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

step "System-scoped tools through real Nix on Linux and macOS"
scripts/test-system-tools.sh

step "Renamed commands through real Nix"
scripts/test-command.sh

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

# The pinned core release is checked by release.yml when a platform release is
# tagged. A change that adds a Spec field cannot pass that check until a core
# release containing the field is published, so it is not a per-commit gate.

step "Fuzz smoke test"
scripts/fuzz.sh
