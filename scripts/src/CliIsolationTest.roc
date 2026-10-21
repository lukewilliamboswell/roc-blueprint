import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import core.Project
import CliHarness
import Integrity
import Script

## What `blueprint build` stages about its caller, against a stubbed compiler
## and Nix.
##
## The stubbed Nix never builds: these cases observe only what `blueprint
## build` stages before it runs the provider: the caller's namespaces in a
## private runtime witness, separate from the reproducible derivation. `PATH` holds
## the stubs, `readlink` and a `python3` that records any use, and nothing
## else, so the CLI is shown to need no Python and no `chmod` of its own.
CliIsolationTest := [].{

	## Run every case from the repository root, in a temporary directory that is
	## removed afterwards.
	run! : Path => Try({}, _)
	run! = |repository| {
		bench = CliHarness.open!(repository, "blueprint-isolation-", ["roc-wire", "nix", "python3"])?
		result = cases!(bench)
		CliHarness.close!(bench)
		result
	}

	## The Spec the stub compiler prints: one build, `app`.
	wire : Str
	wire =
		\\((format ((major 2) (minor 1))) (name "wire")
		\\(requires ("explicit-sources" "builds"))
		\\(systems ("x86_64-linux"))
		\\(sources (((name "default") (provider (NixPackages "github:NixOS/nixpkgs/nixos-unstable")))))
		\\(environments (((name "ci") (parents ()) (tools ()) (overlays ()))))
		\\(shells (((name "default") (environment "ci"))))
		\\(builds (((name "app") (environment "ci") (inputs ()) (needs ())
		\\          (run ("true")) (output "result")))))

	## What the stub Nix prints as the built artifact.
	store : Str
	store = "/nix/store/00000000000000000000000000000000-blueprint-app"

	## Stable recipe bytes refer to the project and a versioned provider runner.
	staged : Str -> List(Str)
	staged = |root| [
		"runnerSource = ",
		"blueprint-build-runner-v1",
		"builder = runner;",
		"path = /. + \"${root}\";",
		"|| builtins.elem path [ \"${root}/.blueprint\" \"${root}/Blueprint.lock\" ])",
		"throw \"snapshot refuses symlink: \${path}\"",
		"throw \"snapshot refuses special file: \${path}\"",
	]

}

Test : { bench : CliHarness.Bench, env : List((OsStr, OsStr)) }

run! : Test, Str, List(Str), List((Str, Str)) => Try(CliHarness.Outcome, _)
run! = |test, root, args, extra|
	CliHarness.blueprint!(test.bench, root, args, CliHarness.setting(test.env, extra))

## How many times the provider was asked to build in this project.
builds! : Str => Try(U64, _)
builds! = |root| Ok(CliHarness.calls!("${root}/nix-calls")?.keep_if(|call| call.first() == Ok("build")).len())

## A project with a resolved lock.
project! : Test, Str => Try(Str, _)
project! = |test, name| {
	root = "${test.bench.work}/${name}"
	Path.create_dir!(Path.utf8(root))?
	Path.write_utf8!(Path.utf8("${root}/Blueprint.roc"), "stub\n")?
	Path.write_utf8!(Path.utf8("${root}/wire.scm"), CliIsolationTest.wire)?
	CliHarness.exited!(run!(test, root, ["update"], [])?, 0, "blueprint update in ${name}")?
	Ok(root)
}

## Every file below a directory.
files! : Str => Try(List(Str), _)
files! = |directory| {
	var $files = []
	for name in CliHarness.names!(directory)? {
		entry = "${directory}/${name}"
		if Path.is_dir!(Path.utf8(entry)) ?? False {
			$files = $files.concat(files!(entry)?)
		} else {
			$files = $files.append(entry)
		}
	}
	Ok($files)
}

## Everything under the generated root, by bytes and inode.
state! : Str => Try(List(Str), _)
state! = |root| {
	var $state = []
	for file in files!("${root}/.blueprint")?.sort_with(Project.bytewise) {
		bytes = Path.read_bytes!(Path.utf8(file))?
		$state = $state.append("${file} ${Integrity.digest(bytes)} ${CliHarness.stat!("%i", file)?}")
	}
	Ok($state)
}

## A refused build never reaches the provider or restages anything.
refused! : Test, Str, Str, Str, List((Str, Str)) => Try({}, _)
refused! = |test, root, program, message, extra| {
	builds_before = builds!(root)?
	state_before = state!(root)?
	Stdout.line!("RUN  ${program} build app")?
	outcome = CliHarness.invoke!({ program, args: ["build", "app"], cwd: root, env: CliHarness.setting(test.env, extra) })?
	CliHarness.check!(
		outcome.code == 1 and outcome.stderr.contains(message),
		"a build that must be refused with ${Str.inspect(message)} exited with code ${outcome.code.to_str()}:\n${outcome.stderr}",
	)?
	CliHarness.check!(builds!(root)? == builds_before and state!(root)? == state_before, "the build refused with ${Str.inspect(message)} had effects")
}

