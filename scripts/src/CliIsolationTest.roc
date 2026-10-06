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
## build` stages before it runs the provider, namely the caller's namespace
## identities and the CLI's own executable as the build runner. `PATH` holds
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
		\\(requires ("builds"))
		\\(systems ("x86_64-linux"))
		\\(sources (((name "default") (provider Auto))))
		\\(environments (((name "ci") (parents ()) (tools ()) (overlays ()))))
		\\(shells (((name "default") (environment "ci"))))
		\\(builds (((name "app") (environment "ci") (inputs ()) (needs ())
		\\          (run ("true")) (output "result")))))

	## What the stub Nix prints as the built artifact.
	store : Str
	store = "/nix/store/00000000000000000000000000000000-blueprint-app"

	## What the staged flake must say about its caller and its project.
	staged : { mnt : Str, net : Str, runner : Str, root : Str } -> List(Str)
	staged = |caller| [
		"isolation = { mnt = \"${caller.mnt}\"; net = \"${caller.net}\"; };",
		"runner = builtins.path { path = /. + \"${caller.runner}\"; name = \"blueprint-runner\"; };",
		# Nix reads the project where it is, minus caller-generated state.
		"path = /. + \"${caller.root}\";",
		"|| builtins.elem path [ \"${caller.root}/.blueprint\" \"${caller.root}/Blueprint.lock\" ])",
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
			],
		),
	}
	work = bench.work

	# An ordinary build stages its caller's namespaces and its own executable.
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
	caller = { mnt: namespace!(readlink, "mnt")?, net: namespace!(readlink, "net")?, runner: bench.blueprint, root }
	for expected in CliIsolationTest.staged(caller) {
		CliHarness.contains!(flake, expected, "the staged flake")?
	}
	CliHarness.check!(!flake.contains("@blueprint-caller"), "the staged flake still holds a placeholder:\n${flake}")?
	# The CLI copies nothing: no snapshot, witness file or runner in its state.
	generated = CliHarness.names!("${root}/.blueprint")?.sort_with(Project.bytewise)
	CliHarness.check!(generated == ["excluded-secret", "flake.lock", "flake.nix"], "the generated root holds ${Str.join_with(generated, " ")}")?
	for source in sources {
		kept = CliHarness.stat!("%a %h", "${root}/${source.file}")?
		CliHarness.check!(kept == "${source.mode} 1", "${source.file} now has mode and link count ${kept}, not ${source.mode} 1")?
	}
	# An unchanged caller stages identical bytes, so Nix can reuse the build.
	CliHarness.exited!(run!(test, root, ["build", "app"], [])?, 0, "a second blueprint build app")?
	CliHarness.check!(Path.read_utf8!(Path.utf8("${root}/.blueprint/flake.nix"))? == flake, "a second build staged a different flake")?
	Script.pass!("build app: stages ${caller.mnt}, ${caller.net}, its own path as runner and the project in place; copies nothing; stages the same bytes again")?

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

	# The runner's path is placed in generated text, so an executable whose
	# path could be read as anything but a path is refused, not escaped.
	for name in ["quo\"te", "dol\$lar", "back\\slash"] {
		odd = "${work}/${name}"
		Path.create_dir!(Path.utf8(odd))?
		Path.copy!(Path.utf8(bench.blueprint), Path.utf8("${odd}/blueprint"))?
		refused!(test, root, "${odd}/blueprint", "blueprint cannot run builds from ${odd}/blueprint", [])?
	}
	Script.pass!("a blueprint whose own path holds a quote, a dollar or a backslash refuses to build")?

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

	# The runner is internal: absent from help, and usable with no project,
	# compiler or provider at hand.
	help = run!(test, linked, ["--help"], [])?
	CliHarness.check!(!help.stdout.contains("__build-runner"), "--help mentions __build-runner")?
	bare = "${work}/bare"
	Path.create_dir!(Path.utf8(bare))?
	missing = run!(test, bare, ["__build-runner"], [("PATH", bare)])?
	CliHarness.check!(missing.code == 1 and missing.stderr == "blueprint build: missing build specification\n", "__build-runner alone exited with code ${missing.code.to_str()}: ${missing.stderr}")?
	surplus = run!(test, bare, ["__build-runner", "a", "b"], [("PATH", bare)])?
	CliHarness.check!(surplus.code == 1 and surplus.stderr == "blueprint build: expected one build specification\n", "__build-runner a b exited with code ${surplus.code.to_str()}: ${surplus.stderr}")?
	Script.pass!("__build-runner: not in help; refuses no specification and two, with no project, compiler or provider")?

	used = CliHarness.calls!(python_log)?
	CliHarness.check!(used.is_empty(), "blueprint ran a host python3: ${Str.inspect(used)}")?
	Script.pass!("Build isolation witness, runner path and refusal tests passed without a host Python or chmod (stubbed Nix/compiler)")
}

expect CliIsolationTest.staged({ mnt: "mnt:[1]", net: "net:[2]", runner: "/repo/blueprint", root: "/tmp/p" }) == [
	"isolation = { mnt = \"mnt:[1]\"; net = \"net:[2]\"; };",
	"runner = builtins.path { path = /. + \"/repo/blueprint\"; name = \"blueprint-runner\"; };",
	"path = /. + \"/tmp/p\";",
	"|| builtins.elem path [ \"/tmp/p/.blueprint\" \"/tmp/p/Blueprint.lock\" ])",
	"throw \"snapshot refuses symlink: \${path}\"",
	"throw \"snapshot refuses special file: \${path}\"",
]
expect CliIsolationTest.wire.contains("(builds (((name \"app\")") and CliIsolationTest.wire.contains("(requires (\"builds\"))")
