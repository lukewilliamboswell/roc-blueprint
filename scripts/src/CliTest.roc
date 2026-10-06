import cli.Env
import cli.OsStr
import cli.Path
import core.Lock
import nix.LockJson
import nix.Locks
import CliHarness
import RocPackagesTest
import Script

## The real `./blueprint` and the real compiler against stubbed Nix and Guix.
##
## The CLI's own `expect`s hold its pure helpers. These cases hold what only a
## run can show: that a command checks, locks and plans in order before it has
## any effect, the exact argv a provider program is given, how often the
## configuration is evaluated, and the text an error becomes.
CliTest := [].{

	## Run every case from the repository root, in a temporary directory that is
	## removed afterwards.
	run! : Path => Try({}, _)
	run! = |repository| {
		bench = CliHarness.open!(repository, "blueprint-cli-", ["roc-record", "roc-wire", "roc-probe", "nix", "guix"])?
		result = cases!(bench)
		CliHarness.close!(bench)
		result
	}

	## The settings most cases start from: one environment, two shells, a task.
	valid : Str
	valid = Str.join_with(
		[
			"	Name(\"argument-test\"),",
			"	Environment(\"ci\", [Tools([\"git\"])]),",
			"	Shell(\"default\", [Use(\"ci\")]),",
			"	Shell(\"ci\", [Use(\"ci\")]),",
			"	Task(\"echo-args\", [Run([\"printf\", \"%s\\n\", \"configured argument\"]), Use(\"ci\")]),",
			"",
		],
		"\n",
	)

	## A Blueprint.roc with these settings, for the platform at this path.
	blueprint_roc : Str, Str -> Str
	blueprint_roc = |platform_path, body| "app [config] { pf: platform \"${platform_path}\" }\nconfig = [\n${body}]\n"

	## The argv that enters a Nix dev shell, or runs a command in one.
	develop : Str, Str, List(Str) -> List(Str)
	develop = |cwd, entry, command| {
		argv = ["develop", "--no-update-lock-file", "--no-write-lock-file", "path:${cwd}/.blueprint#devShells.x86_64-linux.${entry}"]
		if command.is_empty() argv else argv.append("--command").concat(command)
	}

	## What the configured task runs, before any extra argument.
	task : List(Str)
	task = ["printf", "%s\n", "configured argument"]

	## A Spec as a compiler might print it, which the loader must not trust.
	wire : Str
	wire =
		\\((format ((major 2) (minor 0))) (name "wire")
		\\ (systems ("x86_64-linux"))
		\\ (sources (((name "default") (provider Auto))))
		\\ (environments (((name "ci") (parents ()) (tools ()) (overlays ()))))
		\\ (shells (((name "default") (environment "ci"))))
		\\ (tasks (((name "echo-args") (environment "ci") (run ("true"))))))

	## The same Spec with a workflow, in the minor that introduced them.
	workflow_wire : Str
	workflow_wire = "${wire.replace_each("(minor 0)", "(minor 2)").drop_suffix(")")}(requires (\"workflows\")) (workflows (((name \"ci\") (steps ((RunTask \"echo-args\" ())))))))"
}

Test : { bench : CliHarness.Bench, env : List((OsStr, OsStr)), pin : Str }

## Run `./blueprint` and return everything it printed. Only `update` may
## change the authority: after anything else it must be the same file, with
## the same bytes, not written since.
run! : Test, Str, List(Str), I32, List((Str, Str)) => Try(Str, _)
run! = |test, cwd, args, status, overrides| {
	authority = "${cwd}/Blueprint.lock"
	before = CliHarness.identity!(authority)?
	outcome = CliHarness.blueprint!(test.bench, cwd, args, CliHarness.setting(test.env, overrides))?
	what = "blueprint ${Str.join_with(args, " ")}"
	CliHarness.exited!(outcome, status, what)?
	if args != ["update"] {
		CliHarness.check!(CliHarness.identity!(authority)? == before, "${what} changed the authority ${authority}")?
	}
	Ok("${outcome.stdout}${outcome.stderr}")
}

