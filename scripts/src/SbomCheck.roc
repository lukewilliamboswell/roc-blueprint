import cli.Path
import core.Manifest
import core.Sbom
import core.Project
import core.Sidecar
import compilers.Bootstrap
import Bundle
import Integrity
import SbomFiles
import "../../tests/sbom/fixtures/native-linux.spdx.json" as fixture_3 : Str
import "../../tests/sbom/fixtures/native-linux.spdx-2.3.json" as fixture_2 : Str
import "../../tests/sbom/fixtures/native-linux.cdx.json" as fixture_cdx : Str
import "../../tests/sbom/fixtures/input/inventory.json" as inventory_json : Str

## The checks `scripts/check_sbom.roc` runs: the general ones of
## `core.Sidecar` and `core.Manifest`, which the standalone tool's `check`
## runs too, and `release!`, which holds Blueprint's own release sidecars to
## the release authorities committed in this repository.
SbomCheck := [].{
	Evidence : Sidecar.Evidence

	Checked : Sidecar.Checked

	## The profile checks every sidecar gets: `Sidecar.check`.
	profile : Str -> Try(Checked, Str)
	profile = Sidecar.check

	against_inventory : Checked, Sbom.Inventory -> Try({}, Str)
	against_inventory = Sidecar.against_inventory

	same_graph : Checked, Checked -> Bool
	same_graph = Sidecar.same_graph

	## The evidence manifest at `path`, held to the files it names: its
	## subject in `artifacts` (or beside the manifest), each listed sidecar
	## beside it, and the inventory at `inventory`, or else the
	## `<subject>.inventory.json` the release recipe leaves beside the
	## manifest, when there is one.
	manifest! : Str, Str, Str => Try(Manifest.Manifest, _)
	manifest! = |path, artifacts, inventory| {
		text = Path.read_utf8!(Path.utf8(path))?
		listed = Manifest.read(text).map_err(|problem| Invalid("${path}: ${problem}"))?
		subject_path = if (artifacts.is_empty()) Manifest.beside(path, listed.subject.filename) else "${artifacts}/${listed.subject.filename}"
		subject_bytes = Path.read_bytes!(Path.utf8(subject_path)).map_err(|_| Invalid("${path}: no subject ${subject_path}"))?
		var $sidecars = []
		for entry in listed.sidecars {
			match Path.read_bytes!(Path.utf8(Manifest.beside(path, entry.filename))) {
				Ok(bytes) => {
					$sidecars = $sidecars.append({ filename: entry.filename, sha256: Integrity.digest(bytes), size: bytes.len() })
				}
				Err(_) => {}
			}
		}
		left_behind = Manifest.beside(path, "${listed.subject.filename}.inventory.json")
		inventory_path = if !inventory.is_empty() inventory else if (Path.is_file!(Path.utf8(left_behind)) ?? False) left_behind else ""
		measured = if inventory_path.is_empty() Unmeasured else Measured(Integrity.digest(Path.read_bytes!(Path.utf8(inventory_path))?))
		Manifest.check(text, { subject: { sha256: Integrity.digest(subject_bytes), size: subject_bytes.len() }, inventory: measured, sidecars: $sidecars }).map_err(|problem| Invalid("${path}: ${problem}"))
	}

	## A release sidecar against the release authorities committed at `root`.
	release! : Checked, Str => Try({}, _)
	release! = |checked, root| {
		document = checked.document
		evidence = checked.evidence
		ids = document.packages_.map(|entry| entry.id)
		find = |id| document.packages_.find_first(|entry| entry.id == id)
		cli_source = Path.read_utf8!(Path.utf8("${root}/blueprint-cli/main.roc"))?
		if sorted(header_imports(cli_source, [])) != sorted(prefixed(evidence.inspected, "roc-import:")) {
			return Err(Invalid("release import inventory stale/omitted"))
		}
		tag = Path.read_utf8!(Path.utf8("${root}/blueprint-cli/compiler-version"))?.trim()
		match find("roc-builder") {
			Ok(builder) => if builder.version != tag or !document.relationships.any(|edge| edge.from == "Subject" and edge.to == "roc-builder" and edge.relation == "dependsOn" and edge.scope == "build") {
				return Err(Invalid("the build compiler is not a build dependency at ${tag}"))
			}
			Err(_) => return Err(Invalid("known build compiler omitted"))
		}
		tool_source = document.name.starts_with("roc-blueprint-sbom-")
		if tool_source {
			tool = Path.read_utf8!(Path.utf8("${root}/scripts/sbom.roc"))?
			if sorted(header_imports(tool, ["roc"])) != sorted(prefixed(evidence.inspected, "tool-import:")) {
				return Err(Invalid("standalone tool import omitted"))
			}
			for name in ["scripts/sbom.roc", "scripts/src/SbomFiles.roc"] {
				digest = Integrity.digest(Path.read_bytes!(Path.utf8("${root}/${name}"))?)
				if !evidence.inspected.contains("tool-source:${name}:${digest}") {
					return Err(Invalid("standalone tool source ${name} omitted"))
				}
			}
			if !["basic-cli", "core", "http", "sqlite", "rust-std"].all(|id| ids.contains(id)) or ids.contains("roc-embedded") {
				return Err(Invalid("standalone tool inventory omits a dependency or claims the compiler ships"))
			}
		}
		cargo_lock = Path.read_utf8!(Path.utf8("${root}/sbom/upstream/basic-cli-Cargo.lock"))?
		cargo : { components : List(Sbom.Component) }
		cargo = Json.parse(Path.read_utf8!(Path.utf8("${root}/sbom/basic-cli-cargo.json"))?).map_err(|_| Invalid("invalid reviewed Cargo graph"))?
		if evidence.target != "source" or tool_source {
			if !cargo.components.all(|entry| ids.contains(entry.id)) {
				return Err(Invalid("known upstream resolution component omitted"))
			}
			if sorted(cargo_packages(cargo_lock)) != sorted(cargo.components.map(|entry| "${entry.name}@${entry.version}:${entry.sha256}")) {
				return Err(Invalid("supplemental Cargo graph omits/conflicts with original upstream lock"))
			}
		}
		if evidence.target != "source" {
			if !["basic-cli", "http", "weaver", "roc-embedded", "sqlite"].all(|id| ids.contains(id)) {
				return Err(Invalid("known shipped/native input omitted"))
			}
			archive = Bootstrap.compiler(tag, evidence.target).map_err(|_| Invalid("no embedded compiler for ${evidence.target}"))?
			embedded = find("roc-embedded").map_err(|_| Invalid("embedded compiler omitted"))?
			if embedded.sha256 != archive.sha256 or embedded.version != tag {
				return Err(Invalid("embedded compiler identity differs from the bootstrap table"))
			}
		}
		if ids.contains("core") {
			bundles = Path.read_utf8!(Path.utf8("${root}/dist/bundles.txt"))?
			core_name = Bundle.archive(bundles, "roc-blueprint-core").map_err(|_| Invalid("missing core source bundle"))?
			core = find("core").map_err(|_| Invalid("missing core"))?
			if core.sha256 != Integrity.digest(Path.read_bytes!(Path.utf8("${root}/dist/${core_name}"))?) {
				return Err(Invalid("core bundle digest differs"))
			}
		}
		if evidence.target == "source" {
			# Every member of the released archive is stated by its digest.
			for member in SbomFiles.archive_members!("${root}/dist/${document.name}")? {
				if !document.packages_.any(|entry| entry.sha256 == member.sha256) {
					return Err(Invalid("archive member ${member.name} is not stated by SHA-256"))
				}
			}
		}
		if ids.contains("linker-inputs") {
			recipe = Path.read_utf8!(Path.utf8("${root}/blueprint-platform/main.roc"))?
			members = Bundle.target_inputs(recipe).map_err(|_| Invalid("platform recipe has no declared linker members"))?
			for member in members {
				digest = Integrity.digest(Path.read_bytes!(Path.utf8("${root}/blueprint-platform/${member}"))?)
				if !evidence.inspected.contains("platform-member:${member}:${digest}") {
					return Err(Invalid("known delivered native member omitted: ${member}"))
				}
			}
		}
		# `targets` is a Roc keyword, so the field is read under another name.
		native : { artifacts : { all : { sha256 : Str } } }
		native = Json.parse(Path.read_utf8!(Path.utf8("${root}/link-inputs.lock.json"))?.replace_each("\"targets\"", "\"artifacts\"")).map_err(|_| Invalid("invalid link-inputs.lock.json"))?
		if !evidence.inspected.contains("linker-archive:${native.artifacts.all.sha256}") {
			return Err(Invalid("linker input archive omitted"))
		}
		Ok({})
	}
}

