import cli.Env
import cli.OsStr
import cli.Path
import CliHarness
import RocPackagesTest
import Script

## The real `./blueprint` and the real compiler with the host provider, on a
## machine that is not Windows. `BLUEPRINT_PROVIDER=host` selects the provider;
## Nix is a stub that must not run after `blueprint update` has written the
## lock, which is done with the Nix provider as a project's Linux users would.
CliHostTest := [].{

	## Run every case from the repository root, in a temporary directory that is
	## removed afterwards.
	run! : Path => Try({}, _)
	run! = |repository| {
		bench = CliHarness.open!(repository, "blueprint-host-", ["roc-record", "nix"])?
		result = cases!(bench)
		CliHarness.close!(bench)
		result
	}

	## A Blueprint.roc with these settings, for the platform at this path.
	blueprint_roc : Str, List(Str) -> Str
	blueprint_roc = |platform_path, settings| "app [config] { pf: platform \"${platform_path}\" }\nconfig = [\n${Str.join_with(settings.map(|line| "\t${line}\n"), "")}]\n"

	## One environment that declares nothing, a shell, a task and a build.
	plain : List(Str)
	plain = [
		"Name(\"host-test\"),",
		"Environment(\"plain\", []),",
		"Shell(\"default\", [Use(\"plain\")]),",
		"Task(\"say\", [Use(\"plain\"), Run([\"printf\", \"%s\\n\", \"configured argument\"])]),",
		"Build(\"app\", [Use(\"plain\"), Run([\"true\"]), Output(\"out\")]),",
	]
}

Test : { bench : CliHarness.Bench, env : List((OsStr, OsStr)) }

## The variable that selects the host provider.
host : (Str, Str)
host = ("BLUEPRINT_PROVIDER", "host")

## Run `./blueprint` and return everything it printed. The authority must be
## the same file afterwards, with the same bytes, not written since.
run! : Test, Str, List(Str), I32, List((Str, Str)) => Try(Str, _)
run! = |test, cwd, args, status, overrides| {
	authority = "${cwd}/Blueprint.lock"
	before = CliHarness.identity!(authority)?
	outcome = CliHarness.blueprint!(test.bench, cwd, args, CliHarness.setting(test.env, overrides))?
	what = "blueprint ${Str.join_with(args, " ")}"
	CliHarness.exited!(outcome, status, what)?
	CliHarness.check!(CliHarness.identity!(authority)? == before, "${what} changed the authority ${authority}")?
	Ok("${outcome.stdout}${outcome.stderr}")
}

## A new project directory holding a Blueprint.roc with these settings.
project! : Test, Str, List(Str) => Try(Str, _)
project! = |test, name, settings| {
	cwd = "${test.bench.work}/${name}"
	Path.create_dir!(Path.utf8(cwd))?
	platform_path = RocPackagesTest.relative(cwd, "${test.bench.root}/blueprint-platform/main.roc")
	Path.write_utf8!(Path.utf8("${cwd}/Blueprint.roc"), CliHostTest.blueprint_roc(platform_path, settings))?
	Ok(cwd)
}

## Write the lock as a Linux user does, with the Nix provider, then forget
## that Nix ran: nothing after this may run it.
lock! : Test, Str => Try({}, _)
lock! = |test, cwd| {
	outcome = CliHarness.blueprint!(test.bench, cwd, ["update"], test.env)?
	CliHarness.exited!(outcome, 0, "blueprint update with the Nix provider")?
	CliHarness.tool!(["chmod", "0444", "--", "${cwd}/Blueprint.lock"])?
	Path.delete_all!(Path.utf8("${cwd}/.blueprint"))?
	CliHarness.forget!("${cwd}/nix-calls")
}

## Nix did not run and nothing was generated.
without_nix! : Str => Try({}, _)
without_nix! = |cwd| {
	CliHarness.same_calls!(CliHarness.calls!("${cwd}/nix-calls")?, [], "Nix ran in ${cwd}")?
	CliHarness.check!(!CliHarness.present!("${cwd}/.blueprint/flake.nix"), "${cwd}/.blueprint/flake.nix was generated")
}

