import cli.Cmd
import cli.Env
import cli.Path
import FlakeLock
import Process
import Script
import "../../flake.lock" as flake_lock : Str
import "../../fixtures/consumer/inputs.lock" as fixture_lock : Str
import "../../fixtures/overlays/first/flake.nix" as first_overlay : Str
import "../../fixtures/overlays/patch/flake.nix" as patch_overlay : Str
import "../../fixtures/overlays/unused/flake.nix" as unused_overlay : Str

## Projects run through the real `./blueprint` and real Nix. Each scenario
## writes a project, runs `blueprint update`, then runs tasks or evaluates the
## generated flake and compares what comes back.
##
## A scenario written here pins its packages to the nixpkgs revision in
## `fixtures/consumer/inputs.lock` and its overlay to the roc-overlay revision
## in `flake.lock`, so nothing it resolves moves. The two examples run as they
## are written, with the floating inputs a reader would copy.
Scenarios := [].{

	## What a command must do: exit 0, print exactly these bytes, print this
	## with or without a final newline, print a line starting with this,
	## print this somewhere, or fail saying this.
	Check : [Succeeds, Prints(Str), Says(Str), LineStarts(Str), Contains(Str), FailsWith(Str)]

	Step : [
		## `./blueprint` with these arguments, in the project.
		Cli(List(Str), Check),

		## The compiler with these arguments, in the project.
		Compiler(List(Str), Check),

		## `nix eval --raw` of this attribute of the generated flake.
		Eval(Str, Check),

		## Two attributes of the generated flake are one derivation.
		SameDerivation(Str, Str),

		## This task prints `PATH`; the directories holding any of these
		## launchers hold exactly these, so each package has its one command.
		Launchers(Str, List(Str)),

		## The outputs of the generated flake lack the first texts and hold the second.
		Generated(List(Str), List(Str)),
	]

	## `Example` runs in a directory of this repository and updates when its
	## steps say so. `Fresh` is written to a temporary directory and updated
	## first; its lock is then read-only and compared after every step.
	Scenario : { name : Str, place : [Example(Str), Fresh], files : List((Str, Str)), executable : List(Str), steps : List(Step) }

	## Replaced by the platform's path relative to the project.
	platform_token = "@PLATFORM@"

	header = "app [config] { pf: platform \"${platform_token}\" }\n\n"

	scenarios : Str, Str -> List(Scenario)
	scenarios = |packages_ref, overlay_ref| [
		{
			name: "all-settings example: check, list, update and run tasks",
			place: Example("examples/all-settings"),
			files: [],
			executable: [],
			steps: [
				Cli(["check"], Succeeds),
				Cli(["tasks"], Succeeds),
				Cli(["--help"], Succeeds),
				Cli(["run", "--help"], Contains("ci-hello")),
				Cli(["update"], Succeeds),
				Cli(["run", "ci-hello"], LineStarts("git version ")),
				# A shell alias and a task entry share one Nix environment.
				SameDerivation("devShells.x86_64-linux.ci", "devShells.x86_64-linux.blueprint-env-base"),
				Cli(["run", "hello"], LineStarts("git version ")),
			],
		},
		{
			name: "extensions example: the platform emits them, this blueprint refuses them clearly",
			place: Example("examples/extensions"),
			files: [],
			executable: [],
			steps: [
				Compiler(["check", "Blueprint.roc"], Succeeds),
				Compiler(["Blueprint.roc"], Contains("(kind \"services\")")),
				Cli(["check"], FailsWith("needs features: extensions")),
			],
		},
		{
			name: "scoped overlays: both orders, an unselected overlay and one that throws",
			place: Fresh,
			files: [
				("first/flake.nix", first_overlay),
				("patch/flake.nix", patch_overlay),
				# Declared, never selected: evaluating it would fail the update.
				("unused/flake.nix", unused_overlay),
				(
					"Blueprint.roc",
					Str.join_with(
						[
							"${header}config = [",
							"	Name(\"overlay-execution\"),",
							"	Systems([\"x86_64-linux\"]),",
							"	Packages(\"default\", From(NixPackages(\"${packages_ref}\"))),",
							"	Overlay(\"first\", \"path:./first\"),",
							"	Overlay(\"patch\", \"path:./patch\"),",
							"	Overlay(\"unused\", \"path:./unused\"),",
							"	Environment(\"base\", [Tools([\"fixtureTool\"]), Overlays([\"first\"])]),",
							"	Environment(\"patched\", [Extend(\"base\"), Tools([\"fixtureTool\"]), Overlays([\"first\", \"patch\"])]),",
							"	Environment(\"reverse\", [Tools([\"fixtureTool\"]), Overlays([\"patch\", \"first\"])]),",
							"	Environment(\"plain\", [Tools([\"fixtureTool\"])]),",
							"	Task(\"base\", [Use(\"base\"), Run([\"fixture-tool\"])]),",
							"	Task(\"patched\", [Use(\"patched\"), Run([\"fixture-tool\"])]),",
							"	Task(\"reverse\", [Use(\"reverse\"), Run([\"fixture-tool\"])]),",
							"	Task(\"plain\", [Use(\"plain\"), Run([\"fixture-tool\"])]),",
							"]",
							"",
						],
						"\n",
					),
				),
			],
			executable: [],
			steps: [
				Cli(["run", "base"], Prints("base\n")),
				Cli(["run", "patched"], Prints("patch:base\n")),
				# Overlays do not commute: applied last, `first` replaces the patch.
				Cli(["run", "reverse"], Prints("base\n")),
				# A declared but unselected overlay cannot supply the package,
				# and Nix's own missing-attribute failure reaches the user.
				Cli(["run", "plain"], FailsWith("attribute 'fixtureTool' missing")),
				Generated(["unused", ".overlays.default"], ["overlays = [  ];"]),
			],
		},
		{
			name: "system tools: a Linux-only tool leaves the macOS shell evaluable",
			place: Fresh,
			files: [
				(
					"Blueprint.roc",
					Str.join_with(
						[
							"${header}config = [",
							"	Name(\"system-tools\"),",
							"	Systems([\"x86_64-linux\", \"aarch64-darwin\"]),",
							"	Packages(\"default\", From(NixPackages(\"${packages_ref}\"))),",
							"	Packages(\"stable\", From(NixPackages(\"${packages_ref}\"))),",
							"	Environment(\"base\", [Tools([\"git\"]), ToolsFor(\"x86_64-linux\", [\"wayland\"])]),",
							"	Environment(\"dev\", [Extend(\"base\")]),",
							"	Environment(\"scoped\", [ToolsFor(\"x86_64-linux\", [\"stable#wayland\"])]),",
							"	Environment(\"unscoped\", [Tools([\"linuxHeaders\"])]),",
							"	Shell(\"default\", [Use(\"dev\")]),",
							"	Shell(\"scoped\", [Use(\"scoped\")]),",
							"	Shell(\"unscoped\", [Use(\"unscoped\")]),",
							"]",
							"",
						],
						"\n",
					),
				),
			],
			executable: [],
			steps: [
				Eval("devShells.x86_64-linux.default.drvPath", Succeeds),
				Eval("devShells.aarch64-darwin.default.drvPath", Succeeds),
				Eval("devShells.x86_64-linux.scoped.drvPath", Succeeds),
				Eval("devShells.aarch64-darwin.scoped.drvPath", Succeeds),
				# Without a system the same kind of tool is not filtered away:
				# Nix says the package does not exist for that machine.
				Eval("devShells.x86_64-linux.unscoped.drvPath", Succeeds),
				Eval("devShells.aarch64-darwin.unscoped.drvPath", FailsWith("not available on the requested hostPlatform")),
			],
		},
		{
			name: "commands: an inherited launcher, one launcher per package, a roc-stable script",
			place: Fresh,
			files: [
				(
					"Blueprint.roc",
					Str.join_with(
						[
							"${header}config = [",
							"	Name(\"commands\"),",
							"	Systems([\"x86_64-linux\", \"aarch64-darwin\"]),",
							"	Packages(\"default\", From(NixPackages(\"${packages_ref}\"))),",
							"	Overlay(\"roc\", \"${overlay_ref}\"),",
							"	Environment(\"base\", [Command(\"greet\", \"hello\")]),",
							"	Environment(\"dev\", [Extend(\"base\"), Overlays([\"roc\"]), Command(\"roc-stable\", \"rocpkgs.nightly\")]),",
							"	Shell(\"default\", [Use(\"dev\")]),",
							"	Task(\"greet\", [Use(\"dev\"), Run([\"greet\"])]),",
							"	Task(\"version\", [Use(\"dev\"), Run([\"roc-stable\", \"version\"])]),",
							"	Task(\"script\", [Use(\"dev\"), Run([\"./hello.roc\"])]),",
							"	Task(\"path\", [Use(\"dev\"), Run([\"printenv\", \"PATH\"])]),",
							"]",
							"",
						],
						"\n",
					),
				),
				("hello.roc", roc_stable_script),
			],
			executable: ["hello.roc"],
			steps: [
				Cli(["run", "greet"], Says("Hello, world!")),
				Cli(["run", "version"], LineStarts("Roc compiler version ")),
				Cli(["run", "script"], Says("Hello from a roc-stable script")),
				Launchers("path", ["greet", "roc-stable"]),
				Eval("devShells.aarch64-darwin.default.drvPath", Succeeds),
			],
		},
	]

	## A script with no header of its own, run by the environment's `roc-stable`.
	roc_stable_script =
		\\#!/usr/bin/env roc-stable
		\\main! = |_args| {
		\\    echo!("Hello from a roc-stable script")
		\\    Ok({})
		\\}
		\\

	## Why a command did not do what was required, or "" if it did.
	verdict : Check, Process.Outcome -> Str
	verdict = |check, outcome| {
		code = outcome.code.to_str()
		match check {
			Succeeds => if outcome.code == 0 "" else "expected exit 0, got ${code}"
			Prints(text) =>
				if outcome.code == 0 and outcome.stdout == text "" else "expected exit 0 printing exactly ${Str.inspect(text)}, got exit ${code} and ${Str.inspect(outcome.stdout)}"
			Says(text) =>
				if outcome.code == 0 and outcome.stdout.drop_suffix("\n") == text "" else "expected exit 0 saying ${Str.inspect(text)}, got exit ${code} and ${Str.inspect(outcome.stdout)}"
			LineStarts(prefix) =>
				if outcome.code == 0 and outcome.stdout.split_on("\n").any(|line| line.starts_with(prefix)) "" else "expected exit 0 and a line starting with ${Str.inspect(prefix)}, got exit ${code}"
			Contains(text) =>
				if outcome.code == 0 and outcome.stdout.contains(text) "" else "expected exit 0 and output containing ${Str.inspect(text)}, got exit ${code}"
			FailsWith(text) =>
				if outcome.code != 0 and "${outcome.stdout}${outcome.stderr}".contains(text) "" else "expected a failure containing ${Str.inspect(text)}, got exit ${code}"
		}
	}

	## The part of a generated flake that selects and evaluates inputs.
	outputs_of : Str -> Str
	outputs_of = |flake| Str.join_with(flake.split_on("  outputs =").drop_first(1), "  outputs =")

	## What is wrong with a generated flake's outputs, or "" if nothing is.
	generated_problem : Str, List(Str), List(Str) -> Str
	generated_problem = |flake, lacks, holds| {
		outputs = outputs_of(flake)
		match lacks.find_first(|text| outputs.contains(text)) {
			Ok(text) => "the generated outputs contain ${Str.inspect(text)}"
			Err(_) =>
				match holds.find_first(|text| !outputs.contains(text)) {
					Ok(text) => "the generated outputs do not contain ${Str.inspect(text)}"
					Err(_) => ""
				}
		}
	}

	## Run every scenario from the repository root, each fresh project in a
	## temporary directory that is removed afterwards.
	run! : Path => Try({}, _)
	run! = |root_path| {
		root = Path.to_str(Path.canonicalize!(root_path)?)?
		if !(Path.is_file!(Path.utf8("${root}/blueprint")) ?? False) {
			return Script.fail!("./blueprint is missing; build it with `roc build blueprint-cli/main.roc --output=./blueprint`")
		}
		packages_ref = pinned!(fixture_lock, "nixpkgs", "fixtures/consumer/inputs.lock")?
		overlay_ref = pinned!(flake_lock, "roc-overlay", "flake.lock")?
		work = Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-scenarios-")?)?)?
		context = { root, blueprint: "${root}/blueprint", roc: Process.roc!(), work }
		result = each!(context, scenarios(packages_ref, overlay_ref), 0)
		# A scenario leaves its lock read-only.
		_ = Cmd.new_str("chmod").args_str(["-R", "u+w", "--", work]).exec_cmd!()
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

Context : { root : Str, blueprint : Str, roc : Str, work : Str }

pinned! : Str, Str, Str => Try(Str, _)
pinned! = |text, node, file|
	match FlakeLock.locked(text, node) {
		Ok(pin) => Ok(FlakeLock.ref(pin))
		Err(NoPin(_)) => Script.fail!("${file} has no GitHub pin for ${node}")
	}

each! : Context, List(Scenarios.Scenario), U64 => Try({}, _)
each! = |context, remaining, index|
	match remaining {
		[] => Ok({})
		[scenario, .. as rest] => {
			Script.info!("\n==>", scenario.name)?
			one!(context, scenario, index)?
			Script.pass!(scenario.name)?
			each!(context, rest, index + 1)
		}
	}

one! : Context, Scenarios.Scenario, U64 => Try({}, _)
one! = |context, scenario, index|
	match scenario.place {
		Example(directory) => steps!(context, "${context.root}/${directory}", "", scenario.steps)
		Fresh => {
			project = "${context.work}/project-${index.to_str()}"
			platform_path = Process.relative(project, "${context.root}/blueprint-platform/main.roc")
			for (name, text) in scenario.files {
				file = "${project}/${name}"
				Path.create_all!(Path.utf8(Str.join_with(file.split_on("/").drop_last(1), "/")))?
				Path.write_utf8!(Path.utf8(file), text.replace_each(Scenarios.platform_token, platform_path))?
			}
			for name in scenario.executable {
				chmod!("+x", "${project}/${name}")?
			}
			# Only an explicit update resolves pins; nothing after it may.
			_ = Process.succeed!(Process.command(context.blueprint, ["update"], project))?
			lock = Path.read_utf8!(Path.utf8("${project}/Blueprint.lock"))?
			chmod!("a-w", "${project}/Blueprint.lock")?
			steps!(context, project, lock, scenario.steps)
		}
	}

chmod! : Str, Str => Try({}, _)
chmod! = |mode, target|
	Cmd.new_str("chmod").args_str([mode, "--", target]).exec_cmd!().map_err(|_| ChmodFailed(target))

## Run each step in order. `lock` is the authority a fresh project was given;
## it must read the same after every step. An example has none to compare.
steps! : Context, Str, Str, List(Scenarios.Step) => Try({}, _)
steps! = |context, project, lock, remaining|
	match remaining {
		[] => Ok({})
		[step, .. as rest] => {
			step!(context, project, step)?
			if !lock.is_empty() and Path.read_utf8!(Path.utf8("${project}/Blueprint.lock"))? != lock {
				return Script.fail!("a step after `blueprint update` changed Blueprint.lock")
			}
			steps!(context, project, lock, rest)
		}
	}

step! : Context, Str, Scenarios.Step => Try({}, _)
step! = |context, project, step|
	match step {
		Cli(args, check) => require!(Process.command(context.blueprint, args, project), check)
		Compiler(args, check) => require!(Process.command(context.roc, args, project), check)
		Eval(attribute, check) => require!(eval(project, attribute), check)
		SameDerivation(left, right) => {
			left_path = derivation!(project, left)?
			right_path = derivation!(project, right)?
			Process.check!(
				left_path == right_path and left_path.starts_with("/nix/store/") and left_path.ends_with(".drv"),
				"expected ${left} and ${right} to be one derivation, got ${left_path} and ${right_path}",
			)
		}
		Launchers(task, names) => {
			printed = Process.succeed!(Process.command(context.blueprint, ["run", task], project))?
			found = launcher_entries!(printed.stdout.trim().split_on(":"), names, [])?
			Process.check!(
				names.all(|name| found.contains(name)) and found.all(|name| names.contains(name)),
				"unexpected launcher contents: ${Str.join_with(found, " ")}",
			)
		}
		Generated(lacks, holds) => {
			flake = Path.read_utf8!(Path.utf8("${project}/.blueprint/flake.nix"))?
			reason = Scenarios.generated_problem(flake, lacks, holds)
			Process.check!(reason.is_empty(), reason)
		}
	}

## The derivative lock is complete: evaluating must not need to change it.
eval : Str, Str -> Process.Job
eval = |project, attribute|
	Process.command("nix", ["eval", "--no-update-lock-file", "--no-write-lock-file", "--raw", "path:${project}/.blueprint#${attribute}"], project)

derivation! : Str, Str => Try(Str, _)
derivation! = |project, attribute| {
	outcome = Process.succeed!(eval(project, "${attribute}.drvPath"))?
	Ok(outcome.stdout.trim())
}

require! : Process.Job, Scenarios.Check => Try({}, _)
require! = |job, check| {
	outcome = Process.traced!(job)?
	reason = Scenarios.verdict(check, outcome)
	if !reason.is_empty() {
		return Script.fail!("${outcome.stdout}${outcome.stderr}\n${job.label}: ${reason}")
	}
	Ok({})
}

## Every entry of the `PATH` directories that hold one of `names`.
launcher_entries! : List(Str), List(Str), List(Str) => Try(List(Str), _)
launcher_entries! = |directories, names, found|
	match directories {
		[] => Ok(found)
		[directory, .. as rest] => {
			holds = holds_any!(directory, names)
			entries = if holds entry_names!(directory)? else []
			launcher_entries!(rest, names, found.concat(entries))
		}
	}

holds_any! : Str, List(Str) => Bool
holds_any! = |directory, names| {
	var $holds = False
	for name in names {
		if Process.holds_program!(directory, name) {
			$holds = True
		}
	}
	$holds
}

entry_names! : Str => Try(List(Str), _)
entry_names! = |directory| {
	var $names = []
	for entry in Path.list!(Path.utf8(directory))? {
		$names = $names.append(Path.to_str(entry)?.split_on("/").last() ?? "")
	}
	Ok($names)
}

printed : Str -> Process.Outcome
printed = |text| { code: 0, stdout: text, stderr: "" }

failed : Str -> Process.Outcome
failed = |text| { code: 1, stdout: "", stderr: text }

expect Scenarios.verdict(Succeeds, printed("")) == "" and Scenarios.verdict(Succeeds, failed("")) != ""
expect Scenarios.verdict(Prints("base\n"), printed("base\n")) == ""
expect Scenarios.verdict(Prints("base\n"), printed("patch:base\n")) != "" and Scenarios.verdict(Prints("base\n"), printed("base")) != ""
expect Scenarios.verdict(Prints(""), failed("")) != ""
expect Scenarios.verdict(Says("hi"), printed("hi\n")) == "" and Scenarios.verdict(Says("hi"), printed("hi")) == "" and Scenarios.verdict(Says("hi"), printed("hi there\n")) != ""
expect Scenarios.verdict(LineStarts("git version "), printed("warning\ngit version 2.55.0\n")) == ""
expect Scenarios.verdict(LineStarts("git version "), printed("a git version 2\n")) != ""
expect Scenarios.verdict(Contains("ci-hello"), printed("tasks: ci-hello, hello")) == "" and Scenarios.verdict(Contains("ci-hello"), printed("hello")) != ""
expect Scenarios.verdict(FailsWith("missing"), failed("attribute 'x' missing")) == ""
# Saying it and succeeding, or failing for another reason, is not the failure.
expect Scenarios.verdict(FailsWith("missing"), printed("missing")) != "" and Scenarios.verdict(FailsWith("missing"), failed("other")) != ""

# Inputs are declared for every request; only the outputs show what was selected.
expect Scenarios.outputs_of("{\n  inputs = { unused.url = \"path:./unused\"; };\n  outputs = inputs: { overlays = [  ]; };\n}") == " inputs: { overlays = [  ]; };\n}"
expect Scenarios.generated_problem("  inputs = unused;\n  outputs = overlays = [  ];", ["unused"], ["overlays = [  ];"]) == ""
expect Scenarios.generated_problem("  outputs = unused overlays = [  ];", ["unused"], ["overlays = [  ];"]) == "the generated outputs contain \"unused\""
expect Scenarios.generated_problem("  outputs = overlays = [ first ];", ["unused"], ["overlays = [  ];"]) == "the generated outputs do not contain \"overlays = [  ];\""

# Every fresh project names the platform by the token and pins what it resolves.
expect Scenarios.scenarios("github:NixOS/nixpkgs/abc", "github:roc-lang/roc-overlay/def").all(
	|scenario|
		match scenario.place {
			Example(_) => scenario.files.is_empty()
			Fresh =>
				match scenario.files.find_first(|(name, _)| name == "Blueprint.roc") {
					Ok((_, text)) => text.contains("platform \"@PLATFORM@\"") and text.contains("From(NixPackages(\"github:NixOS/nixpkgs/abc\"))") and !text.contains("nixos-") and !text.contains("\"github:roc-lang/roc-overlay\"")
					Err(_) => False
				}
		},
)
expect Scenarios.scenarios("p", "o").len() == 5
