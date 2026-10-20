# Blueprint sandbox builder protocol v1. Changes to these bytes deliberately
# change derivation identity. This runner does not depend on the Blueprint CLI.
# The following variables are supplied by Nix, never by the user command.
# shellcheck disable=SC2154
set -euo pipefail
core="$blueprintCoreutils/bin"
find="$blueprintFind/bin/find"
jq="$blueprintJq/bin/jq"
fail() { printf 'blueprint build: %s\n' "$*" >&2; exit 1; }

# The client mounts this authorization witness out of band. It is not part of
# the derivation and is never exposed through the command's environment.
witness=/blueprint-isolation/witness
[[ -f "$witness" && ! -L "$witness" ]] || fail 'cannot verify build isolation; user Run was not executed: missing sandbox witness'
mapfile -t caller < "$witness"
[[ ${#caller[@]} == 2 ]] || fail 'invalid sandbox witness'
for index in 0 1; do
    namespace=mnt
    [[ "$index" == 0 ]] || namespace=net
    observed=${caller[$index]}
    [[ "$observed" =~ ^$namespace:\[[0-9]+\]$ ]] || fail "invalid caller $namespace namespace"
    current=$("$core/readlink" "/proc/self/ns/$namespace") || fail "cannot read build $namespace namespace"
    [[ "$current" =~ ^$namespace:\[[0-9]+\]$ && "$current" != "$observed" ]] || fail "build shares caller $namespace namespace; user Run was not executed"
done

spec=$blueprintSpecPath
top=$PWD
# Validate before converting JSON into shell variables. Exact argv may include
# newlines, but NUL and control bytes in filesystem/environment paths cannot
# survive shell variable decoding without ambiguity.
"$jq" -e '
    def text: type == "string" and (contains("\u0000") | not);
    def path: text and (test("[\u0000-\u001f\u007f]") | not);
    (.project | path) and (.inputs | path) and (.artifacts | path) and
    (.tools | path) and (.path | path) and
    (.output | path and length > 0 and (startswith("/") | not) and
        (contains("\\") | not) and (contains(":") | not) and
        (split("/") | all(. != "" and . != "." and . != ".."))) and
    (.argv | type == "array" and length > 0 and all(.[]; text)) and
    (.argv[0] | length > 0) and
    ((.roc_packages // []) | type == "array" and
        all(.[]; (.name | path) and (.path | path)))
' "$spec" > /dev/null || fail 'invalid build specification'
get() { "$jq" -er "$1" "$spec"; }
project=$(get '.project')
inputs=$(get '.inputs')
artifacts=$(get '.artifacts')
tools=$(get '.tools')
command_path=$(get '.path')
output=$(get '.output')
[[ -n "$output" && "$output" != /* && "$output" != *\\* && "$output" != *:* ]] || fail 'invalid output path'
IFS=/ read -ra parts <<< "$output"
for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != . && "$part" != .. ]] || fail 'invalid output path'
done

safe_tree() {
    local tree=$1
    [[ ! -L "$tree" ]] || fail "symlink in tree: $tree"
    "$find" "$tree" ! -type f ! -type d -print -quit > "$top/tree-check"
    [[ ! -s "$top/tree-check" ]] || fail 'symlink or special file in tree' 
}
safe_farm() {
    local farm=$1 entry target
    [[ -d "$farm" ]] || fail "missing input farm: $farm"
    "$find" "$farm" -mindepth 1 -maxdepth 1 -print0 > "$top/farm-entries"
    while IFS= read -r -d '' entry; do
        [[ -L "$entry" ]] || fail "invalid input farm entry: $entry"
        target=$("$core/readlink" -f -- "$entry")
        [[ "$target" == /nix/store/* ]] || fail "input outside store: $entry"
        safe_tree "$target"
    done < "$top/farm-entries"
}
safe_tree "$project"
safe_farm "$inputs"
safe_farm "$artifacts"
work=$PWD/blueprint-work
home=$PWD/blueprint-home
"$core/mkdir" -- "$work" "$home"
"$core/cp" -R --preserve=mode -- "$project/." "$work/"
"$core/chmod" -R u+w -- "$work"
cache=$PWD/blueprint-cache
"$core/mkdir" -p -- "$cache/roc/packages"
"$jq" -j '(.roc_packages // [])[] | .name, "\u0000", .path, "\u0000"' "$spec" > "$top/bundles"
while IFS= read -r -d '' bundle && IFS= read -r -d '' location; do
    [[ "$bundle" =~ ^[A-Za-z0-9_-]+$ && -f "$location/main.roc" ]] || fail 'invalid Roc package bundle'
    "$core/ln" -s -- "$location" "$cache/roc/packages/$bundle"
done < "$top/bundles"
"$jq" -j '.argv[] | ., "\u0000"' "$spec" > "$top/argv"
mapfile -d '' -t argv < "$top/argv"
[[ ${#argv[@]} -gt 0 ]] || fail 'empty build command'
cd -- "$work"
"$core/env" -i PATH="$command_path" HOME="$home" XDG_CACHE_HOME="$cache" \
    BLUEPRINT_INPUTS="$inputs" BLUEPRINT_ARTIFACTS="$artifacts" BLUEPRINT_TOOLS="$tools" \
    "${argv[@]}"
[[ -d "$work" && ! -L "$work" ]] || fail 'build replaced the project workspace'
ancestor=$work
for part in "${parts[@]}"; do
    ancestor=$ancestor/$part
    [[ ! -L "$ancestor" ]] || fail "symlink in declared output path: $ancestor"
done
[[ -e "$work/$output" ]] || fail 'missing declared output'
safe_tree "$work/$output"
# The diagnostic names the literal Nix variable.
# shellcheck disable=SC2016
[[ ! -e "$out" && ! -L "$out" ]] || fail 'build wrote directly to $out instead of declared Output'
"$core/cp" -R --preserve=mode -- "$work/$output" "$out"
