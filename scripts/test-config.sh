#!/usr/bin/env bash
# Whole-config validation must happen in roc check, locally and from a bundle.
# Optional argument: platform URL (used by bundle.sh while its server is live).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROC="${ROC:-roc}"
PLATFORM="${1:-$ROOT/blueprint-ir-platform/main.roc}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fixture() {
	printf 'app [config] { pf: platform "%s" }\n\nconfig = %s\n' "$PLATFORM" "$2" >"$WORK/$1.roc"
}

fixture Valid '[Name("valid"), Shell("default", [Tools(["git"])])]'
fixture MissingName '[Shell("default", [Tools(["git"])])]'
fixture DuplicateShell '[Name("duplicate"), Shell("default", [Tools(["git"])]), Shell("default", [Tools(["git"])])]'

"$ROC" check "$WORK/Valid.roc"
for error in MissingName DuplicateShell; do
	status=0
	"$ROC" check "$WORK/$error.roc" >"$WORK/check.log" 2>&1 || status=$?
	# A warning, compiler crash or unrelated error is not a validation success.
	if [[ "$status" != 1 ]] ||
		! grep -qF 'compile time crash' "$WORK/check.log" ||
		! grep -qF "Invalid Blueprint.roc: [$error" "$WORK/check.log"; then
		cat "$WORK/check.log" >&2
		echo "expected compile-time $error rejection (exit 1), got exit $status" >&2
		exit 1
	fi
done

echo "    valid config accepted; missing name and duplicate shells rejected"
