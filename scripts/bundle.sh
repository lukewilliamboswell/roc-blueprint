#!/usr/bin/env bash
# Bundle roc-blueprint-ir or the roc-blueprint platform into dist/.
#
#   scripts/bundle.sh ir
#       Bundle the ir package.
#
#   scripts/bundle.sh platform [IR_URL]
#       Bundle the platform with its `ir` dependency pointing at IR_URL, a
#       published roc-blueprint-ir bundle (a release uses blueprint-ir-platform/ir-release).
#       With no IR_URL, the local blueprint-ir-package/ is bundled and served from localhost.
#
# The two have independent releases (tags `ir-X.Y.Z` and `X.Y.Z`). They must
# live under different tags: Roc identifies a package by its URL minus the
# version and hash, so two bundles under one tag look like one package with
# two hashes.
#
# `roc bundle` only packs files below the entry point's directory, so the
# platform's development dependency `ir: "../blueprint-ir-package/main.roc"` can't be bundled
# as-is; a staged copy of the platform gets `ir: IR_URL` instead.
#
# Every platform bundle is smoke-tested: it is served from localhost with a
# release-like versioned path, and examples/all-settings/Blueprint.roc is run against it.
#
# Environment: ROC (default: roc), PORT (default: 8765).
set -euo pipefail

ROC="${ROC:-roc}"
PORT="${PORT:-8765}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGE="$ROOT/.bundle-stage"
WHAT="${1:-}"
IR_URL="${2:-}"

cleanup() {
	rm -rf "$STAGE"
	if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

# The bundler renames its temp file into --output-dir, so dist/ must be on the
# same filesystem as the working directory (it is: both are in the repo).
rm -rf "$STAGE"
mkdir -p "$DIST" "$STAGE/serve"

bundle() { # bundle <dir> <files...>; prints the created archive name
	local dir="$1"
	shift
	(cd "$dir" && "$ROC" bundle "$@" --output-dir "$DIST") | sed -n 's#^Created: .*/##p'
}

bundle_ir() {
	echo "==> Bundling roc-blueprint-ir" >&2
	local name
	name="$(bundle "$ROOT/blueprint-ir-package" main.roc Ir.roc Sexpr.roc Value.roc)"
	echo "    $name" >&2
	echo "roc-blueprint-ir $name" >>"$DIST/bundles.txt"
	echo "$name"
}

serve() {
	(cd "$STAGE/serve" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
	SERVER_PID=$!
	for _ in $(seq 50); do curl -sf -o /dev/null "http://localhost:$PORT/" && return; sleep 0.1; done
	echo "localhost server did not start" >&2
	exit 1
}

case "$WHAT" in
ir)
	rm -f "$DIST/bundles.txt"
	bundle_ir >/dev/null
	;;
platform)
	rm -f "$DIST/bundles.txt"
	serve
	if [[ -z "$IR_URL" ]]; then
		ir_bundle="$(bundle_ir)"
		mkdir -p "$STAGE/serve/0.0.1-smoke-ir"
		cp "$DIST/$ir_bundle" "$STAGE/serve/0.0.1-smoke-ir/"
		IR_URL="http://localhost:$PORT/0.0.1-smoke-ir/$ir_bundle"
	fi

	echo "==> Building libhost.a"
	(cd "$ROOT/blueprint-ir-platform" && zig build)

	echo "==> Checking vendored linker inputs"
	(cd "$ROOT/blueprint-ir-platform/targets" && sha256sum --quiet -c x64musl.sha256)

	echo "==> Bundling roc-blueprint (ir: $IR_URL)"
	mkdir -p "$STAGE/platform/targets/x64musl"
	cp "$ROOT"/blueprint-ir-platform/*.roc "$STAGE/platform/"
	cp "$ROOT"/blueprint-ir-platform/targets/x64musl/{crt1.o,libhost.a,libc.a,libzigc.a,libcompiler_rt.a} "$STAGE/platform/targets/x64musl/"
	sed -i "s#\"../blueprint-ir-package/main.roc\"#\"$IR_URL\"#" "$STAGE/platform/main.roc"
	grep -qF "\"$IR_URL\"" "$STAGE/platform/main.roc" || { echo "failed to rewrite the ir dependency" >&2; exit 1; }
	pf_bundle="$(cd "$STAGE/platform" && bundle . main.roc $(ls *.roc | grep -v '^main.roc$') targets/x64musl/*)"
	echo "    $pf_bundle"
	echo "roc-blueprint $pf_bundle" >>"$DIST/bundles.txt"

	echo "==> Smoke test: running Blueprint.roc against the platform bundle"
	mkdir -p "$STAGE/serve/0.0.1-smoke" "$STAGE/app"
	cp "$DIST/$pf_bundle" "$STAGE/serve/0.0.1-smoke/"
	sed "s#platform \"../../blueprint-ir-platform/main.roc\"#platform \"http://localhost:$PORT/0.0.1-smoke/$pf_bundle\"#" "$ROOT/examples/all-settings/Blueprint.roc" >"$STAGE/app/Blueprint.roc"
	(cd "$STAGE/app" && "$ROC" Blueprint.roc) | grep -qF '(format ('
	echo "    ok"
	;;
*)
	echo "usage: scripts/bundle.sh ir | platform [IR_URL]" >&2
	exit 2
	;;
esac

echo "==> Wrote $DIST/bundles.txt"
cat "$DIST/bundles.txt"
