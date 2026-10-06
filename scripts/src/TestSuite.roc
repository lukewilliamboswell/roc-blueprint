import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import Bundle
import FlakeLock
import Process
import Script
import StaticChecks

## Everything CI checks, in groups that CI runs as separate jobs.
##
## The `cli`, `scenarios` and `builds` groups use `./blueprint`. They build it unless
## `BLUEPRINT_PREBUILT=1` says the caller already put a tested binary there.
## The caller then answers for the platform hosts too: when every
## `targets/<target>/libhost.a` is present, they are used as they are, and
## when any is missing all are built.
TestSuite := [].{
	groups = ["static", "unit", "cli", "scenarios", "builds", "package", "fuzz"]

	## The groups a command line asks for: all of them, in order, when it names none.
	requested : List(Str) -> Try(List(Str), [UnknownGroup(Str)])
	requested = |args|
		match args.find_first(|name| !groups.contains(name)) {
			Ok(name) => Err(UnknownGroup(name))
			Err(_) => Ok(if args.is_empty() groups else args)
		}

	## A project whose one build copies a file with a tool of its environment.
	packaged_project : Str, Str -> Str
	packaged_project = |platform_path, packages_ref|
		Str.join_with(
			[
				"app [config] { pf: platform \"${platform_path}\" }",
				"",
				"config = [",
				"	Name(\"packaged\"),",
				"	Systems([\"x86_64-linux\"]),",
				"	Packages(\"default\", From(NixPackages(\"${packages_ref}\"))),",
				"	Environment(\"builder\", [Tools([\"coreutils\"])]),",
				"	Build(\"copy\", [Use(\"builder\"), Run([\"cp\", \"message.txt\", \"copied.txt\"]), Output(\"copied.txt\")]),",
				"]",
				"",
			],
			"\n",
		)

	## The platform hosts among the files its targets link: what `zig build`
	## makes. The rest are fetched linker inputs.
	hosts : List(Str) -> List(Str)
	hosts = |target_inputs| target_inputs.keep_if(|file| file.ends_with("/libhost.a"))

	## Run the named groups from the repository root.
	run! : Str, List(Str) => Try({}, _)
	run! = |root, names| {
		prebuilt = (Env.var_str!(OsStr.from_str("BLUEPRINT_PREBUILT")) ?? "") == "1"
		each!({ root, roc: Process.roc!(), prebuilt }, names, { prepared: False, built: False })
	}
}

Context : { root : Str, roc : Str, prebuilt : Bool }

## What an earlier group of this run already did.
Done : { prepared : Bool, built : Bool }

step! : Str => Try({}, _)
step! = |title| Script.info!("\n==>", title)

## A repository script, run by the compiler under test with its own output.
script! : Context, Str, List(Str) => Try({}, _)
script! = |context, name, args|
	Process.passthrough!(Process.command(context.roc, ["scripts/${name}.roc"].concat(args), context.root))

compiler! : Context, List(Str) => Try({}, _)
compiler! = |context, args| Process.passthrough!(Process.command(context.roc, args, context.root))

read! : Context, Str => Try(Str, _)
read! = |context, file| Path.read_utf8!(Path.utf8("${context.root}/${file}"))

problem! : Str => Try({}, _)
problem! = |reason| if reason.is_empty() Ok({}) else Script.fail!(reason)

file_names! : Str => Try(List(Str), _)
file_names! = |directory| {
	var $names = []
	for entry in Path.list!(Path.utf8(directory))? {
		if Path.is_file!(entry)? {
			$names = $names.append(Path.to_str(entry)?.split_on("/").last() ?? "")
		}
	}
	Ok(Process.sorted($names))
}

each! : Context, List(Str), Done => Try({}, _)
each! = |context, names, done|
	match names {
		[] => Ok({})
		[name, .. as rest] => {
			after = group!(context, name, done)?
			each!(context, rest, after)
		}
	}

