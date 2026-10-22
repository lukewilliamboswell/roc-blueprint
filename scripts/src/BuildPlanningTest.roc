import cli.OsStr
import cli.Path
import core.BuildModel
import core.Lock
import core.Spec
import CliHarness
import Script

## Structural plans and saved explanations work without Nix on the host.
BuildPlanningTest := [].{
	wire : Str
	wire =
		\\((format ((major 3) (minor 1))) (name "planning")
		\\(requires ("explicit-sources" "sources" "builds" "build-files"))
		\\(systems ("x86_64-linux"))
		\\(sources (((name "default") (provider ((name "nix") (ref "github:NixOS/nixpkgs/nixos-unstable") (version 1))))))
		\\(resolvers (((provider "nix") (inputs ("assets")))))
		\\(build_sources (((name "assets") (ref "path:./assets"))))
		\\(environments (((name "ci") (parents ()) (tools ()) (overlays ()))))
		\\(executors (((name "native") (provider "nix") (source "default"))))
		\\(build_executors (((build "lib") (executor "native")) ((build "app") (executor "native"))))
		\\(build_files (((build "lib") (paths ("recipe.txt"))) ((build "app") (paths ("app.txt")))))
		\\(builds (((name "lib") (environment "ci") (inputs ("assets")) (needs ()) (run ("compile")) (output "lib"))
		\\         ((name "app") (environment "ci") (inputs ()) (needs ("lib")) (run ("link")) (output "app")))))

	run! : Path => Try({}, _)
	run! = |repository| {
		bench = CliHarness.open!(repository, "blueprint-plan-", ["roc-wire", "nix"])?
		result = cases!(bench)
		CliHarness.close!(bench)
		result
	}
}

cases! = |bench| {
	root = "${bench.work}/project"
	Path.create_dir!(Path.utf8(root))?
	Path.write_utf8!(Path.utf8("${root}/Blueprint.roc"), "stub\n")?
	Path.write_utf8!(Path.utf8("${root}/wire.scm"), BuildPlanningTest.wire)?
	Path.write_utf8!(Path.utf8("${root}/recipe.txt"), "library")?
	Path.write_utf8!(Path.utf8("${root}/app.txt"), "application")?
	Path.create_dir!(Path.utf8("${root}/assets"))?
	Path.write_utf8!(Path.utf8("${root}/assets/input.txt"), "pinned input")?
	env = CliHarness.setting(
		[],
		[
			("PATH", bench.bin),
			("HOME", bench.work),
			("ROC", "${bench.bin}/roc-wire"),
			("NO_COLOR", "1"),
			("STUB_ROC_VERSION", bench.roc_version),
			("STUB_NIX_FIXTURE", "${bench.root}/blueprint-nix/tests/local.nix-lock.json"),
			("STUB_NIX_MODE", "local-inputs"),
			("BLUEPRINT_TARGET", "x86_64-linux"),
		],
	)
	invoke! = |args| CliHarness.blueprint!(bench, root, args, env)
	CliHarness.exited!(invoke!(["update"])?, 0, "prepare planning authority")?
	Path.delete!(Path.utf8("${bench.bin}/nix"))?
	inspect! = |command| {
		outcome = invoke!([command, "build", "app", "--json"])?
		CliHarness.exited!(outcome, 0, "${command} build without Nix")?
		value : BuildModel.Inspection
		value = Json.parse(outcome.stdout).map_err(|_| ScriptFailed)?
		Ok(value)
	}
	first = inspect!("plan")?
	CliHarness.check!(!first.prepared and first.build_identity.is_empty() and first.baseline == "unavailable" and first.schema_version == 1, "structural plan claimed an exact build or available baseline")?
	Path.write_utf8!(Path.utf8("${root}/assets/input.txt"), "dirty pinned input")?
	dirty = invoke!(["plan", "build", "app", "--json"])?
	CliHarness.check!(dirty.code == 1 and dirty.stdout.is_empty() and dirty.stderr.contains("local source") and dirty.stderr.contains("changed"), "dirty pinned local dependency was reported as unchanged")?
	Path.write_utf8!(Path.utf8("${root}/assets/input.txt"), "pinned input")?
	CliHarness.check!(inspect!("plan")?.snapshot_digest == first.snapshot_digest, "restored pinned local content changed snapshot identity")?
	lock_file = "${root}/Blueprint.lock"
	before_lock = Path.read_utf8!(Path.utf8(lock_file))?
	Path.write_utf8!(Path.utf8("${root}/unrelated"), "unselected")?
	CliHarness.check!(inspect!("plan")?.snapshot_digest == first.snapshot_digest, "unselected file changed structural evidence")?
	lock = Lock.parse(before_lock).map_err(|_| ScriptFailed)?
	Path.write_utf8!(Path.utf8(lock_file), { ..lock, sources: lock.sources.append({ name: "unused", provider: "future", ref: "opaque", rev: "one", digest: "future:one" }) }.to_str())?
	CliHarness.check!(inspect!("plan")?.snapshot_digest == first.snapshot_digest, "unselected dependency pin changed structural evidence")?
	# Seed a synthetic successful record to test the consumer of saved evidence.
	record = { schema_version: 1, snapshot: first.snapshot, build_identity: "fixture:prepared", outputs: [{ name: "out", path: "/fixture/output" }] }
	baseline = "${root}/.blueprint/build-records/x86_64-linux/app.scm"
	Path.create_all!(Path.utf8("${root}/.blueprint/build-records/x86_64-linux"))?
	Path.write_utf8!(Path.utf8(baseline), BuildModel.render_record(record).map_err(|_| ScriptFailed)?)?
	unchanged = inspect!("explain")?
	CliHarness.check!(unchanged.baseline == "available" and unchanged.changes.is_empty(), "unchanged declarations differ from saved evidence")?
	Path.write_utf8!(Path.utf8("${root}/recipe.txt"), "library changed")?
	changed = inspect!("explain")?
	CliHarness.check!(changed.changes.any(|change| change.kind == "file-changed" and change.name == "recipe.txt" and change.dependency_path == ["app", "lib"]), "transitive selected edit has no dependency-path explanation")?
	CliHarness.check!(BuildModel.parse_record(Path.read_utf8!(Path.utf8(baseline))?).map_ok(|saved| saved.snapshot) == Ok(first.snapshot), "explanation advanced the successful baseline")?
	Path.write_utf8!(Path.utf8(baseline), "unsupported evidence")?
	unavailable = inspect!("explain")?
	CliHarness.check!(unavailable.baseline == "unavailable" and unavailable.build_identity_status == "unavailable", "malformed evidence was treated as unchanged")?
	Path.delete!(Path.utf8("${root}/recipe.txt"))?
	missing = invoke!(["plan", "build", "app", "--json"])?
	CliHarness.check!(missing.code == 1 and missing.stdout.is_empty() and missing.stderr.contains("missing selected build path"), "missing selected file was treated as complete evidence")?
	Script.pass!("structural planning and transitive explanations without Nix; unrelated files/pins, unavailable evidence and missing selected files")
}

expect Spec.parse(BuildPlanningTest.wire).is_ok()
