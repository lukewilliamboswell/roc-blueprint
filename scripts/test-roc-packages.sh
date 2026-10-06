#!/usr/bin/env bash
# Locked Roc packages reach Roc's cache without a download: a sandboxed build,
# which has no network, runs a basic-cli app, and a task finds them linked.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The cache sits beside the project: build snapshots refuse symlinks.
PROJECT="$WORK/project"
mkdir "$PROJECT"
PLATFORM="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$ROOT/blueprint-platform/main.roc" "$PROJECT")"
CLI="https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst"
HTTP="https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst"

cat >"$PROJECT/Blueprint.roc" <<EOF
app [config] { pf: platform "$PLATFORM" }

config = [
	Name("roc-packages"),
	Systems(["x86_64-linux"]),
	Overlay("roc", "github:roc-lang/roc-overlay"),
	Environment("packages", [RocPackages(["$CLI", "$HTTP"])]),
	Environment("dev", [Extend("packages"), Overlays(["roc"]), Command("roc-stable", "rocpkgs.nightly-2026-10-04-130536d")]),
	Shell("default", [Use("dev")]),
	Task("cached", [Use("dev"), Run(["sh", "-c", "ls -l \"\$XDG_CACHE_HOME/roc/packages\""])]),
	Task("hello", [Use("dev"), Run(["roc-stable", "main.roc"])]),
	Build("offline", [Use("dev"), Run(["sh", "-c", "roc-stable main.roc > greeting.txt"]), Output("greeting.txt")]),
]
EOF

cat >"$PROJECT/main.roc" <<EOF
app [main!] { cli: platform "$CLI" }

import cli.Stdout

main! = |_args| {
	Stdout.line!("Hello from locked packages")?
	Ok({})
}
EOF

cd "$PROJECT"
"$ROOT/blueprint" update
grep -qF "tarball+$CLI" Blueprint.lock

# An empty cache of our own shows what entering the environment provides.
export XDG_CACHE_HOME="$WORK/cache"
listing="$("$ROOT/blueprint" run cached)"
for url in "$CLI" "$HTTP"; do
	hash="$(basename "$url" .tar.zst)"
	grep -qE "$hash -> /nix/store/" <<<"$listing" || { echo "missing cache link for $hash: $listing" >&2; exit 1; }
done
test "$("$ROOT/blueprint" run hello)" = "Hello from locked packages"
test -L "$XDG_CACHE_HOME/roc/packages/$(basename "$CLI" .tar.zst)"

# A package Roc downloaded itself is a real directory and is left alone.
rm "$XDG_CACHE_HOME/roc/packages/$(basename "$HTTP" .tar.zst)"
mkdir "$XDG_CACHE_HOME/roc/packages/$(basename "$HTTP" .tar.zst)"
touch "$XDG_CACHE_HOME/roc/packages/$(basename "$HTTP" .tar.zst)/main.roc"
"$ROOT/blueprint" run cached >/dev/null
test ! -L "$XDG_CACHE_HOME/roc/packages/$(basename "$HTTP" .tar.zst)"

out="$("$ROOT/blueprint" build offline)"
test "$(cat "$out")" = "Hello from locked packages"
echo 'Roc packages: linked on entry, and a networkless build resolves them'
