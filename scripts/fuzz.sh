#!/usr/bin/env bash
# Build each roc-fuzz target in blueprint-ir-package/fuzz/ with coverage instrumentation and run it
# for a while from its corpus. A crash fails the script and libFuzzer prints
# the reproducing input.
#
#   scripts/fuzz.sh [SECONDS]      # per target; default 30 (CI smoke test)
#
# The corpus is copied to a scratch directory, so new inputs libFuzzer finds
# don't land in the repo. To keep them, run the target binary yourself on
# blueprint-ir-package/fuzz/<target>/corpus.
set -euo pipefail
cd "$(dirname "$0")/.."
ROC="${ROC:-roc}"
SECONDS_PER_TARGET="${1:-30}"
WORK="$(mktemp -d)"
# Crashing inputs go here (not the working directory); CI can upload them.
ARTIFACTS="${FUZZ_ARTIFACTS:-fuzz-artifacts}"
mkdir -p "$ARTIFACTS"
trap 'rm -rf "$WORK"' EXIT

for dir in blueprint-ir-package/fuzz/*/; do
	target="$(basename "$dir")"
	echo "==> $target (${SECONDS_PER_TARGET}s)"
	# roc exits non-zero on warnings; roc-fuzz's own nightly pin warns, so
	# judge the build by whether it produced the binary.
	"$ROC" build --fuzz "$dir/main.roc" --output="$WORK/$target" >"$WORK/$target.log" 2>&1 || true
	[[ -x "$WORK/$target" ]] || { cat "$WORK/$target.log" >&2; exit 1; }
	mkdir -p "$WORK/$target-corpus"
	if [[ -d "$dir/corpus" ]]; then cp "$dir"/corpus/* "$WORK/$target-corpus/"; fi
	flags=(-max_total_time="$SECONDS_PER_TARGET" -print_final_stats=1 -artifact_prefix="$ARTIFACTS/$target-")
	for dict in "$dir"/*.dict; do [[ -f "$dict" ]] && flags+=(-dict="$dict"); done
	status=0
	"$WORK/$target" "${flags[@]}" "$WORK/$target-corpus" >"$WORK/$target.out" 2>&1 || status=$?
	if [[ $status -ne 0 ]]; then
		tail -40 "$WORK/$target.out" >&2
		echo "$target failed (exit $status); crashing input in $ARTIFACTS/" >&2
		exit 1
	fi
	grep -E '^Done' "$WORK/$target.out"
done
