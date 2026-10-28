import cli.Env
import cli.OsStr
import cli.Path
import compilers.Bootstrap
import CliHarness
import Integrity
import RocPackagesTest
import Script
import SmokeBinary
import "../../blueprint-cli/compiler-version" as compiler_version : Str

## The real bundled compiler, with no roc on PATH and no project downloads.
CliBootstrapTest := [].{
	run! : Path => Try({}, _)
	run! = |repository| {
		bench = CliHarness.open!(repository, "blueprint-bootstrap-", [])?
		result = cases!(bench)
		CliHarness.close!(bench)
		result
	}
}

cases! : CliHarness.Bench => Try({}, _)
cases! = |bench| {
	lookup!(bench)?
	compiler_version!(bench)?
	bootstrap!(bench)
}

## A metadata query must not resolve project paths, evaluate configuration,
## probe ROC or PATH, or create a cache, including for help and usage errors.
compiler_version! : CliHarness.Bench => Try({}, _)
compiler_version! = |bench| {
	cwd = "${bench.work}/metadata"
	cache = "${bench.work}/metadata-cache"
	Path.create_all!(Path.utf8(cwd))?
	env = CliHarness.setting(
		bench.env,
		[
			("PATH", ""),
			("ROC", "${bench.work}/missing-roc"),
			("BLUEPRINT_ROOT", "${bench.work}/missing-root"),
			("XDG_CACHE_HOME", cache),
		],
	)
	call = { program: bench.blueprint, args: ["compiler-version"], cwd, env }
	for config in [Err(NoConfig), Ok("this is not a Roc program")] {
		match config {
			Ok(text) => Path.write_utf8!(Path.utf8("${cwd}/Blueprint.roc"), text)?
			Err(NoConfig) => {}
		}
		query = CliHarness.invoke!(call)?
		CliHarness.exited!(query, 0, "compiler-version")?
		CliHarness.check!(query.stdout == "${compiler_version.trim()}\n" and query.stderr == "", "compiler-version did not print exactly the bundled release tag:\n${query.stdout}${query.stderr}")?
	}
	# A malformed project in the actual selected root must also be ignored.
	local = { ..call, env: CliHarness.unsetting(env, ["BLUEPRINT_ROOT"]) }
	query = CliHarness.invoke!(local)?
	CliHarness.check!(query.code == 0 and query.stdout == "${compiler_version.trim()}\n" and query.stderr == "", "compiler-version evaluated a malformed project")?
	help = CliHarness.invoke!({ ..call, args: ["compiler-version", "--help"] })?
	CliHarness.exited!(help, 0, "compiler-version --help")?
	CliHarness.contains!(help.stdout, "bundled Roc compiler release tag", "compiler-version help")?
	invalid = CliHarness.invoke!({ ..call, args: ["compiler-version", "unexpected"] })?
	CliHarness.exited!(invalid, 2, "compiler-version with an unexpected argument")?
	CliHarness.check!(invalid.stdout == "" and !CliHarness.present!(cache) and !CliHarness.present!("${cwd}/.blueprint"), "compiler-version created state or printed a tag for invalid usage")?
	Script.pass!("compiler-version reports the bundled tag without a project, compiler, cache or valid overrides; malformed projects are ignored and extra arguments refused")
}

