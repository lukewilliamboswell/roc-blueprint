import cli.Path
import core.Sbom
import core.Project
import compilers.Bootstrap
import Bundle
import Integrity
import "../../tests/sbom/fixtures/native-linux.spdx.json" as fixture_3 : Str
import "../../tests/sbom/fixtures/native-linux.spdx-2.3.json" as fixture_2 : Str
import "../../tests/sbom/fixtures/input/inventory.json" as inventory_json : Str

## Independent checks of a written SBOM sidecar, of either SPDX version, for
## the release job, the bundle smoke test and the test suite. `profile` holds a
## document to the blueprint profile beyond the SPDX model `Sbom.read` checks:
## one described subject with its final digest, a connected graph, and
## evidence that accounts for every inspected input. `against_inventory` and
## `release!` compare it with what produced it.
SbomCheck := [].{
	Evidence : { profile : Str, revision : Str, target : Str, coverage : List(Sbom.Coverage), inspected : List(Str), dispositions : List(Sbom.Disposition) }

	Checked : { document : Sbom.Document, evidence : Evidence, subject : Sbom.Package }

	profile : Str -> Try(Checked, Str)
	profile = |text| {
		document = Sbom.read(text)?
		ids = document.packages_.map(|entry| entry.id)
		if document.roots != ["Subject"] {
			return Err("the document must describe exactly its delivered subject")
		}
		subject = document.packages_.find_first(|entry| entry.id == "Subject").map_err(|_| "missing delivered subject")?
		if subject.name.is_empty() or subject.name.contains("/") or subject.name.contains("\\") or subject.version.is_empty() or !Integrity.is_hex(subject.sha256, 64) {
			return Err("the subject needs a file name, a version and a lowercase SHA-256")
		}
		subject_meta : Try({ target : Str, digest_kind : Str }, _)
		subject_meta = Json.parse(subject.comment)
		meta = subject_meta.map_err(|_| "the subject comment does not name its target")?
		if meta.target.is_empty() or meta.digest_kind != "final-deliverable-sha256" {
			return Err("the subject digest must be the final deliverable's")
		}
		keys = document.relationships.map(|edge| "${edge.from} ${edge.relation} ${edge.scope} ${edge.to}")
		if keys.len() != unique(keys).len() {
			return Err("duplicate relationship")
		}
		var $reached = ["Subject"]
		var $changed = True
		while $changed {
			$changed = False
			for edge in document.relationships {
				if $reached.contains(edge.from) and !$reached.contains(edge.to) {
					$reached = $reached.append(edge.to)
					$changed = True
				}
				if $reached.contains(edge.to) and !$reached.contains(edge.from) {
					$reached = $reached.append(edge.from)
					$changed = True
				}
			}
		}
		if ids.any(|id| !$reached.contains(id)) {
			return Err("disconnected component")
		}
		evidence = match document.evidence {
			[only] => {
				decoded : Try(Evidence, _)
				decoded = Json.parse(only)
				decoded.map_err(|_| "the evidence annotation is not profile evidence")?
			}
			_ => return Err("expected exactly one evidence annotation")
		}
		if evidence.profile != Sbom.profile {
			return Err("evidence names profile ${evidence.profile}, not ${Sbom.profile}")
		}
		if evidence.target != meta.target {
			return Err("evidence target differs from the subject's")
		}
		if !document.namespace.ends_with("revision-${evidence.revision}") {
			return Err("namespace does not end with its evidence revision")
		}
		if evidence.coverage.is_empty() {
			return Err("unknown coverage silently omitted")
		}
		for scope in evidence.coverage {
			if scope.scope.is_empty() or scope.reason.is_empty() or scope.contact.is_empty() or !["complete", "incomplete", "excluded", "verified-empty"].contains(scope.status) {
				return Err("invalid or unexplained coverage")
			}
		}
		inputs = evidence.dispositions.map(|entry| entry.input)
		if unique(evidence.inspected).len() != evidence.inspected.len() or unique(inputs).len() != inputs.len() or sorted(evidence.inspected) != sorted(inputs) {
			return Err("unexplained known-input omission")
		}
		if evidence.dispositions.any(|entry| entry.reason.is_empty() or (!entry.component.is_empty() and !ids.contains(entry.component))) {
			return Err("input disposition without a reason or with an unknown component")
		}
		for entry in document.packages_ {
			if entry.version.is_empty() or entry.license.is_empty() or (entry.supplier != "NOASSERTION" and !entry.supplier.starts_with("Person: ") and !entry.supplier.starts_with("Organization: ")) {
				return Err("package ${entry.id} needs a version, a license and an SPDX supplier")
			}
			if entry.id != "Subject" {
				identity : Try({ identity : Str, origin : Str, target : Str }, _)
				identity = Json.parse(entry.comment)
				match identity {
					Ok(found) => if found.identity.is_empty() or found.origin.is_empty() or (evidence.target != "source" and !found.target.is_empty() and found.target != evidence.target) {
						return Err("package ${entry.id} lacks its identity or names another target")
					}
					Err(_) => return Err("package ${entry.id} does not record its identity")
				}
			}
		}
		if ["/Users/", "/home/", "/private/", "/tmp/", "/nix/store/", "github_pat_", "ghp_", "BEGIN PRIVATE KEY"].any(|marker| text.contains(marker)) {
			return Err("the document holds a developer path or credential")
		}
		Ok({ document, evidence, subject })
	}

	## The inventory a sidecar was bound from is what its evidence states.
	against_inventory : Checked, Sbom.Inventory -> Try({}, Str)
	against_inventory = |checked, inventory|
		if inventory.target != checked.evidence.target or inventory.inspected != checked.evidence.inspected or inventory.inputs != checked.evidence.dispositions or inventory.coverage != checked.evidence.coverage {
			Err("evidence differs from the inventory")
		} else if sorted(inventory.components.map(|entry| entry.id)) != sorted(checked.document.packages_.map(|entry| entry.id).drop_if(|id| id == "Subject")) {
			Err("known component omission")
		} else {
			Ok({})
		}

	## Two renderings of one subject state the same package graph.
	same_graph : Checked, Checked -> Bool
	same_graph = |a, b| { ..a.document, version: "" } == { ..b.document, version: "" }

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
expect [fixture_3, fixture_2].all(|text| SbomCheck.profile(text).is_ok())
expect {
	three = SbomCheck.profile(fixture_3) ?? crash "fixture"
	two = SbomCheck.profile(fixture_2) ?? crash "fixture"
	inventory : Sbom.Inventory
	inventory = Json.parse(inventory_json) ?? crash "inventory"
	SbomCheck.same_graph(three, two) and SbomCheck.against_inventory(three, inventory).is_ok() and SbomCheck.against_inventory(two, { ..inventory, components: inventory.components.drop_first(1) }).is_err()
}
expect [fixture_3, fixture_2].all(
	|text| [
		text.replace_each("final-deliverable-sha256", "source-tree"),
		text.replace_each(Sbom.profile, "blueprint-spdx-2.3-v1"),
		text.replace_each("Reviewed fixture composition declaration", "Built in /Users/someone/work"),
		text.replace_each("native-closure", ""),
		text.replace_each("\\\"status\\\":\\\"incomplete\\\"", "\\\"status\\\":\\\"unknown\\\""),
		text.replace_each("2026-10-21T00:00:00Z", "2026-99-01T00:00:00Z"),
	].all(|broken| broken != text and SbomCheck.profile(broken).is_err()),
)