unique : List(Str) -> List(Str)
unique = |values| values.fold([], |all, value| if (all.contains(value)) all else all.append(value))

sorted : List(Str) -> List(Str)
sorted = |values| values.sort_with(Project.bytewise)

prefixed : List(Str), Str -> List(Str)
prefixed = |values, prefix| values.keep_if(|value| value.starts_with(prefix)).map(|value| value.drop_prefix(prefix))

## The package and platform URLs an app header names, except `skipped` names.
header_imports : Str, List(Str) -> List(Str)
header_imports = |source, skipped| {
	header = source.split_on("\n}\n").first() ?? ""
	header.split_on("\n").fold(
		[],
		|all, line| {
			trimmed = line.trim()
			match trimmed.split_on(": ") {
				[name, .. as rest] if !trimmed.starts_with("#") and !skipped.contains(name) and !name.is_empty() and name.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_') =>
					match Str.join_with(rest, ": ").drop_prefix("platform ").split_on("\"") {
						["", url, ..] => all.append(url)
						_ => all
					}
				_ => all
			}
		},
	)
}

## `name@version:checksum` for each package of a Cargo.lock but the host.
cargo_packages : Str -> List(Str)
cargo_packages = |text| {
	field = |block, key| (block.split_on("\n").find_first(|line| line.starts_with("${key} = \"")) ?? "").split_on("\"").get(1) ?? ""
	text.split_on("[[package]]").drop_first(1).keep_if(|block| field(block, "name") != "roc_host").map(|block| "${field(block, "name")}@${field(block, "version")}:${field(block, "checksum")}")
}