## `blueprint update`, checked: one provider command with exactly this argv,
## and an authority whose Nix pins are the native lock the provider wrote.
update! : Test, Str => Try({}, _)
update! = |test, cwd| {
	_ = run!(test, cwd, ["update"], 0, [])?
	CliHarness.same_calls!(
		CliHarness.calls!("${cwd}/nix-calls")?,
		[["flake", "update", "--flake", "path:${cwd}/.blueprint"]],
		"blueprint update did not run exactly one provider command",
	)?
	authority = Path.read_utf8!(Path.utf8("${cwd}/Blueprint.lock"))?
	native = Path.read_utf8!(Path.utf8("${cwd}/.blueprint/flake.lock"))?
	CliHarness.check!(pins_match(authority, native), "Blueprint.lock is not a major-1 Lock holding the native lock graph:\n${authority}")?
	CliHarness.tool!(["chmod", "0444", "--", "${cwd}/Blueprint.lock"])?
	CliHarness.forget!("${cwd}/nix-calls")
}

## Whether an authority is a major-1 Lock whose Nix hint holds exactly the
## graph in a native lock.
pins_match : Str, Str -> Bool
pins_match = |authority, native|
	match (Lock.parse(authority), CliHarness.authority_graph(authority), LockJson.decode(native)) {
		(Ok(lock), Ok(pinned), Ok(graph)) => lock.format.major == 1 and Locks.equivalent(pinned, graph)
		_ => False
	}

## No provider ran, and nothing was generated or locked.
untouched! : Str => Try({}, _)
untouched! = |cwd| {
	CliHarness.same_calls!(CliHarness.calls!("${cwd}/nix-calls")?, [], "Nix ran in ${cwd}")?
	CliHarness.same_calls!(CliHarness.calls!("${cwd}/guix-calls")?, [], "Guix ran in ${cwd}")?
	CliHarness.check!(!CliHarness.present!("${cwd}/.blueprint"), "${cwd}/.blueprint was created")?
	CliHarness.check!(!CliHarness.present!("${cwd}/Blueprint.lock"), "${cwd}/Blueprint.lock was created")
}

## A new project directory.
isolated! : Test, Str => Try(Str, _)
isolated! = |test, name| {
	cwd = "${test.bench.work}/${name}"
	Path.create_dir!(Path.utf8(cwd))?
	Ok(cwd)
}

settings! : Test, Str, Str => Try({}, _)
settings! = |test, cwd, body| {
	platform_path = RocPackagesTest.relative(cwd, "${test.bench.root}/blueprint-platform/main.roc")
	Path.write_utf8!(Path.utf8("${cwd}/Blueprint.roc"), CliTest.blueprint_roc(platform_path, body))
}

## A project whose compiler is the stub that prints `wire.scm`.
wired! : Test, Str, Str => Try(Str, _)
wired! = |test, name, text| {
	cwd = isolated!(test, name)?
	Path.write_utf8!(Path.utf8("${cwd}/Blueprint.roc"), "")?
	Path.write_utf8!(Path.utf8("${cwd}/wire.scm"), text)?
	Ok(cwd)
}

## The compiler runs recorded in a directory, apart from version probes.
evaluations! : Str => Try(List(List(Str)), _)
evaluations! = |cwd| Ok(CliHarness.calls!("${cwd}/roc-calls")?.keep_if(|call| call != ["version"]))

## Run a command that must print `expected`, and require that it probed the
## compiler and then ran it exactly as `compiler_runs` says.
evaluated! : Test, Str, List(Str), Str, List(List(Str)) => Try({}, _)
evaluated! = |test, cwd, args, expected, compiler_runs| {
	CliHarness.forget!("${cwd}/roc-calls")?
	what = "blueprint ${Str.join_with(args, " ")}"
	CliHarness.contains!(run!(test, cwd, args, 0, [])?, expected, what)?
	CliHarness.check!(CliHarness.calls!("${cwd}/roc-calls")?.contains(["version"]), "${what} did not probe the compiler's version")?
	CliHarness.same_calls!(evaluations!(cwd)?, compiler_runs, "${what} did not evaluate the configuration exactly once")
}

