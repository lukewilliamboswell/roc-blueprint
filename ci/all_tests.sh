#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

ROC_BIN="${ROC:-roc}"
ROC_CACHE_DIR="${ROC_BLUEPRINT_CACHE_DIR:-${TMPDIR:-/tmp}/roc-blueprint-roc-cache}"
export ROC_CACHE_DIR
tmp_base="${ROC_BLUEPRINT_TMPDIR:-$root_dir/.roc-blueprint-tmp}"
tmp_dir="$tmp_base/ci"
docs_dir="$tmp_dir/docs"

rm -rf "$tmp_dir"
mkdir -p "$docs_dir"

echo "$("$ROC_BIN" version)"

echo ""
echo "Checking format..."
"$ROC_BIN" fmt --check packages examples

for package_name in blueprint blueprint-nix; do
    entrypoint="packages/$package_name/main.roc"

    echo ""
    echo "Checking $package_name..."
    "$ROC_BIN" check "$entrypoint"

done

# The current new compiler cannot run `roc test` or `roc docs` directly on a
# package that declares another package dependency. The example tests below
# exercise blueprint-nix through an app until that compiler limitation is gone.
echo ""
echo "Testing blueprint..."
"$ROC_BIN" test packages/blueprint/main.roc

echo ""
echo "Generating blueprint docs..."
"$ROC_BIN" docs packages/blueprint/main.roc --output="$docs_dir/blueprint"

echo ""
echo "Testing release note generation..."
python3 ci/test_release_notes.py

case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        echo ""
        echo "Skipping package bundling on Windows."
        exit 0
        ;;
esac

echo ""
echo "Testing examples against localhost bundles..."
python3 ci/test_examples.py
