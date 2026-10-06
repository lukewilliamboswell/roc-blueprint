#!/usr/bin/env bash
# Run a built blueprint binary on this machine with no Roc of its own: it must
# fetch its compiler, evaluate a Blueprint.roc and realise an environment. It
# must also do so without a host Python.
#
#   scripts/smoke-binary.sh dist/blueprint-aarch64-darwin
#
# SMOKE_PACKAGES names the default package source when the built-in one does
# not support this machine, as on Intel macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BLUEPRINT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
# macOS temporary directories sit behind a symlink; the relative platform path
# below must be computed from the real location.
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
PLATFORM="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$ROOT/blueprint-platform/main.roc" "$WORK")"

cat >"$WORK/Blueprint.roc" <<EOF
app [config] { pf: platform "$PLATFORM" }

config = [
	Name("smoke"),${SMOKE_PACKAGES:+
	Packages("default", From(NixPackages("$SMOKE_PACKAGES"))),}
	Overlay("roc", "github:roc-lang/roc-overlay"),
	Environment("dev", [Tools(["git"]), Overlays(["roc"]), Command("roc-stable", "rocpkgs.nightly")]),
	Shell("default", [Use("dev")]),
	Task("git", [Use("dev"), Run(["git", "--version"])]),
	Task("script", [Use("dev"), Run(["./hello.roc"])]),
]
EOF

cat >"$WORK/hello.roc" <<'EOF'
#!/usr/bin/env roc-stable
main! = |_args| {
    echo!("Hello from a roc-stable script")
    Ok({})
}
EOF
chmod +x "$WORK/hello.roc"

# Leave no Roc for the binary to find.
unset ROC
clean_path=""
IFS=: read -ra entries <<<"$PATH"
for entry in "${entries[@]}"; do
	[[ -x "$entry/roc" ]] || clean_path="${clean_path:+$clean_path:}$entry"
done
export PATH="$clean_path"
if command -v roc >/dev/null; then echo "a roc is still on PATH" >&2; exit 1; fi

# Leave no usable Python either: the first python3 on PATH records and fails.
mkdir "$WORK/no-python"
printf '#!/bin/sh\necho "$@" >>"%s"\nexit 97\n' "$WORK/python3-was-used" >"$WORK/no-python/python3"
chmod +x "$WORK/no-python/python3"
export PATH="$WORK/no-python:$PATH"

cd "$WORK"
"$BLUEPRINT" --version
"$BLUEPRINT" update
"$BLUEPRINT" run git | grep -q '^git version '
test "$("$BLUEPRINT" run script)" = "Hello from a roc-stable script"
if [[ -e "$WORK/python3-was-used" ]]; then echo "blueprint used a host python3" >&2; exit 1; fi
echo "blueprint binary smoke test passed on $(uname -sm)"
