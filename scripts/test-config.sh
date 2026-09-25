#!/usr/bin/env bash
# Whole-config validation must happen in roc check, locally and from a bundle.
# Optional argument: platform URL (used by bundle.sh while its server is live).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROC="${ROC:-roc}"
PLATFORM="${1:-$ROOT/blueprint-platform/main.roc}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# roc check accepts absolute platform paths, but evaluating an app does not.
if [[ "$PLATFORM" == /* ]]; then
	PLATFORM="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$PLATFORM" "$WORK")"
fi

valid=()
invalid=()
messages=()
quote_invalid=()
quote_messages=()
fixture() {
	printf 'app [config] { pf: platform "%s" }\n\nconfig = %s\n' "$PLATFORM" "$2" >"$WORK/$1.roc"
	if [[ $# == 2 ]]; then
		valid+=("$1")
	elif [[ $# == 4 ]]; then
		quote_invalid+=("$1")
		quote_messages+=("$3")
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
fixture SystemTools '[Name("systems"), Systems(["x86_64-linux", "aarch64-darwin"]), Environment("base", [Tools(["git"]), ToolsFor("x86_64-linux", ["wayland"])]), Environment("dev", [Extend("base"), ToolsFor("x86_64-linux", ["alsa-lib"])]), Shell("default", [Use("dev")])]'

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
fixture DuplicateToolsFor '[Name("invalid"), Systems(["x86_64-linux"]), Environment("dev", [ToolsFor("x86_64-linux", ["git"]), ToolsFor("x86_64-linux", ["python3"])])]' 'DuplicateToolsFor'
fixture UndeclaredToolsFor '[Name("invalid"), Systems(["x86_64-linux"]), Environment("dev", [ToolsFor("aarch64-darwin", ["git"])])]' 'undeclared system for system tools'
fixture UnknownToolsForSource '[Name("invalid"), Systems(["x86_64-linux"]), Environment("dev", [ToolsFor("x86_64-linux", ["missing#git"])])]' 'unknown source'
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

# B2 authoring uses ordinary typed settings, including forward dependencies.
fixture Builds '[Name("builds"), Environment("builder", []), Source("assets", "path:./assets"), Build("app", [Use("builder"), Inputs(["assets"]), Needs(["library"]), Run(["python3", "build.py", "", "two words", "$HOME"]), Output("dist/app")]), Build("library", [Use("builder"), Run(["python3", "library.py"]), Output("dist/library")])]'
fixture SourcesOnly '[Name("sources"), Source("assets", "github:example/assets")]'
fixture BuildNoSources '[Name("build"), Environment("builder", []), Build("app", [Use("builder"), Run(["true"]), Output("dist/app")])]'
fixture DuplicateBuildSource '[Name("bad"), Source("assets", "path:./assets"), Source("assets", "path:./other")]' 'DuplicateBuildSource'
fixture SourceInputCollision '[Name("bad"), Source("assets", "path:./assets"), Input("assets", "github:example/assets")]' 'DuplicateInput'
fixture SourcePackageCollision '[Name("bad"), Source("assets", "path:./assets"), Packages("assets", Auto)]' 'DuplicateInput'
fixture SourceDefaultCollision '[Name("bad"), Source("default", "path:./assets")]' 'DuplicateInput'
fixture DuplicateBuild '[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Run(["true"]), Output("out")]), Build("app", [Use("builder"), Run(["true"]), Output("out")])]' 'DuplicateBuild'
fixture MissingBuildUse '[Name("bad"), Build("app", [Run(["true"]), Output("out")])]' 'MissingUse'
fixture MissingBuildRun '[Name("bad"), Build("app", [Use("builder"), Output("out")])]' 'MissingRun'
fixture MissingBuildOutput '[Name("bad"), Build("app", [Use("builder"), Run(["true"])])]' 'MissingOutput'
fixture DuplicateBuildUse '[Name("bad"), Build("app", [Use("builder"), Use("builder"), Run(["true"]), Output("out")])]' 'DuplicateUse'
fixture DuplicateBuildRun '[Name("bad"), Build("app", [Use("builder"), Run(["true"]), Run(["true"]), Output("out")])]' 'DuplicateRun'
fixture DuplicateBuildOutput '[Name("bad"), Build("app", [Use("builder"), Run(["true"]), Output("out"), Output("out")])]' 'DuplicateOutput'
fixture DuplicateBuildInputs '[Name("bad"), Build("app", [Use("builder"), Inputs([]), Inputs([]), Run(["true"]), Output("out")])]' 'DuplicateInputs'
fixture DuplicateBuildNeeds '[Name("bad"), Build("app", [Use("builder"), Needs([]), Needs([]), Run(["true"]), Output("out")])]' 'DuplicateNeeds'
fixture UnknownBuildEnvironment '[Name("bad"), Build("app", [Use("missing"), Run(["true"]), Output("out")])]' 'unknown environment'
fixture UnknownBuildInput '[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Inputs(["missing"]), Run(["true"]), Output("out")])]' 'unknown build source'
fixture PackageIsNotBuildSource '[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Inputs(["default"]), Run(["true"]), Output("out")])]' 'unknown build source'
fixture UnknownBuildDependency '[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Needs(["missing"]), Run(["true"]), Output("out")])]' 'unknown build'
fixture TaskIsNotBuildDependency '[Name("bad"), Environment("builder", []), Task("library", [Use("builder"), Run(["true"])]), Build("app", [Use("builder"), Needs(["library"]), Run(["true"]), Output("out")])]' 'unknown build'
fixture BuildSelfCycle '[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Needs(["app"]), Run(["true"]), Output("out")])]' 'build cycle'
fixture BuildCycle '[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Needs(["library"]), Run(["true"]), Output("out")]), Build("library", [Use("builder"), Needs(["app"]), Run(["true"]), Output("out")])]' 'build cycle'
fixture EmptyBuildRun '[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Run([]), Output("out")])]' 'empty argv'
fixture EmptyBuildExecutable '[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Run([""]), Output("out")])]' 'empty argv'
fixture NulBuildRun '[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Run(["true", Str.from_utf8([0]) ?? ""]), Output("out")])]' 'NUL in argv'
fixture DuplicateBuildInputReference '[Name("bad"), Environment("builder", []), Source("assets", "path:./assets"), Build("app", [Use("builder"), Inputs(["assets", "assets"]), Run(["true"]), Output("out")])]' 'DuplicateBuildInput'
fixture DuplicateBuildNeedReference '[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Needs(["library", "library"]), Run(["true"]), Output("out")])]' 'DuplicateBuildDependency'
index=0
for output in '' '/absolute' '.' '..' 'dist/../escape' 'dist//file' 'dist/' 'C:/file'; do
	fixture "BadOutput$index" "[Name(\"bad\"), Environment(\"builder\", []), Build(\"app\", [Use(\"builder\"), Run([\"true\"]), Output(\"$output\")])]" 'invalid build output'
	index=$((index + 1))
done
index=0
for ref in 'path:.' 'path:./' 'path:/absolute' 'path:../escape' 'path:./assets/../escape' 'file:/absolute' 'git+file:///absolute' 'flake:nixpkgs'; do
	fixture "BadBuildSource$index" "[Name(\"bad\"), Source(\"assets\", \"$ref\")]" 'invalid build source reference'
	index=$((index + 1))
done
# The same bound must apply to compile-time and untrusted runtime graphs.
fixture BuildDepth "$(python3 - <<'PY'
items = ['Name("deep")', 'Environment("builder", [])']
for i in range(129):
    needs = f'Needs(["b{i-1}"]),' if i else ''
    items.append(f'Build("b{i}", [Use("builder"), {needs} Run(["true"]), Output("out")])')
print('[' + ','.join(items) + ']')
PY
)" 'build dependencies exceed 128 levels'

# Imported helpers compose builds without a plugin or separate schema.
cat >"$WORK/ProjectBuilds.roc" <<'ROC'
import pf.Config
ProjectBuilds :: [].{
	settings : List(Config.Setting)
	settings = [Build("app", [Use("builder"), Inputs(["assets"]), Needs(["library"]), Run(["python3", "build.py", "", "two words", "$HOME"]), Output("dist/app")]), Build("library", [Use("builder"), Run(["python3", "library.py"]), Output("dist/library")])]
}
ROC
printf 'app [config] { pf: platform "%s" }\nimport ProjectBuilds\nconfig = [Name("builds"), Environment("builder", []), Source("assets", "path:./assets")].concat(ProjectBuilds.settings)\n' "$PLATFORM" >"$WORK/ComposedBuilds.roc"
valid+=(ComposedBuilds)

# Typed workflow references preserve argv and repeated task/build operations.
workflow_base='Name("workflows"), Environment("dev", []), Task("check.all", [Use("dev"), Run(["true"])]), Build("app", [Use("dev"), Run(["true"]), Output("out")])'
workflow_steps='Workflow("ci", [RunWorkflow("leaf"), BuildArtifact("app"), RunWorkflow("leaf"), BuildArtifact("app")]), Workflow("leaf", [RunTask("check.all", ["", "two words", "\"quoted\"", "$HOME", "line\nbreak", "--flag"])])'
fixture Workflows "[$workflow_base, $workflow_steps]"
fixture EmptyWorkflow '[Name("empty"), Workflow("ci", [])]'
fixture BadWorkflowName '[Name("bad"), Workflow("bad/name", [])]' 'invalid workflow name' quote
fixture BadRunWorkflowName '[Name("bad"), Workflow("ci", [RunWorkflow("bad/name")])]' 'invalid workflow name' quote
fixture BadRunTaskName '[Name("bad"), Workflow("ci", [RunTask("bad..name", [])])]' 'is not a task name' quote
fixture BadArtifactName '[Name("bad"), Workflow("ci", [BuildArtifact("bad/name")])]' 'is not an input name' quote
fixture DuplicateWorkflow '[Name("bad"), Workflow("ci", []), Workflow("ci", [])]' 'DuplicateWorkflow'
fixture UnknownWorkflowTask "[$workflow_base, Workflow(\"ci\", [RunTask(\"missing\", [])])]" 'unknown task'
fixture UnknownWorkflowBuild "[$workflow_base, Workflow(\"ci\", [BuildArtifact(\"missing\")])]" 'unknown build'
fixture UnknownWorkflow "[$workflow_base, Workflow(\"ci\", [RunWorkflow(\"missing\")])]" 'unknown workflow'
fixture WorkflowSelfCycle '[Name("bad"), Workflow("ci", [RunWorkflow("ci")])]' 'workflow cycle'
fixture UnusedWorkflowCycle '[Name("bad"), Workflow("safe", []), Workflow("a", [RunWorkflow("b")]), Workflow("b", [RunWorkflow("a")])]' 'workflow cycle'
fixture WorkflowTaskIsNotBuild '[Name("bad"), Environment("dev", []), Task("check", [Use("dev"), Run(["true"])]), Workflow("ci", [BuildArtifact("check")])]' 'unknown build'
fixture WorkflowBuildIsNotTask "[$workflow_base, Workflow(\"ci\", [RunTask(\"app\", [])])]" 'unknown task'
fixture WorkflowNul "[$workflow_base, Workflow(\"ci\", [RunTask(\"check.all\", [Str.from_utf8([0]) ?? \"\"])])]" 'NUL in argv'

# Count/depth gates run against the local and served platform, not only pure Spec.
workflow_graph() {
	python3 - "$1" "$2" "$3" <<'PY'
import sys
count, double, atomic = map(int, sys.argv[1:])
items = ['Name("graph")', 'Environment("dev", [])',
         'Task("check", [Use("dev"), Run(["true"])])']
for i in range(count):
    steps = ['RunTask("check", [])'] if atomic else []
    if i:
        steps = [f'RunWorkflow("w{i-1}")'] * (2 if double else 1)
    items.append(f'Workflow("w{i}", [{",".join(steps)}])')
print('[' + ','.join(items) + ']')
PY
}
fixture WorkflowEmptyDiamond "$(workflow_graph 128 1 0)"
fixture WorkflowDepth "$(workflow_graph 129 0 0)" 'workflow dependencies exceed 128 levels'
fixture WorkflowExpansion "$(workflow_graph 14 1 1)" 'workflow expansion exceeds 4096 atomic steps'
fixture WorkflowDeclarations "$(workflow_graph 1025 0 0)" 'workflows exceed 1024 declarations'
fixture WorkflowSteps '[Name("wide"), Workflow("empty", []), Workflow("wide", {
 var $steps = []
 while $steps.len() <= 8192 { $steps = $steps.append(RunWorkflow("empty")) }
 $steps
})]' 'workflow graph exceeds 8192 steps'
fixture WorkflowArgv '[Name("args"), Environment("dev", []), Task("check", [Use("dev"), Run(["true"])]), Workflow("ci", [RunTask("check", {
 var $argv = []
 while $argv.len() < 4096 { $argv = $argv.append("") }
 $argv
})])]' 'argv exceeds 4096 arguments'

fixture WorkflowArgvBytes "[$workflow_base, Workflow(\"leaf\", [RunTask(\"check.all\", {
 var \$arg = \"x\"
 while \$arg.to_utf8().len() < 524288 { \$arg = \$arg.concat(\$arg) }
 [\$arg]
})]), Workflow(\"twice\", [RunWorkflow(\"leaf\"), RunWorkflow(\"leaf\")])]" 'workflow expansion exceeds 1 MiB argv bytes'

# Imported workflow helpers use the same public checked constructors.
printf '# Reusable typed workflows compose as ordinary settings.\nimport pf.Config\nProjectWorkflows :: [].{\n settings : List(Config.Setting)\n settings = [%s]\n}\n' "$workflow_steps" >"$WORK/ProjectWorkflows.roc"
printf 'app [config] { pf: platform "%s" }\nimport ProjectWorkflows\nconfig = [%s].concat(ProjectWorkflows.settings)\n' "$PLATFORM" "$workflow_base" >"$WORK/ComposedWorkflows.roc"
valid+=(ComposedWorkflows)

# Capability support is checked for a selected request, not globally.
fixture GuixOverlay '[Name("deferred-capability"), Packages("default", From(GuixPackages("current"))), Overlay("tools", "github:example/tools"), Environment("dev", [Tools(["git"]), Overlays(["tools"])])]'

# The real imported-module fixture must work with the served platform too.
cp "$ROOT/examples/composition/ProjectTasks.roc" "$WORK/ProjectTasks.roc"
sed "s#platform \"../../blueprint-platform/main.roc\"#platform \"$PLATFORM\"#" \
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

# Checked constructor strings fail with their specific from_quote diagnostic.
for index in "${!quote_invalid[@]}"; do
	name="${quote_invalid[$index]}"
	status=0
	"$ROC" check "$WORK/$name.roc" >"$WORK/check.log" 2>&1 || status=$?
	if [[ "$status" != 1 ]] ||
		! grep -qF 'invalid string' "$WORK/check.log" ||
		! grep -qF "${quote_messages[$index]}" "$WORK/check.log"; then
		cat "$WORK/check.log" >&2
		echo "expected checked-name rejection for $name, got exit $status" >&2
		exit 1
	fi
done

# Compare actual emitted semantic Spec, not private lowering implementation details.
# This also proves inheritance is resolved, deduplicated, and parent-first;
# empty child Overlays does not clear the parent selection.
same_ir() {
	"$ROC" "$WORK/$1.roc" >"$WORK/left.spec"
	"$ROC" "$WORK/$2.roc" >"$WORK/right.spec"
	if ! cmp -s "$WORK/left.spec" "$WORK/right.spec"; then
		diff -u "$WORK/left.spec" "$WORK/right.spec" >&2 || true
		echo "expected identical semantic Spec for $1 and $2" >&2
		exit 1
	fi
}
same_ir ForwardInheritance EquivalentInline
same_ir Valid EquivalentDefault
same_ir Composed EquivalentComposition
same_ir Builds ComposedBuilds
same_ir Workflows ComposedWorkflows

# Tool availability must not affect semantic configuration. Keep the compiler
# explicit while removing all executable discovery from the app's environment.
compiler="$(command -v "$ROC")"
mkdir "$WORK/no-tools"
"$compiler" "$WORK/Valid.roc" >"$WORK/with-tools.spec"
PATH="$WORK/no-tools" "$compiler" "$WORK/Valid.roc" >"$WORK/without-tools.spec"
cmp "$WORK/with-tools.spec" "$WORK/without-tools.spec"

# New optional fields must be accompanied by feature markers for old consumers.
"$ROC" "$WORK/Builds.roc" >"$WORK/builds.spec"
grep -qF '(minor 3)' "$WORK/builds.spec"
grep -qF '(requires ("sources" "builds"))' "$WORK/builds.spec"
grep -qF '(build_sources ' "$WORK/builds.spec"
grep -qF '(builds ' "$WORK/builds.spec"
"$ROC" "$WORK/Workflows.roc" >"$WORK/workflows.spec"
grep -qF '(minor 3)' "$WORK/workflows.spec"
grep -qF '(requires ("builds" "workflows"))' "$WORK/workflows.spec"
grep -qF '(workflows ' "$WORK/workflows.spec"
grep -qF '(RunTask "check.all" ("" "two words" "\"quoted\"" "$HOME" "line\nbreak" "--flag"))' "$WORK/workflows.spec"
"$ROC" "$WORK/SystemTools.roc" >"$WORK/system-tools.spec"
grep -qF '(requires ("system-tools"))' "$WORK/system-tools.spec"
grep -qF '(system_tools ' "$WORK/system-tools.spec"
grep -qF '(system "x86_64-linux")' "$WORK/system-tools.spec"

echo "    ${#valid[@]} valid configs accepted; ${#invalid[@]} semantic errors and ${#quote_invalid[@]} checked-name errors rejected at compile time; equivalent Spec verified"
