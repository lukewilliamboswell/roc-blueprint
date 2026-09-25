#!/usr/bin/env bash
# Bundle roc-blueprint-core or the roc-blueprint platform into dist/.
#
#   scripts/bundle.sh core
#       Bundle the core package.
#
#   scripts/bundle.sh platform [CORE_URL]
#       Bundle the platform with its `core` dependency pointing at CORE_URL, a
#       published roc-blueprint-core bundle (a release uses blueprint-platform/core-release).
#       With no CORE_URL, the local blueprint-core/ is bundled and served from localhost.
#
# The two have independent releases (tags `core-X.Y.Z` and `X.Y.Z`). They must
# live under different tags: Roc identifies a package by its URL minus the
# version and hash, so two bundles under one tag look like one package with
# two hashes.
#
# `roc bundle` only packs files below the entry point's directory, so the
# platform's development dependency `core: "../blueprint-core/main.roc"` can't be bundled
# as-is; a staged copy of the platform gets `core: CORE_URL` instead.
#
# Every platform bundle is smoke-tested: it is served from localhost with a
# release-like versioned path, valid/invalid configs are checked, and
# examples/all-settings/Blueprint.roc is run against it.
#
# Environment: ROC (default: roc), PORT (default: 8765).
set -euo pipefail

ROC="${ROC:-roc}"
PORT="${PORT:-8765}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
STAGE="$ROOT/.bundle-stage"
WHAT="${1:-}"
CORE_URL="${2:-}"

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

bundle_core() {
	echo "==> Bundling roc-blueprint-core" >&2
	local name
	name="$(bundle "$ROOT/blueprint-core" main.roc Spec.roc Project.roc Request.roc Steps.roc Layout.roc Sexpr.roc Value.roc Provider.roc Lock.roc Tree.roc)"
	echo "    $name" >&2
	echo "roc-blueprint-core $name" >>"$DIST/bundles.txt"
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
core)
	rm -f "$DIST/bundles.txt"
	bundle_core >/dev/null
	;;
platform)
	rm -f "$DIST/bundles.txt"
	serve
	if [[ -z "$CORE_URL" ]]; then
		core_bundle="$(bundle_core)"
		mkdir -p "$STAGE/serve/0.0.1-smoke-core"
		cp "$DIST/$core_bundle" "$STAGE/serve/0.0.1-smoke-core/"
		CORE_URL="http://localhost:$PORT/0.0.1-smoke-core/$core_bundle"
	fi

	echo "==> Building libhost.a"
	(cd "$ROOT/blueprint-platform" && zig build)

	echo "==> Checking vendored linker inputs"
	(cd "$ROOT/blueprint-platform/targets" && sha256sum --quiet -c x64musl.sha256)

	echo "==> Bundling roc-blueprint (core: $CORE_URL)"
	mkdir -p "$STAGE/platform/targets/x64musl" "$STAGE/platform/targets/arm64mac"
	cp "$ROOT"/blueprint-platform/*.roc "$STAGE/platform/"
	cp "$ROOT"/blueprint-platform/targets/x64musl/{crt1.o,libhost.a,libc.a,libzigc.a,libcompiler_rt.a} "$STAGE/platform/targets/x64musl/"
	cp "$ROOT"/blueprint-platform/targets/arm64mac/libhost.a "$STAGE/platform/targets/arm64mac/"
	sed -i "s#\"../blueprint-core/main.roc\"#\"$CORE_URL\"#" "$STAGE/platform/main.roc"
	grep -qF "\"$CORE_URL\"" "$STAGE/platform/main.roc" || { echo "failed to rewrite the core dependency" >&2; exit 1; }
	pf_bundle="$(cd "$STAGE/platform" && bundle . main.roc $(ls *.roc | grep -v '^main.roc$') targets/x64musl/* targets/arm64mac/*)"
	echo "    $pf_bundle"
	echo "roc-blueprint $pf_bundle" >>"$DIST/bundles.txt"

	echo "==> Smoke test: running Blueprint.roc against the platform bundle"
	mkdir -p "$STAGE/serve/0.0.1-smoke" "$STAGE/app"
	cp "$DIST/$pf_bundle" "$STAGE/serve/0.0.1-smoke/"
	sed "s#platform \"../../blueprint-platform/main.roc\"#platform \"http://localhost:$PORT/0.0.1-smoke/$pf_bundle\"#" "$ROOT/examples/all-settings/Blueprint.roc" >"$STAGE/app/Blueprint.roc"
	echo "==> Compile-time validation against the platform bundle"
	ROC="$ROC" "$ROOT/scripts/test-config.sh" "http://localhost:$PORT/0.0.1-smoke/$pf_bundle"
	(cd "$STAGE/app" && "$ROC" check Blueprint.roc)
	(cd "$STAGE/app" && "$ROC" Blueprint.roc) | grep -qF '(format ('
	echo "    ok"
	;;
*)
	echo "usage: scripts/bundle.sh core | platform [CORE_URL]" >&2
	exit 2
	;;
esac

echo "==> Wrote $DIST/bundles.txt"
cat "$DIST/bundles.txt"
