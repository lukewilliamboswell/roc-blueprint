import cli.Path
import cli.Cmd
import cli.OsStr
import BuildHarness
import Script
import StandaloneRunner

# Real Linux Nix checks for stable recipes, source selection, provenance,
# rebuild comparison and complete tool roots. Called by the build test group.
ReproducibleGates := [].{
	Record : { schema_version : U64, name : Str, system : Str, provider : Str, build_identity : Str, snapshot_digest : Str, metadata : { nix : { derivation : Str } }, outputs : List({ name : Str, path : Str }), sources : List({ name : Str, provider : Str, ref : Str, rev : Str, digest : Str }) }

	Inspection : { prepared : Bool, build_identity : Str, snapshot_digest : Str, baseline : Str, build_identity_status : Str, changes : List({ build : Str, dependency_path : List(Str), kind : Str, name : Str }) }

	inspection : Str -> Try(Inspection, _)
	inspection = |text| Json.parse(text)

	record : Str -> Try(Record, _)
	record = |text| Json.parse(text)

	run! : BuildHarness.Suite => Try({}, _)
	run! = |suite| {
		# The generated root deliberately has spaces: runtime Nix witness mounts
		# must stay valid even though sandbox-paths cannot quote whitespace.
		root = "${suite.work}/repro project [witness]"
		Path.create_dir!(Path.utf8(root))?
		place = { project: root, workspace: "${root}/work", generated: "${root}/generated", lock: "${root}/authority.lock" }
		platform_path = BuildHarness.relative(root, "${suite.root}/blueprint-platform/main.roc")
		config = "app [config] { pf: platform \"${platform_path}\" }\nconfig = [Name(\"reproducers\"), Systems([\"x86_64-linux\"]), Packages(\"nix\", From(NixPackages(\"${suite.pins.nixpkgs.ref}\"))), Executor(\"native\", Nix(\"nix\")), Environment(\"producer\", [Tools([\"nix#python3\", \"nix#glibc\"])]), Build(\"one\", [Use(\"producer\"), Execute(\"native\"), Files([\"recipe.py\"]), Run([\"python3\", \"recipe.py\", \"one\"]), Output(\"output\")]), Build(\"two\", [Use(\"producer\"), Execute(\"native\"), Files([\"recipe.py\"]), Run([\"python3\", \"recipe.py\", \"two\"]), Output(\"output\")]), Build(\"random\", [Use(\"producer\"), Execute(\"native\"), Files([\"recipe.py\"]), Run([\"python3\", \"recipe.py\", \"random\"]), Output(\"output\")])]\n"
		recipe = "import os, pathlib, sys\nassert (pathlib.Path(os.environ['BLUEPRINT_TOOLS']) / 'nix#glibc/lib/libc.so.6').is_file()\npathlib.Path('output').write_bytes(os.urandom(32) if sys.argv[1] == 'random' else sys.argv[1].encode())\n"
		Path.write_utf8!(Path.utf8("${root}/Blueprint.roc"), config)?
		Path.write_utf8!(Path.utf8("${root}/recipe.py"), recipe)?
		_ = BuildHarness.ok!(suite, place, ["update"])?
		before_plan = BuildHarness.events!(suite)?.len()
		declared = inspection(BuildHarness.ok!(suite, place, ["plan", "build", "one", "--json"])?.out)?
		BuildHarness.require!(!declared.prepared and declared.build_identity.is_empty() and declared.baseline == "unavailable" and BuildHarness.events!(suite)?.len() == before_plan, "structural planning executed provider commands or claimed an exact identity")?
		prepared = inspection(BuildHarness.ok!(suite, place, ["plan", "build", "one", "--prepare", "--json"])?.out)?
		BuildHarness.require!(prepared.prepared and prepared.build_identity.ends_with(".drv") and prepared.snapshot_digest == declared.snapshot_digest and prepared.baseline == "unavailable", "prepared plan has different declaration evidence or advanced baseline")?
		for event in BuildHarness.events!(suite)?.drop_first(before_plan) {
			BuildHarness.require!(event.kind != "nix" or (!event.argv.contains("build") and event.argv.contains("allow-import-from-derivation") and event.argv.contains("false")), "planning executed a build or allowed import from derivation")?
		}
		first = record(BuildHarness.ok!(suite, place, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(first.build_identity == prepared.build_identity and first.snapshot_digest == prepared.snapshot_digest, "execution diverged from prepared recipe/evidence")?
		explained = inspection(BuildHarness.ok!(suite, place, ["explain", "build", "one", "--json"])?.out)?
		BuildHarness.require!(explained.baseline == "available" and explained.changes.is_empty(), "successful build did not establish an unchanged baseline")?
		# Evaluation is pure: Nix reads the build's selected files from the
		# host's copy as a locked path, through a record beside the flake.
		for event in BuildHarness.events!(suite)? {
			BuildHarness.require!(event.kind != "nix" or !event.argv.contains("--impure"), "Nix was asked to evaluate impurely: ${Str.inspect(event.argv)}")?
		}
		snapshot_text = Path.read_utf8!(Path.utf8("${place.generated}/project-one.json"))?
		snapshot : { path : Str, narHash : Str }
		snapshot = Json.parse(snapshot_text)?
		BuildHarness.require!(snapshot.path == "${place.workspace}/snapshots/one" and !BuildHarness.exists!("${place.workspace}/snapshots"), "the project record ${snapshot_text} names another copy, or the copy outlived the build")?
		# The derivation's one source is that copy, as Nix stored it: exactly
		# the selected files, with the NAR hash the record locks.
		sources = Cmd.new("nix-store").args(["--query", "--references", first.build_identity].map(OsStr.from_str)).capture!()?.split_on("\n").keep_if(|line| line.ends_with("-source"))
		project_source = sources.first()?
		stored_hash = Cmd.new("nix").args(["hash", "path", project_source].map(OsStr.from_str)).capture!()?.trim()
		BuildHarness.require!(sources.len() == 1 and stored_hash == snapshot.narHash and BuildHarness.names!(project_source)? == ["recipe.py"], "the derivation's project source ${Str.inspect(sources)} is not the recorded copy of exactly the selected files")?
		Path.write_utf8!(Path.utf8("${suite.work}/standalone-runner-path"), StandaloneRunner.locate!(place.generated, "one")?)?
		BuildHarness.require!(first.schema_version == 2 and first.name == "one" and first.system == "x86_64-linux", "invalid provenance header")?
		BuildHarness.require!(first.provider == "nix" and first.build_identity == first.metadata.nix.derivation and first.build_identity.ends_with(".drv") and first.sources.len() == 1 and first.sources.any(|source| source.name == "nix" and !source.rev.is_empty() and !source.digest.is_empty()), "missing actual derivation or source identity")?
		output = first.outputs.first()?
		BuildHarness.require!(output.name == "out" and Path.read_utf8!(Path.utf8(output.path))? == "one", "provenance output differs from built bytes")?
		checked = record(BuildHarness.ok!(suite, place, ["build", "one", "--rebuild", "--json"])?.out)?
		BuildHarness.require!(checked == first, "deterministic rebuild changed provenance")?
		# Python only launches the native CLI under a restrictive inherited umask.
		# Rebuild forces the sandbox user to read the newly mounted witness.
		before_restrictive = Path.read_bytes!(Path.utf8(place.lock))?
		python = BuildHarness.which!("python3")?
		restrictive = BuildHarness.command!(
			suite,
			{
				argv: [python, "-c", "import os,sys; os.umask(0o077); os.execv(sys.argv[1],sys.argv[1:])", suite.blueprint, "build", "one", "--rebuild", "--json"],
				cwd: suite.caller,
				extra: [("BLUEPRINT_ROOT", root), ("BLUEPRINT_WORKSPACE", place.workspace), ("BLUEPRINT_GENERATED_ROOT", place.generated), ("BLUEPRINT_LOCK", "authority.lock")],
				stdin: [],
				code: 0,
				service: NoService,
			},
		)?
		BuildHarness.require!(record(restrictive.out)? == first, "restrictive umask changed build provenance")?
		BuildHarness.require!(Path.read_bytes!(Path.utf8(place.lock))? == before_restrictive, "restrictive umask changed authority")?
		Path.write_utf8!(Path.utf8("${root}/unrelated"), "an application edit")?
		BuildHarness.link!("${root}/absent", "${root}/unrelated-link")?
		unrelated = inspection(BuildHarness.ok!(suite, place, ["explain", "build", "one", "--json"])?.out)?
		BuildHarness.require!(unrelated.snapshot_digest == first.snapshot_digest and unrelated.changes.is_empty(), "unselected input changed selected evidence")?
		unchanged = record(BuildHarness.ok!(suite, place, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(unchanged.build_identity == first.build_identity, "unselected file or symlink changed derivation")?
		BuildHarness.require!(Path.read_utf8!(Path.utf8("${place.generated}/project-one.json"))? == snapshot_text, "an unselected file or symlink entered the copy Nix reads")?
		Path.delete!(Path.utf8("${root}/unrelated-link"))?
		two = record(BuildHarness.ok!(suite, place, ["build", "two", "--json"])?.out)?
		BuildHarness.require!(Path.read_utf8!(Path.utf8(two.outputs.first()?.path))? == "two", "second single-output producer failed")?

		# A CLI binary with different bytes is still the same producer identity.
		patched = "${suite.work}/blueprint-other-patch"
		binary = Path.read_bytes!(Path.utf8(suite.blueprint))?
		Path.write_bytes!(Path.utf8(patched), binary.concat("different CLI patch bytes".to_utf8()))?
		BuildHarness.mode!("755", Path.utf8(patched))?
		other = record(BuildHarness.ok!({ ..suite, blueprint: patched }, place, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(other.build_identity == first.build_identity, "Blueprint binary identity entered derivation")?
		# A second actual caller kernel namespace must name the same recipe.
		# Privileges are dropped before any caller code executes.
		readlink = BuildHarness.which!("readlink")?
		mnt = Cmd.new(OsStr.from_str(readlink)).arg("/proc/self/ns/mnt").capture!()?.trim()
		net = Cmd.new(OsStr.from_str(readlink)).arg("/proc/self/ns/net").capture!()?.trim()
		before_authority = Path.read_bytes!(Path.utf8(place.lock))?
		bridge = StandaloneRunner.bridge!({ root: suite.root, work: suite.work })?
		unshare = BuildHarness.which!("unshare")?
		setpriv = BuildHarness.which!("setpriv")?
		uid = Cmd.new("id").arg("-u").capture!()?.trim()
		gid = Cmd.new("id").arg("-g").capture!()?.trim()
		# sudo's secure_path replaces PATH even with -E. Restore the suite's
		# declared recorder/tools path explicitly before the unprivileged caller.
		(_, path_value) = suite.variables.find_first(|(name, _)| name == OsStr.from_str("PATH"))?
		caller_path = OsStr.to_str_try(path_value)?
		env = BuildHarness.which!("env")?
		BuildHarness.require!(env.starts_with("/nix/store/") and caller_path.starts_with("${suite.work}/bin:"), "namespace caller requires pinned env and the suite's recording PATH")?
		observed = "${suite.work}/other-caller-namespaces"
		separated = BuildHarness.command!(
			suite,
			{
				argv: ["sudo", "-n", "-E", "--", env, "PATH=${caller_path}", unshare, "--mount", "--net", "--", setpriv, "--reuid=${uid}", "--regid=${gid}", "--clear-groups", bridge, "--caller", observed, suite.blueprint, "build", "one", "--json"],
				cwd: suite.caller,
				extra: [("BLUEPRINT_ROOT", root), ("BLUEPRINT_WORKSPACE", place.workspace), ("BLUEPRINT_GENERATED_ROOT", place.generated), ("BLUEPRINT_LOCK", "authority.lock"), ("ROC_BUILD_RUNNER_READLINK", readlink)],
				stdin: [],
				code: 0,
				service: NoService,
			},
		)?
		namespaces = Path.read_utf8!(Path.utf8(observed))?.split_on("\n")
		BuildHarness.require!(namespaces.first() != Ok(mnt) and namespaces.get(1) != Ok(net), "caller namespace control did not change both namespaces")?
		BuildHarness.require!(record(separated.out)?.build_identity == first.build_identity, "caller namespace identity entered derivation")?
		BuildHarness.require!(Path.read_bytes!(Path.utf8(place.lock))? == before_authority, "second namespace changed authority")?

		moved_root = "${suite.work}/repro-relocated"
		BuildHarness.tool!("cp", ["-a", "--", root, moved_root])?
		moved = { project: moved_root, workspace: "${moved_root}/work", generated: "${moved_root}/generated", lock: "${moved_root}/authority.lock" }
		relocated = record(BuildHarness.ok!(suite, moved, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(relocated.build_identity == first.build_identity, "checkout location entered derivation")?
		Path.write_utf8!(Path.utf8("${root}/recipe.py"), "${recipe}# selected recipe changed\n")?
		change_plan = inspection(BuildHarness.ok!(suite, place, ["explain", "build", "one", "--prepare", "--json"])?.out)?
		BuildHarness.require!(change_plan.baseline == "available" and change_plan.build_identity_status == "changed" and change_plan.changes.any(|change| change.kind == "file-changed" and change.name == "recipe.py"), "selected source edit has no precise explanation")?
		changed = record(BuildHarness.ok!(suite, place, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(changed.build_identity != first.build_identity, "selected recipe edit did not change derivation")?
		_ = BuildHarness.ok!(suite, place, ["build", "random"])?
		baseline_file = "${place.workspace}/build-records/x86_64-linux/random.scm"
		successful_baseline = Path.read_bytes!(Path.utf8(baseline_file))?
		refused = BuildHarness.blueprint!(suite, place, ["build", "random", "--rebuild"], { code: 1, stdin: [], service: NoService })?
		BuildHarness.require!(Path.read_bytes!(Path.utf8(baseline_file))? == successful_baseline, "failed rebuild replaced successful baseline")?
		BuildHarness.require!(refused.out.is_empty() and (refused.err.contains("not deterministic") or refused.err.contains("differs")), "rebuild did not reject nondeterministic bytes")?

		# Run the exact standalone runner without Nix: absence of the mount must
		# refuse before parsing a specification or writing any user output.
		actual_runner = Path.read_utf8!(Path.utf8("${suite.work}/standalone-runner-path"))?
		result = Cmd.new(OsStr.from_str(actual_runner)).clear_envs().env("runnerSpecPath", "/missing/spec.json").run!()?
		BuildHarness.require!(result.status != Exited(0) and Str.from_utf8_lossy(result.stderr_bytes).contains("sandbox witness"), "standalone runner did not fail closed on host")?
		Script.pass!("stable derivation across relocation/CLI bytes; selected sources, multiple producers, tool roots, JSON provenance and deterministic/nondeterministic rebuild checks")
	}
}