expect header_imports("app [main!] {\n\tcli: platform \"https://a/b.tar.zst\",\n\t# x: \"no\"\n\tcore: \"../core/main.roc\",\n\troc: \"nightly\",\n}\n", ["roc"]) == ["https://a/b.tar.zst", "../core/main.roc"]
expect cargo_packages("[[package]]\nname = \"a\"\nversion = \"1\"\nchecksum = \"c\"\n\n[[package]]\nname = \"roc_host\"\nversion = \"0\"\n") == ["a@1:c"]

# The profile accepts the committed fixtures of both versions, as one graph,
# and refuses each way a sidecar can misstate its subject or evidence.
expect [fixture_3, fixture_2, fixture_cdx].all(|text| SbomCheck.profile(text).is_ok())
expect {
	three = SbomCheck.profile(fixture_3) ?? crash "fixture"
	two = SbomCheck.profile(fixture_2) ?? crash "fixture"
	inventory : Sbom.Inventory
	inventory = Json.parse(inventory_json) ?? crash "inventory"
	bom = SbomCheck.profile(fixture_cdx) ?? crash "fixture"
	SbomCheck.same_graph(three, two) and SbomCheck.same_graph(three, bom) and SbomCheck.against_inventory(three, inventory).is_ok() and SbomCheck.against_inventory(two, { ..inventory, components: inventory.components.drop_first(1) }).is_err()
}
expect [fixture_3, fixture_2, fixture_cdx].all(
	|text| [
		text.replace_each("final-deliverable-sha256", "source-tree"),
		text.replace_each(Sbom.profile, "blueprint-spdx-2.3-v1"),
		text.replace_each("Reviewed fixture composition declaration", "Built in /Users/someone/work"),
		text.replace_each("native-closure", ""),
		text.replace_each("\\\"status\\\":\\\"incomplete\\\"", "\\\"status\\\":\\\"unknown\\\""),
		text.replace_each("2026-10-21T00:00:00Z", "2026-99-01T00:00:00Z"),
	].all(|broken| broken != text and SbomCheck.profile(broken).is_err()),
)
