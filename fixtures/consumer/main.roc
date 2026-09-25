# Independent consumer of pure planning and decoded authority, never the CLI.
app [main!] {
	pf: platform "../../.basic-cli/main.roc",
	core: "../../blueprint-core/main.roc",
	nix: "../../blueprint-nix/main.roc",
}

import pf.Stdout
import core.Spec
import core.Project
import core.Request
import core.Steps
import core.Layout
import nix.Locks
import nix.NixProvider
import "../../blueprint-nix/tests/sample.spec.scm" as wire : Str
import "../../blueprint-nix/tests/sample.golden.nix" as golden : Str
import "inputs.lock" as native_lock : Str
import "authority.lock" as authority : Str

layout : Layout
layout = Layout.{
	project_root: "/consumer/project",
	workspace: "/consumer/work",
	generated_root: "/consumer/work/generated",
	lock_path: "/consumer/pins/inputs.lock",
}

project : Str -> Try(Spec, Str)
project = |text| {
	decoded = Spec.parse(text).map_err(|_| "invalid fixture Spec")?
	Project.validate(decoded)
}

# The caller supplies serialized authority; decoding and planning are pure.
plan : Spec, Request, Str, Layout -> Try(Steps, Str)
plan = |spec, request, target, paths| NixProvider.plan(
	spec,
	request,
	target,
	paths,
	Locks.decode(authority)?,
)

files : {} -> Try(List(Steps.File), Str)
files = |_| {
	planned = plan(project(wire)?, Request.Generate, "x86_64-linux", layout)?
	match planned.steps {
		[step] => Ok(step.files)
		_ => Err("Generate must produce one step")
	}
}

# B2 emits unused Auto too; alias it to the existing identical nixpkgs pin.
# This fixture-only seed completion changes no locked node or fetch identity.
complete_native_lock : Str
complete_native_lock = native_lock.replace_each(
	"\"nixpkgs\": \"nixpkgs\",",
	"\"default\": \"nixpkgs\", \"nixpkgs\": \"nixpkgs\",",
)

# Explicit conversion of the completed Nix seed preserves every supplied pin.
expect {
	converted = Locks.from_nix(project(wire)?, layout, complete_native_lock)?
	encoded = Locks.encode(converted)
	encoded == authority
}

# Inspection preserves the B1 golden; plans add stable, explicit input kinds.
expect NixProvider.render(project(wire)?) == Ok(golden)

planned_golden : Str
planned_golden = golden.replace_each(
	"  inputs = {\n",
	"  inputs = {\n".concat(
		"    \"default\" = { url = \"github:NixOS/nixpkgs/nixos-unstable\"; "
			.concat("flake = true; };\n"),
	),
).replace_each(
	"\"nixpkgs\".url = \"github:NixOS/nixpkgs/nixos-unstable\";",
	"\"nixpkgs\" = { url = \"github:NixOS/nixpkgs/nixos-unstable\"; "
		.concat("flake = true; };"),
).replace_each(
	"\"roc\".url = \"github:roc-lang/roc-overlay\";",
	"\"roc\" = { url = \"github:roc-lang/roc-overlay\"; flake = true; };",
)

# Full planning shares the golden renderer and returns only derivative files.
expect match files({}) {
	Ok(generated) => generated.map(|file| file.path) == [
		"/consumer/work/generated/flake.nix",
		"/consumer/work/generated/flake.lock",
	] and generated.first().map_ok(|file| file.contents) == Ok(planned_golden)
	Err(_) => False
}

# Generate needs neither provider commands nor filesystem observations here.
expect match plan(project(wire)?, Request.Generate, "x86_64-linux", layout) {
	Ok({ steps: [step] }) => step.action == Generate
		and step.argv.is_empty() and step.operations.is_empty()
			and step.artifacts.is_empty()
	_ => False
}

# Native locks and malformed authorities cannot bypass the decoding protocol.
expect Locks.decode(native_lock).is_err()
	and Locks.decode(authority.replace_each("(major 1)", "(major 9)"))
		.is_err()

# Caller-selected requests render only their environment and its shell aliases.
expect match plan(
	project(wire)?,
	Request.Shell("ci"),
	"x86_64-linux",
	layout,
) {
	Ok({ steps: [step] }) => match step.files.first() {
		Ok(file) => file.contents.contains("\"blueprint-env-base\"")
			and !file.contents.contains("\"blueprint-env-dev\"")
				and !file.contents.contains("llvmPackages")
		Err(_) => False
	}
	_ => False
}