cases! : CliHarness.Bench => Try({}, _)
cases! = |bench| {
	search = Env.var_str!(OsStr.from_str("PATH")) ?? ""
	test = {
		bench,
		env: CliHarness.setting(
			bench.env,
			[
				("PATH", "${bench.bin}:${search}"),
				("ROC", "${bench.bin}/roc-record"),
				("STUB_REAL_ROC", bench.roc),
				("STUB_NIX_FIXTURE", "${bench.root}/fixtures/consumer/inputs.lock"),
				("STUB_NIX_MODE", "declared"),
			],
		),
	}

	# Only `host` selects a provider; anything else is refused by name.
	unknown = project!(test, "unknown-provider", CliHostTest.plain)?
	CliHarness.contains!(run!(test, unknown, ["tasks"], 1, [("BLUEPRINT_PROVIDER", "guix")])?, "BLUEPRINT_PROVIDER selects the host provider with `host` and takes no other value, not \"guix\"", "tasks with an unknown provider")?
	CliHarness.check!(CliHarness.is_version(run!(test, unknown, ["--version"], 0, [("BLUEPRINT_PROVIDER", "guix")])?), "--version with an unknown provider did not print a version")?
	Script.pass!("BLUEPRINT_PROVIDER: an unknown provider is refused by name; --version still works")?

	# Reading the configuration needs no lock and no provider program.
	reading = project!(test, "reading", CliHostTest.plain)?
	CliHarness.contains!(run!(test, reading, ["tasks"], 0, [host])?, "say\t(plain)", "tasks")?
	CliHarness.contains!(run!(test, reading, ["spec"], 0, [host])?, "(name \"host-test\")", "spec")?
	CliHarness.contains!(run!(test, reading, ["check"], 0, [host])?, "Blueprint.roc is valid", "check")?
	CliHarness.check!(run!(test, reading, ["flake"], 0, [host])? == "", "flake printed a file the host provider does not generate")?
	without_nix!(reading)?
	Script.pass!("host provider: tasks, spec and check work; there is no generated file to print")?

	# What only Nix can do is refused before any effect, and says what to do.
	CliHarness.contains!(run!(test, reading, ["update"], 1, [host])?, "run `blueprint update` on Linux or macOS and commit Blueprint.lock", "update")?
	CliHarness.check!(!CliHarness.present!("${reading}/Blueprint.lock"), "a refused update wrote Blueprint.lock")?
	CliHarness.contains!(run!(test, reading, ["shell"], 1, [host])?, "a shell needs Nix, which this host does not have; run the task with `blueprint run`", "shell")?
	CliHarness.contains!(run!(test, reading, ["build", "app"], 1, [host])?, "a sandboxed build needs Nix on Linux, which this host does not have", "build")?
	CliHarness.contains!(run!(test, reading, ["run", "say"], 1, [host])?, "missing authoritative lock", "run without a lock")?
	without_nix!(reading)?
	Script.pass!("host provider: update, shell and build are refused, and a task still needs the lock")?

	# The lock the Nix provider wrote is the lock a task runs from here.
	running = project!(test, "running", CliHostTest.plain)?
	lock!(test, running)?
	CliHarness.check!(run!(test, running, ["run", "say"], 0, [host])? == "configured argument\n", "run say did not run the task's argv")?
	CliHarness.check!(run!(test, running, ["run", "say", "--", "extra one", "two"], 0, [host])? == "configured argument\nextra one\ntwo\n", "run say did not pass the extra arguments")?
	_ = run!(test, running, ["gen"], 0, [host])?
	without_nix!(running)?
	Script.pass!("host provider: a task runs from the lock the Nix provider wrote, without Nix; gen generates nothing")?

	# An environment's declarations are not ignored: a task that needs one is refused.
	tooled = project!(test, "tooled", CliHostTest.plain.concat(["Environment(\"dev\", [Extend(\"plain\"), Tools([\"git\"])]),", "Task(\"status\", [Use(\"dev\"), Run([\"git\", \"status\"])]),"]))?
	lock!(test, tooled)?
	CliHarness.contains!(run!(test, tooled, ["run", "status"], 1, [host])?, "environment dev declares tools, which this host cannot supply: git", "run with a declared tool")?
	without_nix!(tooled)?
	Script.pass!("host provider: a task whose environment declares a tool is refused, naming it")
}

expect CliHostTest.blueprint_roc("../pf/main.roc", ["Name(\"a\"),"]) == "app [config] { pf: platform \"../pf/main.roc\" }\nconfig = [\n\tName(\"a\"),\n]\n"
