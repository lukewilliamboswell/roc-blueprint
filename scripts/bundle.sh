#!/usr/bin/env bash
# Bundle roc-blueprint-ir and the roc-blueprint platform into dist/.
#
#   scripts/bundle.sh [IR_BASE_URL]
#
# `roc bundle` only packs files under the entry point's directory, so the
# platform's `ir: "../ir/main.roc"` dependency can't be bundled as-is. We
# bundle ir first, then stage a copy of the platform whose `ir:` points at
# IR_BASE_URL/<ir-hash>.tar.zst and bundle that.
#
# With no IR_BASE_URL the ir bundle is served from localhost, and an app is
# built against the platform bundle as a smoke test. For a release, pass the
# release download URL, e.g.
#   https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.1.0-ir
# (the ir bundle needs its own release; see .github/workflows/release.yml).
#
# Environment: ROC (default: roc), PORT (default: 8765).
set -euo pipefail

ROC="${ROC:-roc}"
PORT="${PORT:-8765}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGE="$ROOT/.bundle-stage"
IR_BASE_URL="${1:-}"

cleanup() {
	rm -rf "$STAGE"
	if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

# The bundler renames its temp file into --output-dir, so dist/ must be on the
# same filesystem as the working directory (it is: both are in the repo).
rm -rf "$DIST" "$STAGE"
mkdir -p "$DIST" "$STAGE"

bundle() { # bundle <dir> <files...>; prints the created archive name
	local dir="$1"
	shift
	(cd "$dir" && "$ROC" bundle "$@" --output-dir "$DIST") | sed -n 's#^Created: .*/##p'
}

echo "==> Building libhost.a"
(cd "$ROOT" && zig build)

echo "==> Checking vendored linker inputs"
(cd "$ROOT/platform/targets" && sha256sum --quiet -c x64musl.sha256)

echo "==> Bundling roc-blueprint-ir"
IR_BUNDLE="$(bundle "$ROOT/ir" main.roc Ir.roc Sexpr.roc)"
echo "    $IR_BUNDLE"

if [[ -z "$IR_BASE_URL" ]]; then
	# Serve with the same versioned layout as a release (<tag>/ and <tag>-ir/),
	# so the smoke test resolves packages the way a release does.
	SERVE="$STAGE/serve"
	mkdir -p "$SERVE/0.0.1-smoke" "$SERVE/0.0.1-smoke-ir"
	cp "$DIST/$IR_BUNDLE" "$SERVE/0.0.1-smoke-ir/"
	(cd "$SERVE" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
	SERVER_PID=$!
	PF_BASE_URL="http://localhost:$PORT/0.0.1-smoke"
	IR_BASE_URL="$PF_BASE_URL-ir"
	for _ in $(seq 50); do curl -sf -o /dev/null "$IR_BASE_URL/$IR_BUNDLE" && break; sleep 0.1; done
	SMOKE_TEST=1
fi

echo "==> Bundling roc-blueprint (ir: $IR_BASE_URL/$IR_BUNDLE)"
mkdir -p "$STAGE/platform/targets/x64musl"
cp "$ROOT"/platform/*.roc "$STAGE/platform/"
cp "$ROOT"/platform/targets/x64musl/{crt1.o,libhost.a,libc.a,libzigc.a,libcompiler_rt.a} "$STAGE/platform/targets/x64musl/"
sed -i "s#\"../ir/main.roc\"#\"$IR_BASE_URL/$IR_BUNDLE\"#" "$STAGE/platform/main.roc"
grep -q "$IR_BUNDLE" "$STAGE/platform/main.roc" || { echo "failed to rewrite the ir dependency" >&2; exit 1; }
PF_BUNDLE="$(cd "$STAGE/platform" && bundle . main.roc $(ls *.roc | grep -v '^main.roc$') targets/x64musl/*)"
echo "    $PF_BUNDLE"

if [[ -n "${SMOKE_TEST:-}" ]]; then
	echo "==> Smoke test: running Blueprint.roc against the platform bundle"
	cp "$DIST/$PF_BUNDLE" "$SERVE/0.0.1-smoke/"
	mkdir -p "$STAGE/app"
	sed "s#platform \"platform/main.roc\"#platform \"$PF_BASE_URL/$PF_BUNDLE\"#" "$ROOT/Blueprint.roc" >"$STAGE/app/Blueprint.roc"
	(cd "$STAGE/app" && "$ROC" Blueprint.roc) | grep -q '(version 1)'
	echo "    ok"
fi

cat >"$DIST/bundles.txt" <<EOF
roc-blueprint-ir $IR_BUNDLE
roc-blueprint $PF_BUNDLE
EOF
echo "==> Wrote $DIST/bundles.txt"