group! : Context, Str, Done => Try(Done, _)
group! = |context, name, done|
	if name == "static" {
		static!(context)?
		Ok(done)
	} else if name == "unit" {
		prepared = prepare!(context, done)?
		unit!(context)?
		Ok(prepared)
	} else if name == "cli" {
		ready = build_cli!(context, prepare!(context, done)?)?
		cli!(context)?
		Ok(ready)
	} else if name == "scenarios" {
		ready = build_cli!(context, prepare!(context, done)?)?
		scenarios!(context)?
		Ok(ready)
	} else if name == "builds" {
		ready = build_cli!(context, prepare!(context, done)?)?
		builds!(context)?
		Ok(ready)
	} else if name == "package" {
		prepared = prepare!(context, done)?
		packaged!(context)?
		Ok(prepared)
	} else if name == "fuzz" {
		step!("Fuzz targets: replay each committed corpus")?
		script!(context, "fuzz", [])?
		Ok(done)
	} else {
		Script.fail!("unknown test group: ${name}")
	}

prepare! : Context, Done => Try(Done, _)
prepare! = |context, done| {
	if done.prepared {
		return Ok(done)
	}
	step!("Fetch and verify the platform's linker inputs")?
	# Unconditional: a restored cache is storage, not authority. The archive is
	# rehashed against link-inputs.lock.json whether or not it was downloaded.
	script!(context, "link_inputs", ["fetch"])?
	hosts = match Bundle.target_inputs(read!(context, "${Bundle.platform_dir}/main.roc")?) {
		Ok(files) => TestSuite.hosts(files)
		Err(NoTargets) => return Script.fail!("${Bundle.platform_dir}/main.roc declares no targets")
	}
	if context.prebuilt and present!(context, hosts) {
		# No host is committed, so in a job that starts from a checkout these
		# are the ones the caller put there with its binary, built from this
		# commit by the same workflow run.
		step!("Use the ${hosts.len().to_str()} prebuilt platform hosts (BLUEPRINT_PREBUILT=1)")?
	} else {
		step!("Build the platform host")?
		Process.passthrough!(Process.command("zig", ["build"], "${context.root}/blueprint-platform"))?
	}
	Ok({ ..done, prepared: True })
}

## Whether every one of these files of the platform directory exists.
present! : Context, List(Str) => Bool
present! = |context, files| {
	var $missing = files.is_empty()
	for file in files {
		if !(Path.is_file!(Path.utf8("${context.root}/${Bundle.platform_dir}/${file}")) ?? False) {
			$missing = True
		}
	}
	!$missing
}

build_cli! : Context, Done => Try(Done, _)
build_cli! = |context, done| {
	if done.built {
		return Ok(done)
	}
	if context.prebuilt {
		binary = Path.utf8("${context.root}/blueprint")
		if !((Path.is_file!(binary) ?? False) and (Path.is_executable!(binary) ?? False)) {
			return Script.fail!("BLUEPRINT_PREBUILT=1 but ./blueprint is missing")
		}
	} else {
		step!("Build the blueprint CLI")?
		compiler!(context, ["build", "blueprint-cli/main.roc", "--output=./blueprint"])?
	}
	Ok({ ..done, built: True })
}

static! : Context => Try({}, _)
static! = |context| {
	step!("Formatting")?
	compiler!(context, ["fmt", "--check"].concat(StaticChecks.formatted))?

	step!("No binary linker input is tracked")?
	listed = Process.succeed!(Process.command("git", ["ls-files", "--"].concat(StaticChecks.binary_patterns), context.root))?
	problem!(StaticChecks.tracked_binaries_problem(listed.stdout))?

	step!("The CLI reaches providers only through the Provider contract")?
	cli_source = read!(context, "blueprint-cli/main.roc")?
	problem!(StaticChecks.provider_contract_problem(cli_source))?

	step!("The fetched compiler comes from the locked roc-overlay revision")?
	problem!(StaticChecks.overlay_problem(read!(context, "flake.lock")?, read!(context, "blueprint-nix/NixProvider.roc")?))?

	step!("The flake lists the core package's modules and the CLI's version")?
	flake = read!(context, "flake.nix")?
	in_directory = Bundle.modules(file_names!("${context.root}/${Bundle.core_dir}")?)
	problem!(StaticChecks.core_modules_problem(in_directory, Bundle.flake_core_modules(flake)))?
	problem!(StaticChecks.version_problem(flake, cli_source))
}

