import cli.Env
import cli.OsStr
import cli.Path
import compilers.Bootstrap
import CliHarness
import Integrity
import RocPackagesTest
import Script
import "../../blueprint-cli/compiler-version" as compiler_version : Str

## The real bundled compiler, with no roc on PATH and no project downloads.
CliBootstrapTest := [].{
	run! : Path => Try({}, _)
	run! = |repository| {
		bench = CliHarness.open!(repository, "blueprint-bootstrap-", [])?
		result = bootstrap!(bench)
		CliHarness.close!(bench)
		result
	}
}

bootstrap! : CliHarness.Bench => Try({}, _)
bootstrap! = |bench| {
	bin = "${bench.work}/bootstrap-bin"
	Path.create_all!(Path.utf8(bin))?
	search = Env.var_str!(OsStr.from_str("PATH")) ?? ""
	for name in ["tar", "chmod", "gzip"] {
		tool = CliHarness.which!(name, search)?
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
	cold = CliHarness.invoke!(call)?
	CliHarness.exited!(cold, 0, "embedded compiler bootstrap")?
	CliHarness.contains!(cold.stderr, "installing embedded Roc compiler", "cold bootstrap")?
	CliHarness.check!(!cold.stderr.contains("fetching"), "cold bootstrap downloaded its compiler:\n${cold.stderr}")?
	program = Bootstrap.compiler(compiler_version.trim(), system_of(Env.platform!()))?
	artifact = "${store}/v1/artifacts/sha256/${program.sha256}"
	tree = "${store}/v1/trees/sha256/${program.sha256}.tar.gz"
	CliHarness.check!(Integrity.digest(Path.read_bytes!(Path.utf8(artifact))?) == program.sha256, "embedded compiler has the wrong digest")?
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
	CliHarness.check!(CliHarness.names!("${store}/v1/trees/sha256")? == ["${program.sha256}.tar.gz"], "concurrent bootstrap left an incomplete tree")?
	Script.pass!("embedded compiler: cold install, cache reuse, corruption repair and concurrent installs, with no roc on PATH or compiler download")
}

system_of : { arch : [X86, X64, ARM, AARCH64, OTHER(Str)], os : [LINUX, MACOS, WINDOWS, OTHER(Str)] } -> Str
system_of = |machine|
	match machine {
		{ arch: AARCH64, os: LINUX } => "aarch64-linux"
		{ arch: AARCH64, os: MACOS } => "aarch64-darwin"
		_ => "x86_64-linux"
	}
