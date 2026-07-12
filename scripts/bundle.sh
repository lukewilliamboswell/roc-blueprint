#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$root_dir/dist"
roc_bin="${ROC:-roc}"

while (($# > 0)); do
    case "$1" in
        --output-dir)
            output_dir="$2"
            shift 2
            ;;
        --output-dir=*)
            output_dir="${1#--output-dir=}"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

for package_name in blueprint blueprint-nix; do
    package_dir="$root_dir/packages/$package_name"
    package_output_dir="$output_dir/$package_name"
    mkdir -p "$package_output_dir"

    if [ "$package_name" = "blueprint-nix" ]; then
        stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/roc-blueprint-nix-bundle.XXXXXX")"
        trap 'rm -rf "$stage_dir"' EXIT
        mkdir -p "$stage_dir/blueprint"
        cp "$root_dir/scripts/blueprint-nix-bundle-main.roc" "$stage_dir/main.roc"
        cp "$package_dir/Nix.roc" "$stage_dir/Nix.roc"
        cp "$package_dir/NixExpr.roc" "$stage_dir/NixExpr.roc"
        cp "$root_dir/packages/blueprint/main.roc" "$stage_dir/blueprint/main.roc"
        cp "$root_dir/packages/blueprint/Blueprint.roc" "$stage_dir/blueprint/Blueprint.roc"
        cp "$root_dir/packages/blueprint/Environment.roc" "$stage_dir/blueprint/Environment.roc"
        cp "$root_dir/packages/blueprint/EnvironmentId.roc" "$stage_dir/blueprint/EnvironmentId.roc"
        cp "$root_dir/packages/blueprint/Requirement.roc" "$stage_dir/blueprint/Requirement.roc"
        cp "$root_dir/packages/blueprint/Target.roc" "$stage_dir/blueprint/Target.roc"

        (
            cd "$stage_dir"
            "$roc_bin" bundle \
                main.roc \
                Nix.roc \
                NixExpr.roc \
                blueprint/main.roc \
                blueprint/Blueprint.roc \
                blueprint/Environment.roc \
                blueprint/EnvironmentId.roc \
                blueprint/Requirement.roc \
                blueprint/Target.roc \
                --output-dir "$package_output_dir"
        )
        rm -rf "$stage_dir"
        trap - EXIT
    else
        roc_files=(main.roc)
        while IFS= read -r file; do
            roc_files+=("$file")
        done < <(find "$package_dir" -maxdepth 1 -name '*.roc' ! -name 'main.roc' -print | sort)

        (
            cd "$package_dir"
            "$roc_bin" bundle "${roc_files[@]}" --output-dir "$package_output_dir"
        )
    fi
done
