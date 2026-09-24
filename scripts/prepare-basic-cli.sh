#!/usr/bin/env bash
# Build the source-pinned platform and expose it to blueprint-cli/main.roc.
set -euo pipefail
cd "$(dirname "$0")/.."
nix build .#basic-cli --out-link .basic-cli --print-build-logs