## The identity of one of this process's namespaces, which `blueprint`, its
## child, shares.
namespace! : Str, Str => Try(Str, _)
namespace! = |readlink, name| {
	outcome = CliHarness.invoke!({ program: readlink, args: ["/proc/self/ns/${name}"], cwd: "/", env: [] })?
	CliHarness.exited!(outcome, 0, "readlink /proc/self/ns/${name}")?
	Ok(outcome.stdout.trim())
}

cases! : CliHarness.Bench => Try({}, _)
cases! = |bench| {
	readlink = match CliHarness.which!("readlink", Env.var_str!(OsStr.from_str("PATH")) ?? "") {
		Ok(found) => found
		Err(_) => return Script.fail!("readlink not found")
	}
	CliHarness.tool!(["ln", "-s", "--", readlink, "${bench.bin}/readlink"])?
	python_log = "${bench.work}/python3-was-used"
	# Nothing of this process's environment reaches the CLI.
	test = {
		bench,
		env: CliHarness.setting(
			[],
			[
				("PATH", bench.bin),
				("HOME", bench.work),
				("ROC", "${bench.bin}/roc-wire"),
				("NO_COLOR", "1"),
				("STUB_ROC_VERSION", bench.roc_version),
				("STUB_NIX_OUT", CliIsolationTest.store),
				("STUB_NIX_FIXTURE", "${bench.root}/blueprint-nix/tests/local.nix-lock.json"),
				("STUB_NIX_MODE", "local"),
				("STUB_PYTHON_LOG", python_log),
				("STUB_NIX_ISOLATION_LOG", "${bench.work}/runtime-witness.json"),
			],
		),
	}
	work = bench.work

	# Caller namespace observations are runtime authorization, never recipe bytes.
	root = project!(test, "ordinary")?
	sources = [
		{ file: "plain", mode: "644" },
		{ file: "tool", mode: "755" },
		{ file: "odd", mode: "654" },
		{ file: "setuid", mode: "4755" },
		{ file: "nested/deep/file", mode: "640" },
	]
	Path.create_all!(Path.utf8("${root}/nested/deep"))?
	for source in sources {
		Path.write_bytes!(Path.utf8("${root}/${source.file}"), source.file.to_utf8().concat([0xff, 0x00, '\n']))?
		CliHarness.tool!(["chmod", source.mode, "--", "${root}/${source.file}"])?
	}
	Path.write_utf8!(Path.utf8("${root}/.blueprint/excluded-secret"), "workspace excluded\n")?
	before = builds!(root)?
	built = run!(test, root, ["build", "app"], [])?
	CliHarness.exited!(built, 0, "blueprint build app")?
	CliHarness.check!(built.stdout == "${CliIsolationTest.store}\n", "build app printed ${Str.inspect(built.stdout)}, not the artifact")?
	CliHarness.check!(builds!(root)? == before + 1, "build app did not run exactly one provider build")?
	flake = Path.read_utf8!(Path.utf8("${root}/.blueprint/flake.nix"))?
	caller = { mnt: namespace!(readlink, "mnt")?, net: namespace!(readlink, "net")? }
	for expected in CliIsolationTest.staged(root) {
		CliHarness.contains!(flake, expected, "the staged flake")?
	}
	CliHarness.check!(!flake.contains("@blueprint-caller"), "the staged flake still holds a placeholder:\n${flake}")?
	CliHarness.check!(!flake.contains(caller.mnt) and !flake.contains(caller.net) and !flake.contains(bench.blueprint), "caller or executable identity entered the derivation")?
	observed = captured!(test)?
	CliHarness.check!(observed.witness == "${caller.mnt}\n${caller.net}\n", "runtime witness did not capture caller namespaces")?
	CliHarness.check!(observed.directory.starts_with("${root}/.blueprint/isolation/") and !CliHarness.present!(observed.directory), "runtime witness was not private and cleaned after the command")?
	# The CLI copies no project snapshot or executable; runtime witnesses are temporary.
	generated = CliHarness.names!("${root}/.blueprint")?.sort_with(Project.bytewise)
	CliHarness.check!(generated == [".gitignore", "excluded-secret", "flake.lock", "flake.nix", "isolation"], "the generated root holds ${Str.join_with(generated, " ")}")?
	for source in sources {
		kept = CliHarness.stat!("%a %h", "${root}/${source.file}")?
		CliHarness.check!(kept == "${source.mode} 1", "${source.file} now has mode and link count ${kept}, not ${source.mode} 1")?
	}
	# An unchanged caller stages identical bytes, so Nix can reuse the build.
	CliHarness.exited!(run!(test, root, ["build", "app"], [])?, 0, "a second blueprint build app")?
	CliHarness.check!(Path.read_utf8!(Path.utf8("${root}/.blueprint/flake.nix"))? == flake, "a second build staged a different flake")?
	second = captured!(test)?
	CliHarness.check!(second.directory != observed.directory and !CliHarness.present!(second.directory), "two builds reused a mutable witness or left it behind")?
	Script.pass!("build app: private caller witness is cleaned; derivation excludes namespace/CLI identity and stays unchanged across invocations")?

	# Isolation that cannot be observed or is malformed stops before staging.
	shadow = "${work}/shadow"
	CliHarness.install!(bench, shadow, ["readlink"])?
	shadowed = ("PATH", "${shadow}:${bench.bin}")
	refused!(test, root, bench.blueprint, "cannot observe caller build isolation; use Linux with readable /proc/self/ns/mnt", [shadowed])?
	# The mount namespace reads well; the same text is no network namespace.
	refused!(test, root, bench.blueprint, "invalid caller net namespace identity", [shadowed, ("STUB_READLINK", "mnt:[1]")])?
	Path.delete_all!(Path.utf8(shadow))?
	empty = "${work}/no-readlink"
	Path.create_dir!(Path.utf8(empty))?
	for name in ["roc-wire", "nix", "python3"] {
		CliHarness.tool!(["ln", "-s", "--", "${bench.bin}/${name}", "${empty}/${name}"])?
	}
	refused!(test, root, bench.blueprint, "cannot observe caller build isolation", [("PATH", empty)])?
	Script.pass!("a readlink that fails, is absent, or names a namespace wrongly: the build is refused before the provider or any staging")?

	# The CLI path is no longer recipe input, so unusual executable paths work.
	for name in ["quo\"te", "dol\$lar", "back\\slash"] {
		odd = "${work}/${name}"
		Path.create_dir!(Path.utf8(odd))?
		Path.copy!(Path.utf8(bench.blueprint), Path.utf8("${odd}/blueprint"))?
		result = CliHarness.invoke!({ program: "${odd}/blueprint", args: ["build", "app"], cwd: root, env: test.env })?
		CliHarness.exited!(result, 0, "build from unusual CLI path")?
		CliHarness.check!(Path.read_utf8!(Path.utf8("${root}/.blueprint/flake.nix"))? == flake, "CLI path changed the recipe")?
	}
	Script.pass!("quotes, dollars and backslashes in the CLI executable's path do not enter the derivation")?

	# A symlinked generated root is refused, not followed.
	linked = project!(test, "linked-workspace")?
	real = "${work}/real-workspace"
	Path.create_dir!(Path.utf8(real))?
	CliHarness.tool!(["ln", "-s", "--", real, "${linked}/work"])?
	linked_before = builds!(linked)?
	followed = run!(test, linked, ["build", "app"], [("BLUEPRINT_WORKSPACE", "work")])?
	CliHarness.check!(followed.code == 1 and followed.stderr.contains("unsafe"), "a build into a symlinked workspace exited with code ${followed.code.to_str()}:\n${followed.stderr}")?
	CliHarness.check!(builds!(linked)? == linked_before and CliHarness.names!(real)?.is_empty(), "a build into a symlinked workspace reached the provider or wrote through the link")?
	Script.pass!("a workspace that is a link: refused as unsafe, nothing written through it")?

	help = run!(test, linked, ["--help"], [])?
	CliHarness.check!(!help.stdout.contains("__build-runner"), "--help exposes an obsolete runner entrypoint")?

	used = CliHarness.calls!(python_log)?
	CliHarness.check!(used.is_empty(), "blueprint ran a host python3: ${Str.inspect(used)}")?
	Script.pass!("Build runtime witness, stable recipe and refusal tests passed without a host Python or chmod (stubbed Nix/compiler)")
}

captured! : Test => Try({ directory : Str, witness : Str }, _)
captured! = |test| {
	text = Path.read_utf8!(Path.utf8("${test.bench.work}/runtime-witness.json"))?
	Json.parse(text).map_err(|_| ScriptFailed)
}

expect CliIsolationTest.wire.contains("(builds (((name \"app\")") and CliIsolationTest.wire.contains("(requires (\"explicit-sources\" \"builds\"))")
