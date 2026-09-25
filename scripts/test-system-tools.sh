#!/usr/bin/env bash
# A shared shell keeps Linux-only packages out of the macOS Nix closure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PLATFORM="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$ROOT/blueprint-platform/main.roc" "$WORK")"

cat >"$WORK/Blueprint.roc" <<EOF
app [config] { pf: platform "$PLATFORM" }

config = [
	Name("system-tools"),
	Systems(["x86_64-linux", "aarch64-darwin"]),
	Packages("stable", From(NixPackages("github:NixOS/nixpkgs/nixos-24.05"))),
	Environment("base", [Tools(["git"]), ToolsFor("x86_64-linux", ["wayland"])]),
	Environment("dev", [Extend("base")]),
	Environment("scoped", [ToolsFor("x86_64-linux", ["stable#wayland"])]),
	Shell("default", [Use("dev")]),
	Shell("scoped", [Use("scoped")]),
]
EOF

(cd "$WORK" && "$ROOT/blueprint" update)
nix eval --raw "path:$WORK/.blueprint#devShells.x86_64-linux.default.drvPath" >/dev/null
nix eval --raw "path:$WORK/.blueprint#devShells.aarch64-darwin.default.drvPath" >/dev/null
nix eval --raw "path:$WORK/.blueprint#devShells.x86_64-linux.scoped.drvPath" >/dev/null
nix eval --raw "path:$WORK/.blueprint#devShells.aarch64-darwin.scoped.drvPath" >/dev/null
echo 'System-scoped tools: Linux and macOS shells evaluate'