unit! : Context => Try({}, _)
unit! = |context| {
	step!("Platform lowering tests")?
	compiler!(context, ["test", "blueprint-platform/main.roc"])?

	step!("Repository script tests")?
	scripts = file_names!("${context.root}/scripts")?.keep_if(|name| name.ends_with(".roc"))
	tested = Process.together!(scripts.map(|name| Process.command(context.roc, ["test", "scripts/${name}"], context.root)))?
	report_tests!(scripts, tested)?

	step!("Compile-time configuration validation")?
	script!(context, "test_config", [])?

	# Every core and Nix provider expect runs here too: the CLI imports both.
	step!("CLI, provider and core tests")?
	compiler!(context, ["test", "blueprint-cli/main.roc"])?

	step!("Independent library consumer")?
	compiler!(context, ["check", "fixtures/consumer/main.roc"])?
	compiler!(context, ["test", "fixtures/consumer/main.roc"])
}

report_tests! : List(Str), List(Process.Outcome) => Try({}, _)
report_tests! = |scripts, outcomes|
	match (scripts, outcomes) {
		([], []) => Ok({})
		([name, .. as other_scripts], [outcome, .. as other_outcomes]) => {
			if outcome.code != 0 {
				return Script.fail!("${outcome.stdout}${outcome.stderr}\nroc test scripts/${name} exited with code ${outcome.code.to_str()}")
			}
			Script.info!("   ", "scripts/${name}: ${outcome.stdout.trim()}")?
			report_tests!(other_scripts, other_outcomes)
		}
		_ => Script.fail!("roc test did not report every script")
	}

cli! : Context => Try({}, _)
cli! = |context| {
	step!("CLI argument and validation regressions")?
	script!(context, "test_cli", [])?

	step!("Explicit update source safety and concurrent authority publication")?
	script!(context, "test_update", [])?

	step!("Staged isolation witness, build runner path and refusals")?
	script!(context, "test_isolation", [])
}

## The real-Nix suites are two groups of about the same length, so that CI
## runs them as two jobs at the same time. This one enters environments.
scenarios! : Context => Try({}, _)
scenarios! = |context| {
	step!("Examples, scoped overlays, system-scoped tools and renamed commands through real Nix")?
	script!(context, "test_scenarios", [])?

	step!("Locked Roc packages: published for tasks, private to sandboxed builds")?
	script!(context, "test_roc_packages", [])?

	step!("Golden flakes parse as Nix")?
	tests = "${context.root}/blueprint-nix/tests"
	goldens = file_names!(tests)?.keep_if(|name| name.ends_with(".golden.nix"))
	if goldens.is_empty() {
		return Script.fail!("no golden flakes in blueprint-nix/tests")
	}
	for golden in goldens {
		_ = Process.succeed!(Process.command("nix-instantiate", ["--parse", "${tests}/${golden}"], context.root))?
	}
	Ok({})
}

## The other real-Nix group: sandboxed builds, alone and in workflows.
builds! : Context => Try({}, _)
builds! = |context| {
	step!("Sandboxed artifacts, isolation, sources and immutable locks")?
	script!(context, "test_builds", [])?

	step!("Ordered workflows, failure propagation and fresh build operations")?
	script!(context, "test_workflows", [])
}

packaged! : Context => Try({}, _)
packaged! = |context| {
	step!("Nix flake: blueprint builds with the pinned Roc and reports the packaged version")?
	built = Process.succeed!(Process.command("nix", ["build", ".#blueprint", "--no-link", "--print-out-paths"], context.root))?
	package_path = built.stdout.trim()
	reported = Process.succeed!(Process.command("${package_path}/bin/blueprint", ["--version"], context.root))?.stdout.trim()
	flake = read!(context, "flake.nix")?
	Process.check!(StaticChecks.constant(flake, "version") == Ok(reported), "the packaged blueprint reports version ${reported}, not the version in flake.nix")?

	step!("Nix flake: every system's outputs evaluate (no build)")?
	for system in ["x86_64-linux", "aarch64-darwin"] {
		_ = Process.succeed!(Process.command("nix", ["eval", "--raw", ".#packages.${system}.blueprint.drvPath"], context.root))?
		_ = Process.succeed!(Process.command("nix", ["eval", "--raw", ".#devShells.${system}.default.drvPath"], context.root))?
	}

	step!("Nix flake: the packaged blueprint builds an artifact with nothing but Nix on PATH")?
	work = Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-packaged-")?)?)?
	result = packaged_build!(context, package_path, work)
	_ = Cmd.new_str("chmod").args_str(["-R", "u+w", "--", work]).exec_cmd!()
	_ = Path.delete_all!(Path.utf8(work))
	result?

	step!("Bundle core and the platform against it")?
	# The pinned core release is checked by release.yml when a platform release
	# is tagged. A change that adds a Spec field cannot pass that check until a
	# core release containing the field is published, so it is not a
	# per-commit gate.
	script!(context, "bundle", ["platform"])
}

