import cli.Path
import cli.Cmd
import cli.OsStr
import BuildHarness
import Script
import StandaloneRunner

# Real Linux Nix checks for stable recipes, source selection, provenance,
# rebuild comparison and complete tool roots. Called by the build test group.
ReproducibleGates := [].{
	Record : { schema_version : U64, name : Str, system : Str, derivation : Str, outputs : List({ name : Str, path : Str }), sources : List({ name : Str, provider : Str, ref : Str, rev : Str, digest : Str }) }

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
		config = "app [config] { pf: platform \"${platform_path}\" }\nconfig = [Name(\"reproducers\"), Systems([\"x86_64-linux\"]), Packages(\"nix\", From(NixPackages(\"${suite.pins.nixpkgs.ref}\"))), Environment(\"producer\", [Tools([\"nix#python3\", \"nix#glibc\"])]), Build(\"one\", [Use(\"producer\"), Files([\"recipe.py\"]), Run([\"python3\", \"recipe.py\", \"one\"]), Output(\"output\")]), Build(\"two\", [Use(\"producer\"), Files([\"recipe.py\"]), Run([\"python3\", \"recipe.py\", \"two\"]), Output(\"output\")]), Build(\"random\", [Use(\"producer\"), Files([\"recipe.py\"]), Run([\"python3\", \"recipe.py\", \"random\"]), Output(\"output\")])]\n"
		recipe = "import os, pathlib, sys\nassert (pathlib.Path(os.environ['BLUEPRINT_TOOLS']) / 'nix#glibc/lib/libc.so.6').is_file()\npathlib.Path('output').write_bytes(os.urandom(32) if sys.argv[1] == 'random' else sys.argv[1].encode())\n"
		Path.write_utf8!(Path.utf8("${root}/Blueprint.roc"), config)?
		Path.write_utf8!(Path.utf8("${root}/recipe.py"), recipe)?
		_ = BuildHarness.ok!(suite, place, ["update"])?
		first = record(BuildHarness.ok!(suite, place, ["build", "one", "--json"])?.out)?
		Path.write_utf8!(Path.utf8("${suite.work}/standalone-runner-path"), StandaloneRunner.locate!(place.generated, "one")?)?
		BuildHarness.require!(first.schema_version == 1 and first.name == "one" and first.system == "x86_64-linux", "invalid provenance header")?
		BuildHarness.require!(first.derivation.ends_with(".drv") and first.sources.len() == 1 and first.sources.any(|source| source.name == "nix" and !source.rev.is_empty() and !source.digest.is_empty()), "missing actual derivation or source identity")?
		output = first.outputs.first()?
		BuildHarness.require!(output.name == "out" and Path.read_utf8!(Path.utf8(output.path))? == "one", "provenance output differs from built bytes")?
		checked = record(BuildHarness.ok!(suite, place, ["build", "one", "--rebuild", "--json"])?.out)?
		BuildHarness.require!(checked == first, "deterministic rebuild changed provenance")?
		Path.write_utf8!(Path.utf8("${root}/unrelated"), "an application edit")?
		BuildHarness.link!("${root}/absent", "${root}/unrelated-link")?
		unchanged = record(BuildHarness.ok!(suite, place, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(unchanged.derivation == first.derivation, "unselected file or symlink changed derivation")?
		Path.delete!(Path.utf8("${root}/unrelated-link"))?
		two = record(BuildHarness.ok!(suite, place, ["build", "two", "--json"])?.out)?
		BuildHarness.require!(Path.read_utf8!(Path.utf8(two.outputs.first()?.path))? == "two", "second single-output producer failed")?

		# A CLI binary with different bytes is still the same producer identity.
		patched = "${suite.work}/blueprint-other-patch"
		binary = Path.read_bytes!(Path.utf8(suite.blueprint))?
		Path.write_bytes!(Path.utf8(patched), binary.concat("different CLI patch bytes".to_utf8()))?
		BuildHarness.mode!("755", Path.utf8(patched))?
		other = record(BuildHarness.ok!({ ..suite, blueprint: patched }, place, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(other.derivation == first.derivation, "Blueprint binary identity entered derivation")?
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
		observed = "${suite.work}/other-caller-namespaces"
		separated = BuildHarness.command!(
			suite,
			{
				argv: ["sudo", "-n", "-E", "--", unshare, "--mount", "--net", "--", setpriv, "--reuid=${uid}", "--regid=${gid}", "--clear-groups", bridge, "--caller", observed, suite.blueprint, "build", "one", "--json"],
				cwd: suite.caller,
				extra: [("BLUEPRINT_ROOT", root), ("BLUEPRINT_WORKSPACE", place.workspace), ("BLUEPRINT_GENERATED_ROOT", place.generated), ("BLUEPRINT_LOCK", "authority.lock"), ("ROC_BUILD_RUNNER_READLINK", readlink)],
				stdin: [],
				code: 0,
				service: NoService,
			},
		)?
		namespaces = Path.read_utf8!(Path.utf8(observed))?.split_on("\n")
		BuildHarness.require!(namespaces.first() != Ok(mnt) and namespaces.get(1) != Ok(net), "caller namespace control did not change both namespaces")?
		BuildHarness.require!(record(separated.out)?.derivation == first.derivation, "caller namespace identity entered derivation")?
		BuildHarness.require!(Path.read_bytes!(Path.utf8(place.lock))? == before_authority, "second namespace changed authority")?

		moved_root = "${suite.work}/repro-relocated"
		BuildHarness.tool!("cp", ["-a", "--", root, moved_root])?
		moved = { project: moved_root, workspace: "${moved_root}/work", generated: "${moved_root}/generated", lock: "${moved_root}/authority.lock" }
		relocated = record(BuildHarness.ok!(suite, moved, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(relocated.derivation == first.derivation, "checkout location entered derivation")?
		Path.write_utf8!(Path.utf8("${root}/recipe.py"), "${recipe}# selected recipe changed\n")?
		changed = record(BuildHarness.ok!(suite, place, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(changed.derivation != first.derivation, "selected recipe edit did not change derivation")?
		_ = BuildHarness.ok!(suite, place, ["build", "random"])?
		refused = BuildHarness.blueprint!(suite, place, ["build", "random", "--rebuild"], { code: 1, stdin: [], service: NoService })?
		BuildHarness.require!(refused.out.is_empty() and (refused.err.contains("not deterministic") or refused.err.contains("differs")), "rebuild did not reject nondeterministic bytes")?

		# Run the exact standalone runner without Nix: absence of the mount must
		# refuse before parsing a specification or writing any user output.
		actual_runner = Path.read_utf8!(Path.utf8("${suite.work}/standalone-runner-path"))?
		result = Cmd.new(OsStr.from_str(actual_runner)).clear_envs().env("runnerSpecPath", "/missing/spec.json").run!()?
		BuildHarness.require!(result.status != Exited(0) and Str.from_utf8_lossy(result.stderr_bytes).contains("sandbox witness"), "standalone runner did not fail closed on host")?
		Script.pass!("stable derivation across relocation/CLI bytes; selected sources, multiple producers, tool roots, JSON provenance and deterministic/nondeterministic rebuild checks")
	}
}