cases! : CliHarness.Bench => Try({}, _)
cases! = |bench| {
	search = Env.var_str!(OsStr.from_str("PATH")) ?? ""
	record = "${bench.bin}/roc-record"
	probe = "${bench.bin}/roc-probe"
	wire_roc = "${bench.bin}/roc-wire"
	pin = Path.read_utf8!(Path.utf8("${bench.root}/.roc-version"))?.trim()
	test = {
		bench,
		pin,
		env: CliHarness.setting(
			bench.env,
			[
				("PATH", "${bench.bin}:${search}"),
				("ROC", record),
				("STUB_REAL_ROC", bench.roc),
				("STUB_ROC_VERSION", bench.roc_version),
				("STUB_NIX_FIXTURE", "${bench.root}/fixtures/consumer/inputs.lock"),
				("STUB_NIX_MODE", "declared"),
			],
		),
	}
	work = bench.work

	# These must work without Blueprint.roc.
	CliHarness.check!(CliHarness.is_version(run!(test, work, ["--version"], 0, [])?), "--version did not print a version")?
	CliHarness.contains!(run!(test, work, ["--help"], 0, [])?, "workflow", "--help")?
	CliHarness.contains!(run!(test, work, ["workflow", "--help"], 0, [])?, "workflow", "workflow --help")?
	_ = run!(test, work, ["workflow"], 2, [])?
	_ = run!(test, work, ["unknown-command"], 2, [])?
	CliHarness.contains!(run!(test, work, ["tasks"], 1, [])?, "there is no Blueprint.roc", "tasks without a Blueprint.roc")?
	Script.pass!("without Blueprint.roc: version, help and usage errors (exit 2); tasks says there is no Blueprint.roc")?

	# Every command evaluates the configuration once, with a probed compiler.
	settings!(test, work, CliTest.valid)?
	evaluated!(test, work, ["--help"], "argument-test", [["Blueprint.roc"]])?
	evaluated!(test, work, ["run", "--help"], "echo-args", [["Blueprint.roc"]])?
	evaluated!(test, work, ["shell", "--help"], "ci", [["Blueprint.roc"]])?
	evaluated!(test, work, ["tasks"], "echo-args\t(ci)", [["Blueprint.roc"]])?
	evaluated!(test, work, ["spec"], "(name \"argument-test\")", [["Blueprint.roc"]])?
	evaluated!(test, work, ["flake"], "devShells", [["Blueprint.roc"]])?
	evaluated!(test, work, ["check"], "Blueprint.roc is valid", [["Blueprint.roc"], ["check", "Blueprint.roc"]])?
	untouched!(work)?
	Script.pass!("help, tasks, spec, flake and check: one evaluation each, no provider, nothing generated")?

	# A missing or wrong compiler fails before evaluating any configuration.
	probing = [
		{ name: "missing", overrides: [("ROC", "${bench.bin}/missing")], diagnostic: "could not probe", probes: [] },
		{ name: "wrong", overrides: [("ROC", probe), ("STUB_PROBE_VERSION", "Roc compiler version other-nightly")], diagnostic: "incompatible ROC executable", probes: [["version"]] },
		{ name: "failed", overrides: [("ROC", probe), ("STUB_PROBE_STATUS", "19"), ("STUB_PROBE_VERSION", bench.roc_version.trim())], diagnostic: "could not probe", probes: [["version"]] },
	]
	for case in probing {
		cwd = isolated!(test, "compiler-${case.name}")?
		settings!(test, cwd, CliTest.valid)?
		output = run!(test, cwd, ["spec"], 1, case.overrides)?
		what = "spec with a ${case.name} compiler"
		CliHarness.contains!(output, case.diagnostic, what)?
		CliHarness.contains!(output, pin, what)?
		CliHarness.contains!(output, "set ROC", what)?
		CliHarness.same_calls!(CliHarness.calls!("${cwd}/roc-calls")?, case.probes, "${what} ran the compiler for more than its version")?
		untouched!(cwd)?
		CliHarness.contains!(run!(test, cwd, ["--help"], 0, case.overrides)?, "blueprint", "--help with a ${case.name} compiler")?
		CliHarness.check!(CliHarness.is_version(run!(test, cwd, ["--version"], 0, case.overrides)?), "--version with a ${case.name} compiler did not print a version")?
	}
	Script.pass!("ROC missing, incompatible or failing: refused before any evaluation, naming ${pin}; help and version still work")?

	# Without ROC, a compatible roc on PATH is used as it is. An incompatible
	# or absent one makes the CLI fetch the pinned compiler through the provider.
	fetched = "${work}/fetched-compiler"
	Path.create_all!(Path.utf8("${fetched}/bin"))?
	CliHarness.tool!(["ln", "-s", "--", record, "${fetched}/bin/roc"])?
	for case in [{ name: "path", roc: record }, { name: "fetched", roc: probe }, { name: "absent", roc: "" }] {
		cwd = isolated!(test, "compiler-${case.name}")?
		settings!(test, cwd, CliTest.valid)?
		on_path = "${cwd}/path-bin"
		Path.create_dir!(Path.utf8(on_path))?
		if !case.roc.is_empty() {
			CliHarness.tool!(["ln", "-s", "--", case.roc, "${on_path}/roc"])?
		}
		env = CliHarness.setting(
			CliHarness.unsetting(test.env, ["ROC"]),
			[
				("PATH", "${on_path}:${bench.bin}:/usr/bin:/bin"),
				("STUB_PROBE_VERSION", "Roc compiler version other-nightly"),
				("STUB_NIX_OUT", fetched),
			],
		)
		outcome = CliHarness.blueprint!(bench, cwd, ["spec"], env)?
		CliHarness.exited!(outcome, 0, "spec without ROC, compiler ${case.name}")?
		CliHarness.contains!(outcome.stdout, "(name ", "spec without ROC, compiler ${case.name}")?
		builds = CliHarness.calls!("${cwd}/nix-calls")?.keep_if(|call| call.first() == Ok("build"))
		CliHarness.check!(fetch_matches(case.name == "path", builds, pin), "without ROC and with compiler ${case.name}, the provider was asked to build ${Str.inspect(builds)}")?
	}
	Script.pass!("ROC unset: a compatible roc on PATH is used; otherwise one provider build of roc-overlay#\"${pin}\"")?

	# ROC is invocation-relative even when BLUEPRINT_ROOT selects elsewhere.
	elsewhere = isolated!(test, "compiler-relative-root")?
	settings!(test, elsewhere, CliTest.valid)?
	CliHarness.forget!("${work}/roc-calls")?
	relative = run!(test, work, ["check"], 0, [("ROC", "./bin/roc-record"), ("BLUEPRINT_ROOT", elsewhere)])?
	CliHarness.contains!(relative, "Blueprint.roc is valid", "check with a relative ROC")?
	here = CliHarness.calls!("${work}/roc-calls")?
	CliHarness.check!(!here.is_empty() and here.all(|call| call == ["version"]), "a relative ROC was not probed from the invocation directory: ${Str.inspect(here)}")?
	CliHarness.same_calls!(evaluations!(elsewhere)?, [["Blueprint.roc"], ["check", "Blueprint.roc"]], "a relative ROC did not evaluate in BLUEPRINT_ROOT")?
	untouched!(elsewhere)?
	Script.pass!("ROC=./bin/roc-record: probed from the invocation directory, evaluated in BLUEPRINT_ROOT")?

	# First use cannot initialize pins implicitly, even for plain generation.
	for command in [["gen"], ["shell", "ci"], ["run", "echo-args"]] {
		output = run!(test, work, command, 1, [])?
		what = "blueprint ${Str.join_with(command, " ")} without a lock"
		CliHarness.contains!(output, "missing authoritative lock", what)?
		CliHarness.contains!(output, "blueprint update", what)?
		untouched!(work)?
	}
	update!(test, work)?
	_ = run!(test, work, ["gen"], 0, [])?
	CliHarness.same_calls!(CliHarness.calls!("${work}/nix-calls")?, [], "gen ran the provider")?
	_ = run!(test, work, ["shell", "ci"], 0, [])?
	CliHarness.same_calls!(CliHarness.calls!("${work}/nix-calls")?, [CliTest.develop(work, "ci", [])], "shell ci")?
	CliHarness.forget!("${work}/nix-calls")?
	_ = run!(test, work, ["run", "echo-args", "--", "first", "two words", "--literal", ""], 0, [])?
	CliHarness.same_calls!(
		CliHarness.calls!("${work}/nix-calls")?,
		[CliTest.develop(work, "blueprint-env-ci", CliTest.task.concat(["first", "two words", "--literal", ""]))],
		"run echo-args with arguments after --",
	)?
	Script.pass!("no lock: gen, shell and run refuse and do nothing; after update, exact provider argv, with arguments after -- passed as they are")?

	# `check` reuses the Spec loaded for the command line. It must still refuse
	# an unsupported feature, a configuration that does not compile, and a Raw
	# target that only the provider can refuse.
	settings!(test, work, "${CliTest.valid}	Custom(\"services\", \"demo\", Str(\"value\")),\n")?
	CliHarness.contains!(run!(test, work, ["check"], 1, [])?, "needs features: extensions", "check with a Custom setting")?
	settings!(test, work, "	Environment(\"ci\", [Tools([\"git\"])]),\n	Shell(\"default\", [Use(\"ci\")]),\n")?
	CliHarness.contains!(run!(test, work, ["check"], 1, [])?, "MissingName", "check without a Name")?
	settings!(test, work, "${CliTest.valid}	Raw(\"nix\", \"unknown\", Attrs([])),\n")?
	CliHarness.contains!(run!(test, work, ["check"], 1, [])?, "unknown raw nix target", "check with an unknown Raw target")?
	Script.pass!("check: refuses an unsupported feature, a configuration without a Name and an unknown Raw target")?

	# The real loader must distrust wire data even if a compiler emits it: one
	# case for each place `evaluate!` can refuse it.
	rejected = [
		{ name: "major-3", text: CliTest.wire.replace_each("(major 2)", "(major 3)"), diagnostic: "Spec format 3.0" },
		{ name: "workflow-tag", text: CliTest.workflow_wire.replace_each("RunTask \"echo-args\" ()", "FutureStep \"echo-args\""), diagnostic: "could not read the Spec from Blueprint.roc" },
		{ name: "requires", text: "${CliTest.wire.drop_suffix(")")}(requires (\"future-operation\")))", diagnostic: "needs features: future-operation" },
		{ name: "reference", text: CliTest.wire.replace_each("(environment \"ci\")", "(environment \"missing\")"), diagnostic: "unknown environment: missing" },
	]
	for case in rejected {
		cwd = wired!(test, "wire-${case.name}", case.text)?
		output = run!(test, cwd, ["run", "echo-args"], 1, [("ROC", wire_roc)])?
		CliHarness.contains!(output, case.diagnostic, "run echo-args with the ${case.name} wire Spec")?
		untouched!(cwd)?
	}
	# Same-major future minors and optional fields remain forward compatible.
	future = wired!(test, "wire-future-minor", "${CliTest.wire.replace_each("(minor 0)", "(minor 999)").drop_suffix(")")}(future-field (Future \"ignored\")))")?
	accepted = run!(test, future, ["spec"], 0, [("ROC", wire_roc)])?
	CliHarness.contains!(accepted, "(minor 999)", "spec of a future minor")?
	CliHarness.contains!(accepted, "(name \"wire\")", "spec of a future minor")?
	untouched!(future)?
	# A future minor preserves known workflow steps, rather than ignoring them.
	future_flow = wired!(test, "wire-workflow-future-minor", CliTest.workflow_wire.replace_each("(minor 2)", "(minor 999)"))?
	preserved = run!(test, future_flow, ["spec"], 0, [("ROC", wire_roc)])?
	CliHarness.contains!(preserved, "(minor 999)", "spec of a future minor with a workflow")?
	CliHarness.contains!(preserved, "(RunTask \"echo-args\" ())", "spec of a future minor with a workflow")?
	CliHarness.contains!(preserved, "(workflows (", "spec of a future minor with a workflow")?
	untouched!(future_flow)?
	Script.pass!("untrusted wire Spec: other major, unknown step, unknown feature and dangling reference refused before any effect; a future minor is read, with its workflow steps")?

	# Request checks precede every Nix, workspace and lock effect. These use
	# the real compiler: Auto grammar is deliberately checked after selection.
	incompatible = [
		{ name: "source", command: ["shell", "ci"], tool: "git", declaration: "Packages(\"default\", From(GuixPackages(\"current\"))),", diagnostic: "source default requires Guix, not Nix" },
		{ name: "auto-grammar", command: ["run", "echo-args"], tool: "python@3.12:out", declaration: "Packages(\"default\", Auto),", diagnostic: "invalid Nix tool: python@3.12:out" },
	]
	for case in incompatible {
		cwd = isolated!(test, "request-${case.name}")?
		settings!(test, cwd, "${CliTest.valid.replace_each("Tools([\"git\"])", "Tools([\"${case.tool}\"])")}	${case.declaration}\n")?
		output = run!(test, cwd, case.command, 1, [])?
		CliHarness.contains!(output, case.diagnostic, "blueprint ${Str.join_with(case.command, " ")} with an incompatible ${case.name}")?
		untouched!(cwd)?
	}
	Script.pass!("a request the Nix provider cannot serve is refused before any provider, workspace or lock effect")?

	# An unselected Guix environment, even one with a shell alias, must not
	# contaminate a Nix task's requested dependency closure.
	foreign = Str.join_with(
		[
			"	Packages(\"foreign\", From(GuixPackages(\"current\"))),",
			"	Overlay(\"foreign-overlay\", \"github:example/unused-overlay\"),",
			"	Environment(\"foreign\", [Tools([\"foreign#python@3.12:out\"]), Overlays([\"foreign-overlay\"])]),",
			"",
		],
		"\n",
	)
	closure = isolated!(test, "closure")?
	settings!(test, closure, "${CliTest.valid}${foreign}")?
	update!(test, closure)?
	# Adding an alias does not change input/overlay lock identity.
	settings!(test, closure, "${CliTest.valid}${foreign}	Shell(\"foreign\", [Use(\"foreign\")]),\n")?
	_ = run!(test, closure, ["run", "echo-args"], 0, [])?
	CliHarness.same_calls!(CliHarness.calls!("${closure}/nix-calls")?, [CliTest.develop(closure, "blueprint-env-ci", CliTest.task)], "run echo-args beside a Guix environment")?
	CliHarness.same_calls!(CliHarness.calls!("${closure}/guix-calls")?, [], "Guix ran for a Nix task")?
	rendered = Path.read_utf8!(Path.utf8("${closure}/.blueprint/flake.nix"))?
	CliHarness.check!(!rendered.contains("python@3.12:out") and !rendered.contains("blueprint-env-foreign"), "the generated flake holds the unselected Guix environment:\n${rendered}")?
	# Stable declarations may mention an unused overlay, but neither the
	# selected package imports nor their overlay stack may use it.
	outputs = Str.join_with(rendered.split_on("  outputs =").drop_first(1), "  outputs =")
	CliHarness.check!(!outputs.is_empty() and !outputs.contains("foreign-overlay") and outputs.contains("overlays = [  ];"), "the generated flake's outputs use the unselected overlay:\n${outputs}")?
	Script.pass!("an unselected Guix environment with a shell alias: the Nix task's flake holds neither its tools nor its overlay")?

	# The Core rejects a lock whose recorded intent no longer matches the
	# Spec, naming what changed, before the provider plans anything.
	stale = isolated!(test, "stale-intent")?
	settings!(test, stale, CliTest.valid)?
	update!(test, stale)?
	settings!(test, stale, "${CliTest.valid}	Input(\"utils\", \"github:numtide/flake-utils\"),\n")?
	CliHarness.contains!(run!(test, stale, ["run", "echo-args"], 1, [])?, "changed its inputs since the lock was resolved", "run echo-args with a stale lock")?
	CliHarness.same_calls!(CliHarness.calls!("${stale}/nix-calls")?, [], "the provider ran with a stale lock")?
	Script.pass!("a lock resolved for other inputs is refused, naming them, before the provider runs")?

	# Pure layout validation must precede even lock reads and source effects.
	# The generated directory may contain work, but its files may not.
	collisions = [
		{ name: "gen", command: ["gen"], workspace: "flake.nix" },
		{ name: "build", command: ["build", "app"], workspace: "flake.lock/child" },
		{ name: "update", command: ["update"], workspace: "flake.nix/child" },
	]
	for case in collisions {
		cwd = isolated!(test, "collision-${case.name}")?
		settings!(test, cwd, "${CliTest.valid}	Build(\"app\", [Use(\"ci\"), Run([\"true\"]), Output(\"result\")]),\n")?
		generated = "${cwd}/generated"
		output = run!(test, cwd, case.command, 1, [("BLUEPRINT_GENERATED_ROOT", generated), ("BLUEPRINT_WORKSPACE", "${generated}/${case.workspace}")])?
		CliHarness.contains!(output, "must not overlap", "blueprint ${case.name} with its workspace at ${case.workspace}")?
		CliHarness.check!(!CliHarness.present!(generated), "a layout collision caused staging in ${generated}")?
		untouched!(cwd)?
	}
	Script.pass!("gen, build and update refuse a workspace that is or lies under a generated file, before staging")?

	# A failed native command is final: no retries, package translation or
	# switching to the installed Guix stub. Preserve its diagnostic and code.
	failures = [
		{ name: "shell", command: ["shell", "ci"], diagnostic: "exited with code 23", entry: "ci", argv: [] },
		{ name: "run", command: ["run", "echo-args"], diagnostic: "task echo-args exited with code 23", entry: "blueprint-env-ci", argv: CliTest.task },
	]
	for case in failures {
		cwd = isolated!(test, "no-fallback-${case.name}")?
		settings!(test, cwd, CliTest.valid)?
		update!(test, cwd)?
		output = run!(test, cwd, case.command, 1, [("STUB_NIX_FAIL", "1")])?
		what = "blueprint ${Str.join_with(case.command, " ")} when Nix fails"
		CliHarness.contains!(output, "native package command failed", what)?
		CliHarness.contains!(output, case.diagnostic, what)?
		CliHarness.same_calls!(CliHarness.calls!("${cwd}/nix-calls")?, [CliTest.develop(cwd, case.entry, case.argv)], "${what}: the provider was not run exactly once")?
		CliHarness.same_calls!(CliHarness.calls!("${cwd}/guix-calls")?, [], "${what}: Guix ran")?
	}
	Script.pass!("a failing provider command is final: one run, its diagnostic and code 23 reported, no Guix")?

	# The workflow executor consumes one complete plan, never reloads per step.
	flow = isolated!(test, "workflow-single-load")?
	settings!(
		test,
		flow,
		Str.join_with(
			[
				CliTest.valid.drop_suffix("\n"),
				"	Workflow(\"ci\", [RunTask(\"echo-args\", [\"\", \"--\"]), RunWorkflow(\"again\")]),",
				"	Workflow(\"again\", [RunTask(\"echo-args\", [\"line\\nbreak\", \"a'b\\\"c\"])]),",
				"",
			],
			"\n",
		),
	)?
	CliHarness.contains!(run!(test, flow, ["workflow", "absent"], 1, [])?, "unknown workflow: absent", "workflow absent")?
	untouched!(flow)?
	update!(test, flow)?
	CliHarness.forget!("${flow}/roc-calls")?
	_ = run!(test, flow, ["workflow", "ci"], 0, [])?
	CliHarness.same_calls!(CliHarness.calls!("${flow}/roc-calls")?, [["version"], ["Blueprint.roc"]], "workflow ci did not load the configuration exactly once")?
	CliHarness.same_calls!(
		CliHarness.calls!("${flow}/nix-calls")?,
		[
			CliTest.develop(flow, "blueprint-env-ci", CliTest.task.concat(["", "--"])),
			CliTest.develop(flow, "blueprint-env-ci", CliTest.task.concat(["line\nbreak", "a'b\"c"])),
		],
		"workflow ci",
	)?
	Script.pass!("workflow ci: one evaluation, then each step's exact argv in order")?

	Script.pass!("CLI compiler/loader, validation and stubbed process-boundary tests passed")
}

