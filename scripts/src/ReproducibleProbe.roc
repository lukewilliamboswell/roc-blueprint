import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import BuildHarness
import ReproducibleGates
import Script
import StaticChecks

## Separate CI jobs compare actual derivations from different Linux images and
## CLI patch-version builds. These are synthetic patch tests, not two published
## releases; both binaries retain the same frozen shared runner/toolchain pins.
ReproducibleProbe := [].{
	Observation : { schema_version : U64, variant : Str, cli_version : Str, host : Str, image : Str, provenance : ReproducibleGates.Record }

	run! : Path, Str, Str => Try({}, _)
	run! = |root, variant, output| {
		BuildHarness.require!(["release", "synthetic"].contains(variant), "unknown reproducibility probe variant")?
		repository = Path.to_str(Path.canonicalize!(root)?)?
		destination = if output.starts_with("/") output else "${repository}/${output}"
		BuildHarness.run!(root, "repro-${variant}", |suite| probe!(suite, variant, destination))
	}

	compare! : Str, Str => Try({}, _)
	compare! = |first, second| {
		a : Observation
		a = Json.parse(Path.read_utf8!(Path.utf8(first))?)?
		b : Observation
		b = Json.parse(Path.read_utf8!(Path.utf8(second))?)?
		BuildHarness.require!(a.schema_version == 1 and b.schema_version == 1, "unknown probe schema")?
		BuildHarness.require!(a.variant == "release" and b.variant == "synthetic", "missing release/synthetic pair")?
		BuildHarness.require!(!a.host.is_empty() and !b.host.is_empty() and a.host != b.host and !a.image.is_empty() and !b.image.is_empty() and a.image != b.image, "probes did not identify two different CI hosts/images")?
		BuildHarness.require!(a.cli_version != b.cli_version and b.cli_version.contains("-test"), "probes did not run different CLI patch versions")?
		BuildHarness.require!(a.provenance == b.provenance, "producer derivation, outputs or locked source content_identity differed between hosts/CLI versions")?
		Script.pass!("same producer derivation and outputs on ${a.image}/${a.cli_version} and ${b.image}/${b.cli_version} (synthetic patch test)")
	}

	synthetic_version : Str -> Try(Str, [BadVersion])
	synthetic_version = |version| match (version.split_on("-").first() ?? "").split_on(".") {
		[major, minor, patch] => {
			number = U64.from_str(patch).map_err(|_| BadVersion)?
			Ok("${major}.${minor}.${(number + 1).to_str()}-test")
		}
		_ => Err(BadVersion)
	}
}

probe! : BuildHarness.Suite, Str, Str => Try({}, _)
probe! = |suite, variant, output| {
	# This first build may populate Nix's binary/source caches. Existing suites
	# retain the recorder's offline default; the forced rebuild below is offline.
	variables = suite.variables.append((OsStr.from_str("NIX_RECORDER_ONLINE"), OsStr.from_str("1")))
	online = { ..suite, variables }
	cli_source = Path.utf8("${suite.root}/blueprint-cli/main.roc")
	source = Path.read_utf8!(cli_source)?
	released = StaticChecks.constant(source, "version")?
	expected_version = if variant == "synthetic" {
		patched = ReproducibleProbe.synthetic_version(released)?
		marker = "version = \"${released}\""
		BuildHarness.require!(source.contains(marker), "CLI version literal not found")?
		Path.write_utf8!(cli_source, source.replace_each(marker, "version = \"${patched}\""))?
		# Native build only: reuse the release artifact's other platform hosts.
		Cmd.new(OsStr.from_str(suite.roc)).args(["build", "blueprint-cli/main.roc", "--output=${suite.blueprint}"].map(OsStr.from_str)).cwd(Path.utf8(suite.root)).exec!()?
		patched
	} else released
	actual_version = Cmd.new(OsStr.from_str(suite.blueprint)).arg("--version").capture!()?.trim()
	BuildHarness.require!(actual_version == expected_version, "probe CLI did not report expected patch version")?
	project = "${suite.work}/${variant} producer checkout"
	Path.create_dir!(Path.utf8(project))?
	place = BuildHarness.layout(project)
	platform_path = BuildHarness.relative(project, "${suite.root}/blueprint-platform/main.roc")
	config = "app [config] { pf: platform \"${platform_path}\" }\nconfig = [Name(\"two-host-producer\"), Systems([\"x86_64-linux\"]), Packages(\"nix\", From(NixPackages(\"${suite.pins.nixpkgs.ref}\"))), Environment(\"producer\", [Tools([\"nix#coreutils\"])]), Build(\"copy\", [Use(\"producer\"), Files([\"input.txt\"]), Run([\"cp\", \"input.txt\", \"output\"]), Output(\"output\")])]\n"
	Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), config)?
	Path.write_utf8!(Path.utf8("${project}/input.txt"), "same producer bytes on both independent hosts\n")?
	_ = BuildHarness.ok!(online, place, ["update"])?
	# The public lock projection supplies both Nix's SRI hash and the neutral
	# content content_identity; no test-specific conversion or native lock parser.
	locked : { format : U64, sources : { nix : { content_identity : Str, ref : Str, metadata : { nix : { fetchTree : { narHash : Str, rev : Str } } } } } }
	locked = Json.parse(BuildHarness.ok!(online, place, ["lock", "show", "--json", "nix"])?.out)?
	BuildHarness.require!(locked.format == 2 and locked.sources.nix.metadata.nix.fetchTree.narHash == suite.pins.nixpkgs.nar_hash and locked.sources.nix.ref == suite.pins.nixpkgs.ref, "probe lock projection differs from committed package pin")?
	first = ReproducibleGates.record(BuildHarness.ok!(online, place, ["build", "copy", "--json"])?.out)?
	checked = ReproducibleGates.record(BuildHarness.ok!(suite, place, ["build", "copy", "--rebuild", "--json"])?.out)?
	BuildHarness.require!(first == checked, "offline rebuild changed probe provenance")?
	BuildHarness.require!(first.sources.len() == 1 and first.sources.any(|pin| pin.name == "nix" and pin.digest == locked.sources.nix.content_identity and pin.ref == locked.sources.nix.ref and pin.rev == locked.sources.nix.metadata.nix.fetchTree.rev), "probe provenance differs from verified package pin")?
	BuildHarness.require!(Path.read_utf8!(Path.utf8(first.outputs.first()?.path))? == "same producer bytes on both independent hosts\n", "probe output differs from selected input")?
	observation : ReproducibleProbe.Observation
	observation = { schema_version: 1, variant, cli_version: actual_version, host: Cmd.new("uname").arg("-n").capture!()?.trim(), image: Env.var_str!("ImageOS")?, provenance: first }
	Path.write_utf8!(Path.utf8(output), Json.to_str(observation))?
	Script.pass!("wrote ${variant} actual producer derivation from ${observation.host}/${observation.image}")
}

expect ReproducibleProbe.synthetic_version("0.7.0") == Ok("0.7.1-test")
expect ReproducibleProbe.synthetic_version("1.4.2-rc1") == Ok("1.4.3-test")
expect ReproducibleProbe.synthetic_version("0.7") == Err(BadVersion)
