#!/usr/bin/env bash
# Cross-build the blueprint CLI for every host the configuration platform
# supports, from one Linux machine, into dist/blueprint-<system>.
#
# Roc links macOS programs against a minimal sysroot it expects beside its own
# executable. Only the macOS compiler archive ships that sysroot, so this
# assembles a toolchain from both archives. Their URLs and hashes come from the
# flake's locked roc-overlay, for the nightly in .roc-version.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # system -> extracted archive directory
	local system="$1" url hash archive
	url="$(nix eval --raw ".#packages.$system.roc.src.url")"
	hash="$(nix eval --raw ".#packages.$system.roc.src.outputHash")"
	archive="$(nix store prefetch-file --json --expected-hash "$hash" "$url" | python3 -c 'import json, sys; print(json.load(sys.stdin)["storePath"])')"
	mkdir -p "$WORK/$system"
	tar -xzf "$archive" -C "$WORK/$system" --strip-components=1
	echo "$WORK/$system"
}

linux="$(fetch x86_64-linux)"
mac="$(fetch aarch64-darwin)"
cp -R "$mac/darwin" "$linux/darwin"
roc="$linux/roc"
test "$("$roc" version)" = "Roc compiler version $(sed -n '1p' .roc-version)"

(cd blueprint-platform && zig build)
mkdir -p "$DIST"
build() { # roc target, Nix system
	local out="$DIST/blueprint-$2"
	# The compiler occasionally fails with an unexplained internal error and
	# succeeds unchanged when run again.
	"$roc" build blueprint-cli/main.roc --target="$1" --output="$out" ||
		"$roc" build blueprint-cli/main.roc --target="$1" --output="$out"
	test -s "$out"
	echo "==> $out"
}
build x64musl x86_64-linux
build arm64musl aarch64-linux
build arm64mac aarch64-darwin
build x64mac x86_64-darwin
(cd "$DIST" && sha256sum blueprint-x86_64-linux blueprint-aarch64-linux blueprint-aarch64-darwin blueprint-x86_64-darwin >blueprint.sha256)
cat "$DIST/blueprint.sha256"