## What the provider was asked to build for a compiler: nothing when the one
## on PATH is compatible, otherwise the pinned release from roc-overlay, once.
fetch_matches : Bool, List(List(Str)), Str -> Bool
fetch_matches = |on_path, builds, pin|
	match builds {
		[] => on_path
		[["build", "--no-link", "--print-out-paths", installable]] =>
			!on_path and installable.starts_with("github:roc-lang/roc-overlay/") and installable.ends_with("#\"${pin}\"")

		_ => False
	}

expect CliTest.blueprint_roc("../p/main.roc", "	Name(\"x\"),\n") == "app [config] { pf: platform \"../p/main.roc\" }\nconfig = [\n	Name(\"x\"),\n]\n"
expect CliTest.valid.contains("Run([\"printf\", \"%s\\n\", \"configured argument\"])")

expect CliTest.develop("/p", "ci", []) == ["develop", "--no-update-lock-file", "--no-write-lock-file", "path:/p/.blueprint#devShells.x86_64-linux.ci"]
expect CliTest.develop("/p", "blueprint-env-ci", ["printf", ""]) == ["develop", "--no-update-lock-file", "--no-write-lock-file", "path:/p/.blueprint#devShells.x86_64-linux.blueprint-env-ci", "--command", "printf", ""]

expect CliTest.wire.starts_with("((format ((major 2) (minor 0))) (name \"wire\")\n") and CliTest.wire.ends_with("(run (\"true\"))))))")
expect CliTest.workflow_wire.ends_with("(run (\"true\")))))(requires (\"workflows\")) (workflows (((name \"ci\") (steps ((RunTask \"echo-args\" ())))))))")

