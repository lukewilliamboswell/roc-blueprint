#!/usr/bin/env bash
# Spike stand-in: copies the musl runtime files that roc-platform-template-zig
# has already staged. Replace with a pinned, verified download before release.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template_dir="${ROC_PLATFORM_TEMPLATE_ZIG:-$root_dir/../roc-platform-template-zig}"

for target in x64musl; do
    mkdir -p "$root_dir/platform/targets/$target"
    for file in crt1.o libc.a libzigc.a libcompiler_rt.a; do
        cp "$template_dir/platform/targets/$target/$file" "$root_dir/platform/targets/$target/$file"
    done
done
