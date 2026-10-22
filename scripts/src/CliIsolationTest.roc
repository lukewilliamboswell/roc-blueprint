import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import core.Project
import core.Spec
import core.BuildModel
import CliHarness
import Integrity
import Script

## What `blueprint build` stages about its caller, against a stubbed compiler
## and Nix.
##
## The stubbed Nix never builds: these cases observe only what `blueprint
## build` stages before it runs the provider: the caller's namespaces in a
## private runtime witness, separate from the reproducible derivation. `PATH` holds
## the stubs, `readlink`, `chmod` and a `python3` that records any use.
## The CLI publishes only the owned witness file's read permissions and needs no Python.
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
		\\((format ((major 3) (minor 1))) (name "wire")
		\\(requires ("explicit-sources" "builds"))
		\\(systems ("x86_64-linux"))
		\\(sources (((name "default") (provider ((name "nix") (ref "github:NixOS/nixpkgs/nixos-unstable") (version 1))))))
		\\(environments (((name "ci") (parents ()) (tools ()) (overlays ()))))
		\\(shells (((name "default") (environment "ci"))))
		\\(executors (((name "native") (provider "nix") (source "default"))))
		\\(build_executors (((build "app") (executor "native"))))
		\\(builds (((name "app") (environment "ci") (inputs ()) (needs ())
		\\          (run ("true")) (output "result")))))

	## What the stub Nix prints as the built artifact.
	store : Str
	store = "/nix/store/00000000000000000000000000000000-blueprint-app"

	## Stable recipe bytes refer to a versioned provider runner, and read the
	## project and the compiler as locked paths through records beside the
	## flake, never by a path of the caller's.
	staged : List(Str)
	staged = [
		"runnerSource = ",
		"blueprint-build-runner-v1",
		"builder = runner;",
		"project = projectFor ./project-app.json;",
		"projectFor = record: let project = builtins.fromJSON (builtins.readFile record); in (builtins.fetchTree { type = \"path\"; path = project.path; narHash = project.narHash; }).outPath;",
		"compilerArchive = (let record = builtins.fromJSON (builtins.readFile ./source-file-",
	]

	## The SRI hash the stub Nix prints for a path whose last component is
	## `name`.
	stub_hash : Str -> Str
	stub_hash = |name| "sha256-${Str.from_utf8(Integrity.digest(name.to_utf8()).to_utf8().take_first(43)) ?? ""}="

	## A record of a locked path, as the CLI writes it beside the flake.
	Record : { path : Str, narHash : Str }

}

Test : { bench : CliHarness.Bench, env : List((OsStr, OsStr)) }

run! : Test, Str, List(Str), List((Str, Str)) => Try(CliHarness.Outcome, _)
run! = |test, root, args, extra|
	CliHarness.blueprint!(test.bench, root, args, CliHarness.setting(test.env, extra))