expect fetch_matches(True, [], "nightly-x") and !fetch_matches(False, [], "nightly-x")
expect fetch_matches(False, [["build", "--no-link", "--print-out-paths", "github:roc-lang/roc-overlay/abc?narHash=sha256-x#\"nightly-x\""]], "nightly-x")
expect !fetch_matches(True, [["build", "--no-link", "--print-out-paths", "github:roc-lang/roc-overlay/abc#\"nightly-x\""]], "nightly-x")
expect !fetch_matches(False, [["build", "--no-link", "--print-out-paths", "github:other/overlay#\"nightly-x\""]], "nightly-x")
expect !fetch_matches(False, [["build", "--no-link", "--print-out-paths", "github:roc-lang/roc-overlay/abc#\"nightly-y\""]], "nightly-x")
expect !fetch_matches(False, [["build", "github:roc-lang/roc-overlay/abc#\"nightly-x\""]], "nightly-x")

native_sample : Str
native_sample =
	\\{"nodes":{"default":{"locked":{"rev":"abc"}}},"version":7}

authority_sample : Str
authority_sample = Lock.to_str(
	Lock.{
		format: Lock.current_format,
		intent: Lock.empty_intent,
		sources: [],
		hints: [{ provider: "nix", value: Locks.to_value(LockJson.decode("{\"graph\":${native_sample}}") ?? LockJson.Null) }],
	},
)

expect pins_match(authority_sample, native_sample)
expect pins_match(authority_sample, "{\"version\":7,\"nodes\":{\"default\":{\"locked\":{\"rev\":\"abc\"}}}}")
expect !pins_match(authority_sample, native_sample.replace_each("abc", "abd"))
expect !pins_match(authority_sample.replace_each("(major 1)", "(major 2)"), native_sample)
expect !pins_match(native_sample, native_sample)