## A build observes its namespaces with `readlink`. The Nix package appends
## coreutils to PATH for that, so the packaged CLI must build where PATH holds
## only `nix`, and the same binary without its wrapper must not.
packaged_build! : Context, Str, Str => Try({}, _)
packaged_build! = |context, package_path, work| {
	project = "${work}/project"
	only_nix = "${work}/bin"
	Path.create_all!(Path.utf8(project))?
	Path.create_all!(Path.utf8(only_nix))?
	nix = match Process.holding!(Process.search_path!(), "nix") {
		[directory, ..] => "${directory}/nix"
		[] => return Script.fail!("nix is not on PATH")
	}
	Cmd.new_str("ln").args_str(["-s", nix, "${only_nix}/nix"]).exec_cmd!().map_err(|_| LinkFailed)?

	packages_ref = match FlakeLock.locked(read!(context, "fixtures/consumer/inputs.lock")?, "nixpkgs") {
		Ok(pin) => FlakeLock.ref(pin)
		Err(NoPin(_)) => return Script.fail!("fixtures/consumer/inputs.lock has no GitHub pin for nixpkgs")
	}
	platform_path = Process.relative(project, "${context.root}/blueprint-platform/main.roc")
	Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), TestSuite.packaged_project(platform_path, packages_ref))?
	Path.write_utf8!(Path.utf8("${project}/message.txt"), "built by the packaged blueprint\n")?

	inherited = Env.dict!().map(|(name, value)| (OsStr.display(name), OsStr.display(value))).keep_if(|(name, _)| name != "ROC" and name != "PATH")
	confined = |program, args, extra| {
		job = Process.command(program, args, project)
		{ ..job, cmd: job.cmd.clear_envs().envs_str(inherited.concat([("PATH", only_nix)]).concat(extra)) }
	}
	wrapped = "${package_path}/bin/blueprint"
	_ = Process.succeed!(confined(wrapped, ["update"], []))?
	built = Process.succeed!(confined(wrapped, ["build", "copy"], []))?
	artifact = Path.read_utf8!(Path.utf8(built.stdout.trim()))?
	Process.check!(artifact == "built by the packaged blueprint\n", "the packaged blueprint built: ${artifact}")?

	# The wrapper also supplies the compiler; give the bare binary that one.
	bare = "${package_path}/bin/.blueprint-wrapped"
	compiler = Process.succeed!(Process.command("nix", ["eval", "--raw", ".#packages.x86_64-linux.roc.outPath"], context.root))?.stdout.trim()
	unwrapped = Process.traced!(confined(bare, ["build", "copy"], [("ROC", "${compiler}/bin/roc")]))?
	Process.check!(
		unwrapped.code != 0 and unwrapped.stderr.contains("readlink"),
		"without its wrapper the packaged blueprint was expected to miss readlink, got exit ${unwrapped.code.to_str()}:\n${unwrapped.stderr}",
	)
}

expect TestSuite.requested([]) == Ok(["static", "unit", "cli", "scenarios", "builds", "package", "fuzz"])
expect TestSuite.requested(["scenarios", "builds"]) == Ok(["scenarios", "builds"])

# The real-Nix suites were one group, `nix`; it is not kept as a second name.
expect TestSuite.requested(["nix"]) == Err(UnknownGroup("nix"))
expect TestSuite.requested(["unit", "cli"]) == Ok(["unit", "cli"])
expect TestSuite.requested(["unit", "units"]) == Err(UnknownGroup("units"))
expect TestSuite.packaged_project("../pf/main.roc", "github:NixOS/nixpkgs/abc").contains("Packages(\"default\", From(NixPackages(\"github:NixOS/nixpkgs/abc\")))")

# The hosts are the built files of every target the platform declares.
expect TestSuite.hosts(["targets/x64musl/crt1.o", "targets/x64musl/libhost.a", "targets/x64musl/libc.a", "targets/arm64mac/libhost.a"]) == ["targets/x64musl/libhost.a", "targets/arm64mac/libhost.a"]
expect TestSuite.hosts(["targets/x64musl/libhost.a.sig", "targets/x64musl/crt1.o"]).is_empty()