## How many times the provider was asked to build in this project.
builds! : Str => Try(U64, _)
builds! = |root| Ok(CliHarness.calls!("${root}/.blueprint/nix-calls")?.keep_if(|call| call.first() == Ok("build")).len())

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
	chmod = CliHarness.which!("chmod", Env.var_str!(OsStr.from_str("PATH")) ?? "")?
	CliHarness.tool!(["ln", "-s", "--", chmod, "${bench.bin}/chmod"])?
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
				("STUB_NIX_CALLS", ".blueprint/nix-calls"),
				("STUB_PYTHON_LOG", python_log),
				("STUB_NIX_ISOLATION_LOG", "${bench.work}/runtime-witness.json"),
				("STUB_NIX_HASH_COPY", "${bench.work}/hashed"),
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
	planned = run!(test, root, ["plan", "build", "app", "--prepare", "--json"], [])?
	CliHarness.exited!(planned, 0, "prepare build without execution")?
	prepared : BuildModel.Inspection
	prepared = Json.parse(planned.stdout).map_err(|_| ScriptFailed)?
	CliHarness.check!(prepared.prepared and prepared.build_identity.ends_with(".drv") and prepared.baseline == "unavailable" and prepared.outputs == [{ name: "out", path: CliIsolationTest.store }] and builds!(root)? == before, "native preparation built an artifact or advanced the baseline")?
	CliHarness.check!(!CliHarness.present!("${bench.work}/runtime-witness.json"), "preparation observed runtime execution namespaces")?
	# Nix has read the copy of the project into its store by then, so none
	# stays to be read again with the generated root.
	CliHarness.check!(!CliHarness.present!("${root}/.blueprint/snapshots"), "preparation left a copy of the project behind")?
	built = run!(test, root, ["build", "app"], [])?
	CliHarness.exited!(built, 0, "blueprint build app")?
	CliHarness.check!(built.stdout == "${CliIsolationTest.store}\n", "build app printed ${Str.inspect(built.stdout)}, not the artifact")?
	CliHarness.check!(builds!(root)? == before + 1, "build app did not run exactly one provider build")?
	flake = Path.read_utf8!(Path.utf8("${root}/.blueprint/flake.nix"))?
	caller = { mnt: namespace!(readlink, "mnt")?, net: namespace!(readlink, "net")? }
	for expected in CliIsolationTest.staged {
		CliHarness.contains!(flake, expected, "the staged flake")?
	}
	CliHarness.check!(!flake.contains("@blueprint-caller"), "the staged flake still holds a placeholder:\n${flake}")?
	CliHarness.check!(!flake.contains(root) and !flake.contains("builtins.path"), "the staged flake reads a caller path itself:\n${flake}")?
	CliHarness.check!(!flake.contains(caller.mnt) and !flake.contains(caller.net) and !flake.contains(bench.blueprint), "caller or executable identity entered the derivation")?
	observed = captured!(test)?
	CliHarness.check!(observed.witness == "${caller.mnt}\n${caller.net}\n", "runtime witness did not capture caller namespaces")?
	CliHarness.check!(observed.directory.starts_with("/tmp/blueprint-isolation-") and !CliHarness.present!(observed.directory), "runtime witness was not private and cleaned after the command")?
	# The CLI copies the build's selected files into the workspace for Nix to
	# read as a locked path, and no executable; the copy and runtime
	# witnesses last only while the build does.
	generated = CliHarness.names!("${root}/.blueprint")?.sort_with(Project.bytewise)
	source_files = generated.keep_if(|name| name.starts_with("source-file-") and name.ends_with(".json"))
	CliHarness.check!(source_files.len() == 1, "the runner compiler needs exactly one original-file path record")?
	CliHarness.check!(generated.keep_if(|name| !source_files.contains(name)) == [".gitignore", "build-records", "excluded-secret", "flake.lock", "flake.nix", "nix-calls", "project-app.json"], "the generated root holds ${Str.join_with(generated, " ")}")?
	for source in sources {
		kept = CliHarness.stat!("%a %h", "${root}/${source.file}")?
		CliHarness.check!(kept == "${source.mode} 1", "${source.file} now has mode and link count ${kept}, not ${source.mode} 1")?
	}
	# Each record names where the host put the content and the NAR hash Nix
	# printed for it there; evaluation needs nothing else of the caller.
	copy = "${root}/.blueprint/snapshots/app"
	project_text = Path.read_utf8!(Path.utf8("${root}/.blueprint/project-app.json"))?
	project_record : CliIsolationTest.Record
	project_record = Json.parse(project_text).map_err(|_| ScriptFailed)?
	CliHarness.check!(project_record == { path: copy, narHash: CliIsolationTest.stub_hash("app") }, "the project record is ${project_text}")?
	compiler_text = Path.read_utf8!(Path.utf8("${root}/.blueprint/${source_files.first() ?? ""}"))?
	compiler_record : CliIsolationTest.Record
	compiler_record = Json.parse(compiler_text).map_err(|_| ScriptFailed)?
	CliHarness.check!(compiler_record.narHash == CliIsolationTest.stub_hash(compiler_record.path.split_on("/").last() ?? "") and Path.is_file!(Path.utf8(compiler_record.path)) ?? False, "the compiler record is ${compiler_text}")?
	nix_calls = CliHarness.calls!("${root}/.blueprint/nix-calls")?
	CliHarness.check!(nix_calls.contains(["hash", "path", copy]) and nix_calls.contains(["hash", "path", compiler_record.path]), "Nix did not hash what the records name: ${Str.inspect(nix_calls)}")?
	CliHarness.check!(!nix_calls.any(|call| call.contains("--impure")), "Nix was asked to evaluate impurely: ${Str.inspect(nix_calls)}")?
	# The stub Nix kept what it was asked to hash.
	hashed = "${bench.work}/hashed/app"
	snapshot = CliHarness.names!(hashed)?.sort_with(Project.bytewise)
	CliHarness.check!(snapshot == ["Blueprint.roc", "nested", "odd", "plain", "setuid", "tool", "wire.scm"], "the copy of the project held ${Str.join_with(snapshot, " ")}")?
	for source in sources {
		original = Path.read_bytes!(Path.utf8("${root}/${source.file}"))?
		executable = Path.is_executable!(Path.utf8("${root}/${source.file}"))?
		CliHarness.check!(Path.read_bytes!(Path.utf8("${hashed}/${source.file}"))? == original and Path.is_executable!(Path.utf8("${hashed}/${source.file}"))? == executable, "the copy of ${source.file} differed in bytes or in whether it is executable")?
	}
	# An unchanged caller stages identical bytes, so Nix can reuse the build.
	CliHarness.exited!(run!(test, root, ["build", "app"], [])?, 0, "a second blueprint build app")?
	CliHarness.check!(Path.read_utf8!(Path.utf8("${root}/.blueprint/flake.nix"))? == flake and Path.read_utf8!(Path.utf8("${root}/.blueprint/project-app.json"))? == project_text, "a second build staged a different flake or project record")?
	second = captured!(test)?
	CliHarness.check!(second.directory != observed.directory and !CliHarness.present!(second.directory), "two builds reused a mutable witness or left it behind")?
	baseline_path = "${root}/.blueprint/build-records/x86_64-linux/app.scm"
	baseline_before = Path.read_bytes!(Path.utf8(baseline_path))?
	invalid_result = run!(test, root, ["build", "app"], [("STUB_NIX_RESULT_DRV", "/nix/store/wrong-recipe.drv")])?
	CliHarness.check!(invalid_result.code == 1 and invalid_result.stderr.contains("does not match the prepared build") and Path.read_bytes!(Path.utf8(baseline_path))? == baseline_before, "invalid provider result advanced successful build evidence")?
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

	# A name that is not UTF-8, in a directory whose name is not either, is
	# copied as it is. A symlink is refused before the provider runs.
	bytes = project!(test, "bytes")?
	odd_directory = "${bytes}/".to_utf8().concat(['d', 0xfe])
	Path.create_dir!(Path.unix_bytes(odd_directory))?
	Path.write_bytes!(Path.unix_bytes(odd_directory.append('/').concat(['f', 0xff])), [1, 2, 3])?
	CliHarness.exited!(run!(test, bytes, ["build", "app"], [])?, 0, "build app with names that are not UTF-8")?
	copied = Path.read_bytes!(Path.unix_bytes("${bench.work}/hashed/app/".to_utf8().concat(['d', 0xfe, '/', 'f', 0xff])))?
	CliHarness.check!(copied == [1, 2, 3] and !CliHarness.present!("${bytes}/.blueprint/snapshots"), "a file whose name is not UTF-8 was copied as ${Str.inspect(copied)}, or the copy stayed")?
	CliHarness.tool!(["ln", "-s", "--", "absent", "${bytes}/dangling"])?
	bytes_before = builds!(bytes)?
	linked_entry = run!(test, bytes, ["build", "app"], [])?
	CliHarness.check!(linked_entry.code == 1 and linked_entry.stderr.contains("snapshot refuses symlink: ${bytes}/dangling") and builds!(bytes)? == bytes_before and !CliHarness.present!("${bytes}/.blueprint/snapshots"), "a project symlink was not refused before the provider, or a partial copy stayed:\n${linked_entry.stderr}")?
	# What an interrupted run left is removed before anything is staged.
	Path.delete!(Path.utf8("${bytes}/dangling"))?
	Path.create_all!(Path.utf8("${bytes}/.blueprint/snapshots/stale"))?
	CliHarness.exited!(run!(test, bytes, ["build", "app"], [])?, 0, "build app after an interrupted one")?
	flake_source = CliHarness.names!("${bytes}/.blueprint")?
	CliHarness.check!(!flake_source.contains("snapshots"), "a leftover copy stayed in the generated root: ${Str.join_with(flake_source, " ")}")?
	Script.pass!("selected files are copied with their names' bytes; a symlink is refused before Nix")?

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

expect Spec.parse(CliIsolationTest.wire).is_ok()
