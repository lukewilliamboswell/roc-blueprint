import cli.Path
import cli.Cmd
import cli.OsStr
import BuildHarness
import Script

# Real Linux Nix checks for stable recipes, source selection, provenance,
# rebuild comparison and complete tool roots. Called by the build test group.
ReproducibleGates := [].{
	Record : { schema_version : U64, name : Str, system : Str, derivation : Str, outputs : List({ name : Str, path : Str }), sources : List({ name : Str, provider : Str, ref : Str, rev : Str, digest : Str }) }

	record : Str -> Try(Record, _)
	record = |text| Json.parse(text)

	run! : BuildHarness.Suite => Try({}, _)
	run! = |suite| {
		root = "${suite.work}/repro-project"
		Path.create_dir!(Path.utf8(root))?
		place = { project: root, workspace: "${root}/work", generated: "${root}/generated", lock: "${root}/authority.lock" }
		platform_path = BuildHarness.relative(root, "${suite.root}/blueprint-platform/main.roc")
		config = "app [config] { pf: platform \"${platform_path}\" }\nconfig = [Name(\"reproducers\"), Systems([\"x86_64-linux\"]), Packages(\"nix\", From(NixPackages(\"${suite.pins.nixpkgs.ref}\"))), Environment(\"producer\", [Tools([\"nix#bash\", \"nix#coreutils\", \"nix#glibc\"])]), Build(\"one\", [Use(\"producer\"), Files([\"recipe.sh\"]), Run([\"bash\", \"recipe.sh\", \"one\"]), Output(\"output\")]), Build(\"two\", [Use(\"producer\"), Files([\"recipe.sh\"]), Run([\"bash\", \"recipe.sh\", \"two\"]), Output(\"output\")]), Build(\"random\", [Use(\"producer\"), Files([\"recipe.sh\"]), Run([\"bash\", \"recipe.sh\", \"random\"]), Output(\"output\")])]\n"
		recipe = "set -eu\ntest -f \"$BLUEPRINT_TOOLS/nix#glibc/lib/libc.so.6\"\nif [ \"$1\" = random ]; then head -c 32 /dev/urandom > output; else printf '%s' \"$1\" > output; fi\n"
		Path.write_utf8!(Path.utf8("${root}/Blueprint.roc"), config)?
		Path.write_utf8!(Path.utf8("${root}/recipe.sh"), recipe)?
		_ = BuildHarness.ok!(suite, place, ["update"])?
		first = record(BuildHarness.ok!(suite, place, ["build", "one", "--json"])?.out)?
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

		moved_root = "${suite.work}/repro-relocated"
		BuildHarness.tool!("cp", ["-a", "--", root, moved_root])?
		moved = { project: moved_root, workspace: "${moved_root}/work", generated: "${moved_root}/generated", lock: "${moved_root}/authority.lock" }
		relocated = record(BuildHarness.ok!(suite, moved, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(relocated.derivation == first.derivation, "checkout location entered derivation")?
		Path.write_utf8!(Path.utf8("${root}/recipe.sh"), "${recipe}# selected recipe changed\n")?
		changed = record(BuildHarness.ok!(suite, place, ["build", "one", "--json"])?.out)?
		BuildHarness.require!(changed.derivation != first.derivation, "selected recipe edit did not change derivation")?
		_ = BuildHarness.ok!(suite, place, ["build", "random"])?
		refused = BuildHarness.blueprint!(suite, place, ["build", "random", "--rebuild"], { code: 1, stdin: [], service: NoService })?
		BuildHarness.require!(refused.out.is_empty() and (refused.err.contains("not deterministic") or refused.err.contains("differs")), "rebuild did not reject nondeterministic bytes")?

		# Run the exact standalone runner without Nix: absence of the mount must
		# refuse before parsing a specification or writing any user output.
		result = Cmd.new("bash").arg(OsStr.from_str("${suite.root}/blueprint-nix/build-runner-v1.sh"))
			.env("blueprintCoreutils", "/missing").env("blueprintFind", "/missing").env("blueprintJq", "/missing").run!()?
		BuildHarness.require!(result.status != Exited(0) and Str.from_utf8_lossy(result.stderr_bytes).contains("missing sandbox witness"), "standalone runner did not fail closed on host")?
		Script.pass!("stable derivation across relocation/CLI bytes; selected sources, multiple producers, tool roots, JSON provenance and deterministic/nondeterministic rebuild checks")
	}
}
