#!/usr/bin/env bash
# Run a built blueprint binary on this machine with no Roc of its own: it must
# fetch its compiler, evaluate a Blueprint.roc and realise an environment.
#
#   scripts/smoke-binary.sh dist/blueprint-aarch64-darwin
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BLUEPRINT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PLATFORM="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$ROOT/blueprint-platform/main.roc" "$WORK")"

cat >"$WORK/Blueprint.roc" <<EOF
app [config] { pf: platform "$PLATFORM" }

config = [
	Name("smoke"),
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

cd "$WORK"
"$BLUEPRINT" --version
"$BLUEPRINT" update
"$BLUEPRINT" run git | grep -q '^git version '
test "$("$BLUEPRINT" run script)" = "Hello from a roc-stable script"
echo "blueprint binary smoke test passed on $(uname -sm)"