# Staging cannot quietly select an undeclared target.
expect plan(project(wire)?, Request.Generate, "unsupported", layout).is_err()

# Caller-owned paths still reject lexical parent traversal before file effects.
expect plan(
	project(wire)?,
	Request.Generate,
	"x86_64-linux",
	{ ..layout, generated_root: "/consumer/../escape" },
).is_err()

# A changed local source needs matching authority, never implicit resolution.
expect [
	wire.replace_each(
		"github:NixOS/nixpkgs/nixos-unstable",
		"path:./packages",
	),
	wire.replace_each("github:roc-lang/roc-overlay", "path:./overlay"),
].all(
	|text| match project(text) {
		Ok(spec) => plan(spec, Request.Generate, "x86_64-linux", layout).is_err()
		Err(_) => False
	},
)

# Unsupported local Git spelling is not reinterpreted as an unlocked source.
expect plan(
	project(
		wire.replace_each(
			"github:roc-lang/roc-overlay",
			"git+file:./overlay",
		),
	)?,
	Request.Generate,
	"x86_64-linux",
	layout,
).is_err()

# A declared but unsupported target is still rejected by the shared renderer.
expect plan(
	project(wire.replace_each("aarch64-darwin", "riscv64-linux"))?,
	Request.Generate,
	"x86_64-linux",
	layout,
).is_err()

# Staging is not a bypass for required feature support checks.
expect plan(
	project(
		wire.replace_each(
			"(systems",
			"(requires (\"future-build\")) (systems",
		),
	)?,
	Request.Generate,
	"x86_64-linux",
	layout,
).is_err()

# Task argument boundaries and read-only lock flags survive the real plan API.
expect {
	spec = project(wire)?
	task_project = {
		..spec,
		tasks: [
			{
				name: "print",
				environment: "base",
				run: ["printf", "%s"],
			},
		],
	}
	planned = plan(
		task_project,
		Request.Run("print", ["two words", "", "--literal"]),
		"x86_64-linux",
		layout,
	)?
	match planned.steps {
		[step] => step.action == Run("print") and step.argv == [
			"nix",
			"develop",
			"--no-update-lock-file",
			"--no-write-lock-file",
			"path:/consumer/work/generated#devShells.x86_64-linux.blueprint-env-base",
			"--command",
			"printf",
			"%s",
			"two words",
			"",
			"--literal",
		]
		_ => False
	}
}

# Switching the selected closure preserves both lock bytes and authority.
expect {
	spec = project(wire)?
	all = plan(spec, Request.Generate, "x86_64-linux", layout)?
	selected = plan(spec, Request.Shell("ci"), "x86_64-linux", layout)?
	match (all.steps, selected.steps) {
		([full], [shell]) => full.files.last() == shell.files.last()
			and Locks.decode(authority).map_ok(Locks.encode) == Ok(authority)
		_ => False
	}
}

# Consumers receive the entire ordered workflow through the same pure API.
# Nested repetitions equal standalone steps without a Blueprint subprocess.
expect {
	spec = project(wire)?
	workflow_project = {
		..spec,
		requires_: spec.requires_.append("workflows"),
		tasks: [{ name: "print", environment: "base", run: ["printf", "%s"] }],
		workflows: [
			{
				name: "ci",
				steps: [RunWorkflow("print"), RunWorkflow("print")],
			},
			{
				name: "print",
				steps: [RunTask("print", ["two words", "", "--literal"])],
			},
		],
	}
	atomic = plan(
		workflow_project,
		Request.Run("print", ["two words", "", "--literal"]),
		"x86_64-linux",
		layout,
	)?
	sequence = plan(
		workflow_project,
		Request.Workflow("ci"),
		"x86_64-linux",
		layout,
	)?
	match atomic.steps {
		[step] => sequence.steps == [step, step]
			and step.action == Run("print")
				and Locks.decode(authority).map_ok(Locks.encode) == Ok(authority)
		_ => False
	}
}

main! = |_args| {
	generated = files({}).map_err(|_| Exit(1))?
	for file in generated {
		Stdout.line!("# ${file.path}")?
		Stdout.write!(file.contents)?
	}
	Ok({})
}
