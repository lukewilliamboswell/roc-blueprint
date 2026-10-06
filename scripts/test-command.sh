#!/usr/bin/env bash
# A Command adds only its launcher: a pinned Roc runs as roc-stable without
# putting a bare roc on PATH, and shebang scripts resolve it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PLATFORM="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$ROOT/blueprint-platform/main.roc" "$WORK")"

cat >"$WORK/Blueprint.roc" <<EOF
app [config] { pf: platform "$PLATFORM" }

config = [
	Name("commands"),
	Systems(["x86_64-linux", "aarch64-darwin"]),
	Overlay("roc", "github:roc-lang/roc-overlay"),
	Environment("base", [Command("greet", "hello")]),
	Environment("dev", [Extend("base"), Overlays(["roc"]), Command("roc-stable", "rocpkgs.nightly")]),
	Shell("default", [Use("dev")]),
	Task("greet", [Use("dev"), Run(["greet"])]),
	Task("version", [Use("dev"), Run(["roc-stable", "version"])]),
	Task("script", [Use("dev"), Run(["./hello.roc"])]),
	Task("contents", [Use("dev"), Run(["sh", "-c", "ls \"\$(dirname \"\$(command -v roc-stable)\")\" \"\$(dirname \"\$(command -v greet)\")\""])]),
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

cd "$WORK"
"$ROOT/blueprint" update
test "$("$ROOT/blueprint" run greet)" = "Hello, world!"
"$ROOT/blueprint" run version | grep -q '^Roc compiler version '
test "$("$ROOT/blueprint" run script)" = "Hello from a roc-stable script"
# Each launcher package holds its one command, not the tool's own executables.
contents="$("$ROOT/blueprint" run contents | grep -v ':$' | grep -v '^$' | sort | tr '\n' ' ')"
test "$contents" = "greet roc-stable " || { echo "unexpected launcher contents: $contents" >&2; exit 1; }
nix eval --raw "path:$WORK/.blueprint#devShells.aarch64-darwin.default.drvPath" >/dev/null
echo 'Commands: renamed launchers run, and macOS shell evaluates'
