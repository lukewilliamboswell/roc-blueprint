#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

ROC_BIN="${ROC:-roc}"
tmp_base="${ROC_BLUEPRINT_TMPDIR:-$root_dir/.roc-blueprint-tmp}"
tmp_dir="$tmp_base/ci"
docs_dir="$tmp_dir/docs"
bundle_dir="$tmp_dir/bundles"

rm -rf "$tmp_dir"
mkdir -p "$docs_dir" "$bundle_dir"

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
echo "Checking examples..."
if [ -z "${ROC_PLATFORM_BUNDLE:-}" ]; then
    for example in examples/*.roc; do
        "$ROC_BIN" check "$example" --no-cache
        "$ROC_BIN" test "$example" --no-cache
    done
else
    echo "Using the local platform override during bundle-backed example tests."
fi

case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        echo ""
        echo "Skipping package bundling on Windows."
        exit 0
        ;;
esac

echo ""
echo "Bundling packages..."
scripts/bundle.sh --output-dir "$bundle_dir"

echo ""
echo "Testing examples against localhost bundles..."
python3 ci/test_bundle_examples.py