bootstrap! : CliHarness.Bench => Try({}, _)
bootstrap! = |bench| {
	bin = "${bench.work}/bootstrap-bin"
	Path.create_all!(Path.utf8(bin))?
	search = Env.var_str!(OsStr.from_str("PATH")) ?? ""
	for name in ["tar", "chmod", "gzip"] {
		tool = match CliHarness.which!(name, search) {
			Ok(found) => found
			Err(_) => return Script.fail!("bootstrap prerequisite ${name} not found on PATH: ${search}")
		}
		CliHarness.tool!(["ln", "-s", tool, "${bin}/${name}"])?
	}
	cache = "${bench.work}/bootstrap-cache"
	env = CliHarness.setting(CliHarness.unsetting(bench.env, ["ROC"]), [("PATH", bin), ("XDG_CACHE_HOME", cache)])
	store = "${cache}/blueprint"
	cwd = "${bench.work}/project"
	Path.create_all!(Path.utf8(cwd))?
	platform_path = RocPackagesTest.relative(cwd, "${bench.root}/blueprint-platform/main.roc")
	Path.write_utf8!(Path.utf8("${cwd}/Blueprint.roc"), "app [config] { pf: platform \"${platform_path}\" }\nconfig = [Name(\"bootstrap\"), Environment(\"dev\", [])]\n")?
	call = { program: bench.blueprint, args: ["check"], cwd, env }
	Script.info!("==>", "Cold bootstrap with isolated PATH")?
	cold = CliHarness.invoke!(call)?
	CliHarness.exited!(cold, 0, "embedded compiler bootstrap")?
	CliHarness.contains!(cold.stderr, "installing embedded Roc compiler", "cold bootstrap")?
	CliHarness.check!(!cold.stderr.contains("fetching"), "cold bootstrap downloaded its compiler:\n${cold.stderr}")?
	program = Bootstrap.compiler(compiler_version.trim(), system_of(Env.platform!()))?
	artifact = "${store}/v1/artifacts/sha256/${program.sha256}"
	tree = "${store}/v1/trees/sha256/${program.sha256}.tar.gz"
	CliHarness.check!(CliHarness.present!(artifact), "embedded compiler artifact missing: ${artifact}; stored artifacts: ${Str.inspect(CliHarness.names!("${store}/v1/artifacts/sha256")?)}")?
	CliHarness.check!(Integrity.digest(Path.read_bytes!(Path.utf8(artifact))?) == program.sha256, "embedded compiler has the wrong digest")?
	# Check the actual executable extracted from the verified embedded archive,
	# with no roc available on PATH and a cache owned by this test.
	reported = CliHarness.invoke!({ ..call, args: ["compiler-version"] })?
	CliHarness.exited!(reported, 0, "compiler-version after bootstrap")?
	actual = CliHarness.invoke!({ ..call, program: "${tree}/${program.path}", args: ["version"] })?
	CliHarness.exited!(actual, 0, "bundled roc version")?
	CliHarness.check!(SmokeBinary.compiler_matches(reported.stdout, actual.stdout), "bundled roc version disagrees with compiler-version:\n${reported.stdout}${actual.stdout}${actual.stderr}")?
	Script.pass!("bundled roc version confirms compiler-version: ${actual.stdout.trim()}")?
	warm = CliHarness.invoke!(call)?
	CliHarness.exited!(warm, 0, "warm bootstrap")?
	CliHarness.check!(!warm.stderr.contains("installing") and !warm.stderr.contains("fetching"), "warm bootstrap reinstalled its compiler:\n${warm.stderr}")?
	# A damaged artifact must be restored from the executable, and its old
	# tree discarded, including files that were not in the original archive.
	Path.write_utf8!(Path.utf8("${tree}/stale"), "discard me")?
	Path.write_utf8!(Path.utf8(artifact), "corrupt")?
	repaired = CliHarness.invoke!(call)?
	CliHarness.exited!(repaired, 0, "bootstrap cache repair")?
	CliHarness.check!(repaired.stderr.contains("installing embedded Roc compiler") and !repaired.stderr.contains("fetching") and !CliHarness.present!("${tree}/stale"), "bootstrap did not repair its cache from embedded bytes:\n${repaired.stderr}")?
	CliHarness.check!(Integrity.digest(Path.read_bytes!(Path.utf8(artifact))?) == program.sha256, "repaired compiler has the wrong digest")?
	# Two fresh invocations can publish the same embedded archive and tree.
	CliHarness.tool!(["chmod", "-R", "u+w", store])?
	Path.delete_all!(Path.utf8(store))?
	one = CliHarness.start!(call)?
	two = CliHarness.start!(call)?
	CliHarness.exited!(CliHarness.finish!(one, "first concurrent bootstrap")?, 0, "first concurrent bootstrap")?
	CliHarness.exited!(CliHarness.finish!(two, "second concurrent bootstrap")?, 0, "second concurrent bootstrap")?
	CliHarness.check!(CliHarness.names!("${store}/v1/artifacts/sha256")? == [program.sha256], "concurrent bootstrap did not keep one compiler artifact")?
	trees = CliHarness.names!("${store}/v1/trees/sha256")?
	CliHarness.check!(trees.len() == 2 and trees.contains("${program.sha256}.tar.gz") and trees.contains("${program.sha256}.tar.gz.digest"), "concurrent bootstrap left an incomplete tree, or one without its digest record: ${Str.inspect(trees)}")?
	# The Nix-enabled release fixture also includes a fetched compiler probe;
	# validate that mixed configuration without needing Nix on this machine.
	release_project = "${bench.work}/release-smoke"
	Path.create_all!(Path.utf8(release_project))?
	release_platform = RocPackagesTest.relative(release_project, "${bench.root}/blueprint-platform/main.roc")
	Path.write_utf8!(Path.utf8("${release_project}/Blueprint.roc"), SmokeBinary.blueprint_roc(release_platform, SmokeBinary.pinned?))?
	CliHarness.exited!(CliHarness.invoke!({ ..call, cwd: release_project })?, 0, "Nix-enabled release smoke configuration")?
	Script.pass!("embedded compiler: cold install, cache reuse, corruption repair and concurrent installs, with no roc on PATH or compiler download")
}

system_of : { arch : [X86, X64, ARM, AARCH64, OTHER(Str)], os : [LINUX, MACOS, WINDOWS, OTHER(Str)] } -> Str
system_of = |machine|
	match machine {
		{ arch: AARCH64, os: LINUX } => "aarch64-linux"
		{ arch: AARCH64, os: MACOS } => "aarch64-darwin"
		_ => "x86_64-linux"
	}

## PATH lookup follows executable links and rejects broken/non-executable entries.
lookup! : CliHarness.Bench => Try({}, _)
lookup! = |bench| {
	directory = "${bench.work}/lookup"
	Path.create_all!(Path.utf8("${directory}/directory"))?
	Path.write_utf8!(Path.utf8("${directory}/plain"), "not executable")?
	CliHarness.tool!(["ln", "-s", "../stub-tool", "${directory}/linked"])?
	CliHarness.tool!(["ln", "-s", "absent", "${directory}/broken"])?
	CliHarness.check!(CliHarness.which!("linked", directory) == Ok("${bench.work}/stub-tool"), "PATH lookup did not follow an executable symlink")?
	for name in ["broken", "plain", "directory"] {
		CliHarness.check!(CliHarness.which!(name, directory) == Err(NotFound), "PATH lookup accepted ${name}")?
	}
	Script.pass!("PATH lookup follows executable symlinks and rejects broken links, non-executable files and directories")
}
