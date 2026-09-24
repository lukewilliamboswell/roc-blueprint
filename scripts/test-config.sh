#!/usr/bin/env bash
# Whole-config validation must happen in roc check, locally and from a bundle.
# Optional argument: platform URL (used by bundle.sh while its server is live).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROC="${ROC:-roc}"
PLATFORM="${1:-$ROOT/blueprint-ir-platform/main.roc}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# roc check accepts absolute platform paths, but evaluating an app does not.
if [[ "$PLATFORM" == /* ]]; then
	PLATFORM="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$PLATFORM" "$WORK")"
fi

valid=()
invalid=()
messages=()
fixture() {
	printf 'app [config] { pf: platform "%s" }\n\nconfig = %s\n' "$PLATFORM" "$2" >"$WORK/$1.roc"
	if [[ $# == 2 ]]; then
		valid+=("$1")
	else
		invalid+=("$1")
		messages+=("$3")
	fi
}

fixture Valid '[Name("valid"), Environment("dev", [Tools(["git"])]), Shell("default", [Use("dev")])]'
fixture ExplicitAuto '[Name("auto"), Packages("default", Auto), Environment("dev", [Tools(["hello@2.12.1", "glibc:debug"])]), Shell("default", [Use("dev")])]'
fixture ExplicitNix '[Name("nix"), Packages("default", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("dev", [Tools(["python3Packages.requests", "7zip", "2bwm"])]), Shell("default", [Use("dev")])]'
fixture ExplicitGuix '[Name("guix"), Packages("guix", From(GuixPackages("https://git.savannah.gnu.org/git/guix.git"))), Environment("dev", [Tools(["guix#hello@2.12.1", "guix#glibc:debug"])]), Shell("default", [Use("dev")])]'
fixture ForwardInheritance '[Name("inheritance"), Overlay("tools", "github:roc-lang/roc-overlay"), Environment("dev", [Extend("base"), Tools(["python3", "git"]), Overlays(["tools"])]), Environment("base", [Tools(["git"]), Overlays(["tools"])]), Environment("alias", [Extend("dev"), Overlays([])]), Environment("empty", []), Shell("default", [Use("alias")]), Task("check.version", [Use("dev"), Run(["git", "--version"])])]'
fixture TasksWithoutShells '[Name("tasks"), Environment("dev", [Tools(["git"])]), Task("check", [Use("dev"), Run(["git", "--version"])])]'
fixture EquivalentInline '[Name("inheritance"), Overlay("tools", "github:roc-lang/roc-overlay"), Environment("dev", [Tools(["git", "python3"]), Overlays(["tools"])]), Environment("base", [Tools(["git"]), Overlays(["tools"])]), Environment("alias", [Tools(["git", "python3"]), Overlays(["tools"])]), Environment("empty", []), Shell("default", [Use("alias")]), Task("check.version", [Use("dev"), Run(["git", "--version"])])]'
fixture EquivalentDefault '[Name("valid"), Packages("default", Auto), Environment("dev", [Tools(["git"])]), Shell("default", [Use("dev")])]'
fixture EquivalentComposition '[Name("composed"), Systems(["x86_64-linux"]), Environment("base", [Tools(["git"])]), Environment("dev", [Tools(["git", "python3"])]), Shell("default", [Use("dev")]), Task("fmt", [Use("dev"), Run(["python3", "--version"])]), Task("test", [Use("dev"), Run(["git", "--version"])]), Task("args", [Use("dev"), Run(["python3", "-c", "import json, sys; print(json.dumps(sys.argv[1:]))", "configured argument"])])]'

fixture MissingName '[Environment("dev", [])]' 'MissingName'
fixture DuplicateName '[Name("one"), Name("two")]' 'DuplicateName'
fixture DuplicateSystems '[Name("duplicate"), Systems(["x86_64-linux"]), Systems(["aarch64-linux"])]' 'DuplicateSystems'
fixture NoSystems '[Name("invalid"), Systems([])]' 'no systems'
fixture InvalidName '[Name("")]' 'invalid name'
fixture DuplicateShell '[Name("duplicate"), Environment("dev", []), Shell("default", [Use("dev")]), Shell("default", [Use("dev")])]' 'DuplicateShell'
fixture DuplicateEnvironment '[Name("duplicate"), Environment("dev", []), Environment("dev", [])]' 'DuplicateEnvironment'
fixture DuplicateTask '[Name("duplicate"), Environment("dev", []), Task("check", [Use("dev"), Run(["git"])]), Task("check", [Use("dev"), Run(["git"])])]' 'DuplicateTask'
fixture DuplicateSource '[Name("duplicate"), Packages("default", Auto), Packages("default", Auto)]' 'DuplicateSource'
fixture DuplicateInput '[Name("duplicate"), Input("tools", "github:numtide/flake-utils"), Overlay("tools", "github:roc-lang/roc-overlay")]' 'DuplicateInput'
fixture MissingShellUse '[Name("invalid"), Shell("default", [])]' 'MissingUse'
fixture DuplicateShellUse '[Name("invalid"), Environment("dev", []), Shell("default", [Use("dev"), Use("dev")])]' 'DuplicateUse'
fixture MissingTaskUse '[Name("invalid"), Task("check", [Run(["git"])])]' 'MissingUse'
fixture DuplicateTaskUse '[Name("invalid"), Environment("dev", []), Task("check", [Use("dev"), Use("dev"), Run(["git"])])]' 'DuplicateUse'
fixture MissingRun '[Name("invalid"), Environment("dev", []), Task("check", [Use("dev")])]' 'MissingRun'
fixture DuplicateRun '[Name("invalid"), Environment("dev", []), Task("check", [Use("dev"), Run(["git"]), Run(["git"])])]' 'DuplicateRun'
fixture EmptyRun '[Name("invalid"), Environment("dev", []), Task("check", [Use("dev"), Run([])])]' 'empty argv'
fixture EmptyExecutable '[Name("invalid"), Environment("dev", []), Task("check", [Use("dev"), Run([""])])]' 'empty argv'
fixture DuplicateTools '[Name("invalid"), Environment("dev", [Tools([]), Tools([])])]' 'DuplicateTools'
fixture DuplicateOverlays '[Name("invalid"), Environment("dev", [Overlays([]), Overlays([])])]' 'DuplicateOverlays'
fixture DuplicateExtend '[Name("invalid"), Environment("base", []), Environment("dev", [Extend("base"), Extend("base")])]' 'DuplicateExtend'
fixture UnknownShellEnvironment '[Name("invalid"), Shell("default", [Use("missing")])]' 'unknown environment'
fixture UnknownTaskEnvironment '[Name("invalid"), Task("check", [Use("missing"), Run(["git"])])]' 'unknown environment'
fixture UnknownParent '[Name("invalid"), Environment("dev", [Extend("missing")])]' 'unknown environment'
fixture UnknownSource '[Name("invalid"), Environment("dev", [Tools(["missing#git"])])]' 'unknown source'
fixture UnknownOverlay '[Name("invalid"), Environment("dev", [Overlays(["missing"])])]' 'unknown overlay'
fixture FlakeIsNotOverlay '[Name("invalid"), Input("utils", "github:numtide/flake-utils"), Environment("dev", [Overlays(["utils"])])]' 'unknown overlay'
fixture InputIsNotSource '[Name("invalid"), Input("utils", "github:numtide/flake-utils"), Environment("dev", [Tools(["utils#git"])])]' 'unknown source'
fixture SelfCycle '[Name("invalid"), Environment("dev", [Extend("dev")])]' 'environment cycle'
fixture EnvironmentCycle '[Name("invalid"), Environment("one", [Extend("two")]), Environment("two", [Extend("three")]), Environment("three", [Extend("one")])]' 'environment cycle'
fixture InvalidNixTool '[Name("invalid"), Packages("default", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("dev", [Tools(["hello@2.12.1"])])]' 'invalid Nix tool'
fixture InvalidGuixTool '[Name("invalid"), Packages("default", From(GuixPackages("https://git.savannah.gnu.org/git/guix.git"))), Environment("dev", [Tools(["git@"])])]' 'invalid Guix tool'

# Capability support is checked for a selected request, not globally.
fixture GuixOverlay '[Name("deferred-capability"), Packages("default", From(GuixPackages("current"))), Overlay("tools", "github:example/tools"), Environment("dev", [Tools(["git"]), Overlays(["tools"])])]'

# The real imported-module fixture must work with the served platform too.
cp "$ROOT/examples/composition/ProjectTasks.roc" "$WORK/ProjectTasks.roc"
sed "s#platform \"../../blueprint-ir-platform/main.roc\"#platform \"$PLATFORM\"#" \
	"$ROOT/examples/composition/Blueprint.roc" >"$WORK/Composed.roc"
valid+=(Composed)
for name in "${valid[@]}"; do
	"$ROC" check "$WORK/$name.roc"
done

for index in "${!invalid[@]}"; do
	name="${invalid[$index]}"
	message="${messages[$index]}"
	status=0
	"$ROC" check "$WORK/$name.roc" >"$WORK/check.log" 2>&1 || status=$?
	# A warning, compiler crash or unrelated error is not a validation success.
	if [[ "$status" != 1 ]] ||
		! grep -qF 'compile time crash' "$WORK/check.log" ||
		! grep -qF 'Invalid Blueprint.roc:' "$WORK/check.log" ||
		! grep -qF "$message" "$WORK/check.log"; then
		cat "$WORK/check.log" >&2
		echo "expected compile-time $name rejection containing '$message' (exit 1), got exit $status" >&2
		exit 1
	fi
done

# Compare actual emitted semantic IR, not private lowering implementation details.
# This also proves inheritance is resolved, deduplicated, and parent-first;
# empty child Overlays does not clear the parent selection.
same_ir() {
	"$ROC" "$WORK/$1.roc" >"$WORK/left.ir"
	"$ROC" "$WORK/$2.roc" >"$WORK/right.ir"
	if ! cmp -s "$WORK/left.ir" "$WORK/right.ir"; then
		diff -u "$WORK/left.ir" "$WORK/right.ir" >&2 || true
		echo "expected identical semantic IR for $1 and $2" >&2
		exit 1
	fi
}
same_ir ForwardInheritance EquivalentInline
same_ir Valid EquivalentDefault
same_ir Composed EquivalentComposition

echo "    ${#valid[@]} valid configs accepted; ${#invalid[@]} semantic errors rejected at compile time; equivalent IR verified"
