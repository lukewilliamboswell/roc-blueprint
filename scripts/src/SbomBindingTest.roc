import cli.Env
import cli.Path
import core.Manifest
import core.Sbom
import core.Spdx3
import Process
import SbomTest
import Script

## The native `scripts/sbom.roc` tool against read-only copies of
## `tests/sbom/fixtures/input`: `inspect` reproduces the committed inventory,
## `bind` writes SPDX 3.0.1, SPDX 2.3 and CycloneDX 1.7 that read back to one
## package graph and are the committed `native-linux` renderings, both
## default sidecars and the evidence manifest beside the artifact when no
## output is named, `check --manifest` holds that manifest to the files, and
## every refusal the tool promises holds. Then against read-only copies of
## `tests/sbom/fixtures/source-import`, as its `expected.json` states: each
## accepted consumer target's inventory, the `native-source-import`
## renderings from `bind`, and each refusal with its exact message. Inputs
## are never changed.
##
## `chmod`, `ln -s` and `mkfifo` set up the cases basic-cli cannot create; the
## checks themselves are Roc.
SbomBindingTest := [].{
	run! : Str, Str, Str => Try({}, _)
	run! = |tool, fixtures, source_import| {
		work = Path.to_str(Env.create_temp_dir_with_prefix!("blueprint-sbom-binding-")?)?
		result = cases!(tool, fixtures, work)
		_ = Path.delete_all!(Path.utf8(work))
		result?
		imported = Path.to_str(Env.create_temp_dir_with_prefix!("blueprint-sbom-source-import-")?)?
		outcome = source_import!(tool, source_import, imported)
		_ = Path.delete_all!(Path.utf8(imported))
		outcome?
		reviewed = Path.to_str(Env.create_temp_dir_with_prefix!("blueprint-sbom-reviewed-source-")?)?
		bound = reviewed_source!(tool, reviewed)
		_ = Path.delete_all!(Path.utf8(reviewed))
		bound
	}
}

inputs = ["Spec", "Lock", "composition.json", "inventory.json", "subject.json", "context.json", "sample-artifact"]

## Copy `names` from `fixtures` into `work`, read-only, and return each with
## its text, for `guarded!` to hold unchanged.
staged! : Str, Str, List(Str) => Try(List((Str, Str)), _)
staged! = |fixtures, work, names| {
	var $original = []
	for name in names {
		text = Path.read_utf8!(Path.utf8("${fixtures}/${name}"))?
		Path.write_utf8!(Path.utf8("${work}/${name}"), text)?
		$original = $original.append((name, text))
	}
	_ = Process.succeed!(Process.command("chmod", ["0444"].concat(names), work))?
	Ok($original)
}

## Run the tool in `work`, require the exit it must have, and require every
## staged input to be as it was.
guarded! : Str, List(Str), Str, List((Str, Str)), Bool => Try(Process.Outcome, _)
guarded! = |tool, args, work, original, success| {
	result = Process.traced!(Process.command(tool, args, work))?
	if (result.code == 0) != success {
		return Script.fail!("sbom ${Str.join_with(args, " ")} ${if (success) "failed" else "succeeded"}: ${result.stderr}")
	}
	for (name, text) in original {
		if Path.read_utf8!(Path.utf8("${work}/${name}")) != Ok(text) {
			return Script.fail!("sbom ${Str.join_with(args, " ")} changed its input ${name}")
		}
	}
	Ok(result)
}

## The committed rendering `name` of the suite's own cases.
rendering! : Str => Try(Str, _)
rendering! = |name|
	match SbomTest.outputs.find_first(|file| file.name == name) {
		Ok(file) => Ok(file.text)
		Err(_) => Script.fail!("the suite renders no ${name}")
	}

cases! = |tool, fixtures, work| {
	original = staged!(fixtures, work, inputs)?
	call! = |args, success| guarded!(tool, args, work, original, success).map_ok(|_| {})
	refused! = |args, reason| {
		result = guarded!(tool, args, work, original, False)?
		if !result.stderr.contains(reason) {
			return Script.fail!("sbom ${Str.join_with(args, " ")} did not refuse with \"${reason}\": ${result.stderr}")
		}
		Ok({})
	}
	call!(["inspect", "Spec", "Lock", "composition.json", "x86_64-linux", "inspected.json"], True)?
	inspected : Try(Sbom.Inventory, _)
	inspected = Json.parse(Path.read_utf8!(Path.utf8("${work}/inspected.json"))?)
	committed : Try(Sbom.Inventory, _)
	committed = Json.parse(Path.read_utf8!(Path.utf8("${work}/inventory.json"))?)
	if inspected.is_err() or inspected != committed {
		return Script.fail!("inspect does not reproduce tests/sbom/fixtures/input/inventory.json")
	}

	base = ["bind", "inventory.json", "subject.json", "context.json", "sample-artifact"]
	call!(base.append("new.spdx.json"), True)?
	call!(base.concat(["new.spdx-2.3.json", "--spdx-2.3"]), True)?
	three = Path.read_utf8!(Path.utf8("${work}/new.spdx.json"))?
	two = Path.read_utf8!(Path.utf8("${work}/new.spdx-2.3.json"))?
	if Spdx3.validate(three).is_err() {
		return Script.fail!("bind wrote SPDX 3.0.1 the model rejects")
	}
	# What the tool binds from the committed inputs is the committed case.
	if three != rendering!("native-linux.spdx.json")? or two != rendering!("native-linux.spdx-2.3.json")? {
		return Script.fail!("bind of tests/sbom/fixtures/input does not write the committed native-linux renderings")
	}
	# Without an output, bind writes SPDX 3.0.1 and CycloneDX beside the artifact.
	call!(base, True)?
	beside = Path.read_utf8!(Path.utf8("${work}/sample-artifact.spdx.json"))?
	bom = Path.read_utf8!(Path.utf8("${work}/sample-artifact.cdx.json"))?
	if beside != three {
		return Script.fail!("the default SPDX sidecar differs from an explicit one")
	}
	if bom != rendering!("native-linux.cdx.json")? {
		return Script.fail!("bind of tests/sbom/fixtures/input does not write the committed native-linux CycloneDX rendering")
	}
	match (Sbom.read(three), Sbom.read(two), Sbom.read_cyclonedx(bom)) {
		(Ok(from_three), Ok(from_two), Ok(from_bom)) =>
			if { ..from_three, version: "" } != { ..from_two, version: "" } or { ..from_three, version: "" } != { ..from_bom, version: "" } {
				return Script.fail!("the SPDX 3.0.1, SPDX 2.3 and CycloneDX sidecars state different package graphs")
			}
		_ => return Script.fail!("a bound sidecar does not read back")
	}

	# `bind` also writes the evidence manifest beside the sidecars: the subject,
	# both sidecars and the inventory by digest and size, files by name alone.
	manifest_name = "sample-artifact${Manifest.suffix}"
	manifest_text = Path.read_utf8!(Path.utf8("${work}/${manifest_name}"))?
	manifest = match Manifest.read(manifest_text) {
		Ok(read) => read
		Err(problem) => return Script.fail!("bind wrote a manifest that does not read back: ${problem}")
	}
	sha = |text| Crypto.SHA256.hash(text.to_utf8()).to_hex()
	listed = manifest.sidecars.map(|entry| (entry.filename, entry.format, entry.sha256, entry.size))
	if manifest.subject != { filename: "sample-artifact", version: "1.0.0", target: "x86_64-linux", sha256: sha("fixture subject\n"), size: 16 } or manifest.inventory_sha256 != sha(Path.read_utf8!(Path.utf8("${work}/inventory.json"))?) or listed != [("sample-artifact.cdx.json", "cyclonedx-1.7", sha(bom), bom.to_utf8().len()), ("sample-artifact.spdx.json", "spdx-3.0.1", sha(beside), beside.to_utf8().len())] {
		return Script.fail!("the manifest does not state the subject, sidecars and inventory bind used")
	}
	if manifest_text.contains(work) or manifest.sidecars.map(|entry| entry.filename).append(manifest.subject.filename).any(|name| name.contains("/") or name.contains("\\")) {
		return Script.fail!("the manifest names a path rather than a file name")
	}
	# `check --manifest` checks the listed sidecars as documents and rehashes
	# the subject, each sidecar and the inventory; staged copies show each
	# refusal: a tampered sidecar, an edited inventory digest, other subject
	# bytes, and a listed sidecar that is absent.
	call!(["check", "--manifest", manifest_name, "--artifacts", ".", "--inventory", "inventory.json"], True)?
	call!(["check", "--manifest", manifest_name, "--artifacts", ".", "--inventory", "inventory.json", "new.spdx-2.3.json"], True)?
	call!(["check", "--manifest", manifest_name], True)?
	variant! = |name, artifact_text, bom_text, body| {
		Path.create_all!(Path.utf8("${work}/${name}"))?
		for (file, text) in [("sample-artifact", artifact_text), ("sample-artifact.spdx.json", three), ("sample-artifact.cdx.json", bom_text), (manifest_name, body)] {
			Path.write_utf8!(Path.utf8("${work}/${name}/${file}"), text)?
		}
		Ok("${name}/${manifest_name}")
	}
	tampered = variant!("tampered", "fixture subject\n", "${bom}\n", manifest_text)?
	refused!(["check", "--manifest", tampered, "--artifacts", "tampered", "--inventory", "inventory.json"], "sample-artifact.cdx.json differs")?
	edited = variant!("edited", "fixture subject\n", bom, manifest_text.replace_each(manifest.inventory_sha256, Str.join_with(List.repeat("b", 64), "")))?
	refused!(["check", "--manifest", edited, "--artifacts", "edited", "--inventory", "inventory.json"], "the inventory differs")?
	call!(["check", "--manifest", edited, "--artifacts", "edited"], True)?
	other = variant!("other", "other bytes\n", bom, manifest_text)?
	refused!(["check", "--manifest", other, "--artifacts", "other"], "subject's bytes differ")?
	missing = variant!("missing", "fixture subject\n", bom, manifest_text)?
	Path.delete!(Path.utf8("${work}/missing/sample-artifact.cdx.json"))?
	refused!(["check", "--manifest", missing, "--artifacts", "missing"], "which is absent")?
	# A named output takes `--manifest` for a manifest of that one sidecar,
	# beside it, which never overwrites the subject or a sidecar.
	call!(base.concat(["explicit.spdx-2.3.json", "--spdx-2.3", "--manifest", "explicit${Manifest.suffix}"]), True)?
	explicit = Manifest.read(Path.read_utf8!(Path.utf8("${work}/explicit${Manifest.suffix}"))?)
	if explicit.map_ok(|read| read.sidecars.map(|entry| (entry.filename, entry.format))) != Ok([("explicit.spdx-2.3.json", "spdx-2.3")]) {
		return Script.fail!("the manifest of a named output does not list exactly that sidecar")
	}
	call!(["check", "--manifest", "explicit${Manifest.suffix}", "--artifacts", ".", "--inventory", "inventory.json"], True)?
	refused!(base.concat(["refused.cdx.json", "--cyclonedx", "--manifest", "sample-artifact"]), "overwrite subject")?
	refused!(base.concat(["refused.cdx.json", "--cyclonedx", "--manifest", "refused.cdx.json"]), "overwrite a sidecar")?
	refused!(base.concat(["refused.cdx.json", "--cyclonedx", "--manifest", "other/refused${Manifest.suffix}"]), "beside")?
	if Path.is_file!(Path.utf8("${work}/refused.cdx.json"))? {
		return Script.fail!("a refused bind wrote a sidecar")
	}
	call!(base, False)?
	call!(base.concat(["new.cdx.json", "--cyclonedx"]), True)?
	# The tool checks what it bound: profile, artifact bytes, inventory, and one
	# graph across formats; a tampered sidecar does not pass.
	call!(["check", "--artifacts", ".", "--inventory", "inventory.json", "sample-artifact.spdx.json", "sample-artifact.cdx.json", "new.spdx-2.3.json"], True)?
	Path.write_utf8!(Path.utf8("${work}/tampered.cdx.json"), bom.replace_each("\"scope\":\"excluded\"", "\"scope\":\"required\""))?
	if !bom.contains("\"scope\":\"excluded\"") {
		return Script.fail!("the bound CycloneDX sidecar has no build-only component to tamper with")
	}
	call!(["check", "tampered.cdx.json"], False)?
	call!(["check", "--artifacts", "nested", "sample-artifact.spdx.json"], False)?
	if Path.read_utf8!(Path.utf8("${work}/new.cdx.json"))? != bom {
		return Script.fail!("the default CycloneDX sidecar differs from an explicit one")
	}

	# An existing sidecar, or any input, is never replaced.
	call!(base.append("new.spdx.json"), False)?
	for name in ["sample-artifact", "inventory.json", "subject.json", "context.json"] {
		call!(base.append(name), False)?
	}
	Path.create_all!(Path.utf8("${work}/nested"))?
	call!(base.append("nested/../sample-artifact"), False)?

	# The subject is a regular file named in subject.json, not an alias of one.
	Path.hard_link!(Path.utf8("${work}/sample-artifact"), Path.utf8("${work}/artifact-hardlink"))?
	call!(["bind", "inventory.json", "subject.json", "context.json", "artifact-hardlink", "hardlink-result.json"], False)?
	_ = Process.succeed!(Process.command("ln", ["-s", "sample-artifact", "artifact-symlink"], work))?
	call!(["bind", "inventory.json", "subject.json", "context.json", "artifact-symlink", "symlink-result.json"], False)?
	Path.create_all!(Path.utf8("${work}/symlink-parent"))?
	_ = Process.succeed!(Process.command("ln", ["-s", "${work}/sample-artifact", "symlink-parent/sample-artifact"], work))?
	call!(["bind", "inventory.json", "subject.json", "context.json", "symlink-parent/sample-artifact", "symlink-parent-result.json"], False)?
	_ = Process.succeed!(Process.command("mkfifo", ["input-fifo"], work))?
	call!(["bind", "inventory.json", "subject.json", "input-fifo", "sample-artifact", "fifo-result.json"], False)?

	# Bounded inputs, and a subject or target that differs from the artifact.
	Path.write_utf8!(Path.utf8("${work}/oversized.json"), Str.join_with(List.repeat(" ", 1024 * 1024 + 1), ""))?
	call!(["inspect", "Spec", "Lock", "oversized.json", "x86_64-linux", "oversized-result.json"], False)?
	subject = Path.read_utf8!(Path.utf8("${work}/subject.json"))?
	written_sha = subject.split_on("\"sha256\":\"").get(1).map_ok(|rest| rest.split_on("\"").first() ?? "") ?? ""
	if !written_sha.is_empty() {
		Path.write_utf8!(Path.utf8("${work}/wrong-subject.json"), subject.replace_each(written_sha, Str.join_with(List.repeat("b", 64), "")))?
		call!(["bind", "inventory.json", "wrong-subject.json", "context.json", "sample-artifact", "wrong-subject-result.json"], False)?
	}
	Path.write_utf8!(Path.utf8("${work}/wrong-target.json"), Path.read_utf8!(Path.utf8("${work}/inventory.json"))?.replace_each("\"target\":\"x86_64-linux\"", "\"target\":\"aarch64-linux\""))?
	call!(["bind", "wrong-target.json", "subject.json", "context.json", "sample-artifact", "wrong-target-result.json"], False)?

	# A source bundle is inventoried from the archive the bundler produced:
	# `members` lists a `.tar.zst` member by member with the system `tar`, and
	# `inspect --members` refuses a composition that omits one.
	Path.create_all!(Path.utf8("${work}/bundle"))?
	for (name, text) in bundle_files {
		Path.write_utf8!(Path.utf8("${work}/bundle/${name}"), text)?
	}
	bundle = "${work}/bundle"
	_ = Process.succeed!(Process.command("tar", ["--zstd", "-cf", "../bundle.tar.zst"].concat(bundle_files.map(|(name, _)| name)), bundle))?
	call!(["members", "bundle.tar.zst", "members.json"], True)?
	listing : Try(Sbom.Listing, _)
	listing = Json.parse(Path.read_utf8!(Path.utf8("${work}/members.json"))?)
	members = match listing {
		Ok(found) => found.members
		Err(_) => return Script.fail!("members wrote no listing")
	}
	if members != bundle_files.map(|(name, text)| { name, size: text.to_utf8().len(), sha256: Crypto.SHA256.hash(text.to_utf8()).to_hex() }) {
		return Script.fail!("members does not list the archive's four members by digest")
	}
	archive = Sbom.archive_members("sources", members) ?? crash "invalid member listing"
	sources = { kind: "library", copyright: "NOASSERTION", attribution: "NOASSERTION", package_url: "", source_refs: [], id: "sources", name: "example-bundle", version: "1.0.0", producer: "Organization: Fixture upstream", identity: "https://example.org/source/example-bundle/1.0.0", download: "https://example.org/source/example-bundle/1.0.0.tar.gz", sha256: "", license: "MIT", license_url: "", modified: "", target: "source", origin: "reviewed" }
	composition : Sbom.Composition
	composition = { profile: Sbom.profile, imported_documents: [], unavailable_sboms: [], components: [sources].concat(archive.components), relationships: [{ from: "Subject", to: "sources", relation: "contains", scope: "", basis: "Source files in the produced bundle" }].concat(archive.relationships), coverage: [{ scope: "members", component: "", aspect: "", status: "complete", reason: "Every archive member is stated by SHA-256", contact: "https://example.org/support" }], inputs: [] }
	Path.write_utf8!(Path.utf8("${work}/composition-members.json"), Json.to_str(composition))?
	call!(["inspect", "Spec", "Lock", "composition-members.json", "source", "members-inventory.json", "--members", "members.json"], True)?
	dropped = { ..composition, components: composition.components.keep_if(|entry| entry.id != "member-message.txt"), relationships: composition.relationships.keep_if(|relation| relation.to != "member-message.txt") }
	Path.write_utf8!(Path.utf8("${work}/composition-dropped.json"), Json.to_str(dropped))?
	call!(["inspect", "Spec", "Lock", "composition-dropped.json", "source", "dropped-inventory.json", "--members", "members.json"], False)?
	# Without the listing, the omission goes unnoticed: the archive is the proof.
	call!(["inspect", "Spec", "Lock", "composition-dropped.json", "source", "unlisted-inventory.json"], True)?
	# A disposition accounts for the member instead, and is exported.
	Path.write_utf8!(Path.utf8("${work}/composition-explained.json"), Json.to_str({ ..dropped, inputs: [{ input: Sbom.member_input(members.last() ?? crash "no members"), component: "", reason: "Greeting text imported by Example.roc; not code" }] }))?
	call!(["inspect", "Spec", "Lock", "composition-explained.json", "source", "explained-inventory.json", "--members", "members.json"], True)?
	if !Path.read_utf8!(Path.utf8("${work}/explained-inventory.json"))?.contains("\"archive-member:message.txt:") {
		return Script.fail!("the member's disposition is not in the inventory's inspected inputs")
	}
	# Only a source archive has members, and the listing is never replaced.
	call!(["inspect", "Spec", "Lock", "composition.json", "x86_64-linux", "native-members-inventory.json", "--members", "members.json"], False)?
	call!(["members", "bundle.tar.zst", "members.json"], False)?
	# Links and names that leave the archive are refused before extraction.
	_ = Process.succeed!(Process.command("ln", ["-s", "main.roc", "link.roc"], bundle))?
	_ = Process.succeed!(Process.command("tar", ["--zstd", "-cf", "../linked.tar.zst", "main.roc", "link.roc"], bundle))?
	call!(["members", "linked.tar.zst", "linked.json"], False)?
	Path.hard_link!(Path.utf8("${bundle}/main.roc"), Path.utf8("${bundle}/hard.roc"))?
	_ = Process.succeed!(Process.command("tar", ["--zstd", "-cf", "../hard.tar.zst", "main.roc", "hard.roc"], bundle))?
	call!(["members", "hard.tar.zst", "hard.json"], False)?
	_ = Process.succeed!(Process.command("tar", ["--zstd", "-P", "-cf", "../escape.tar.zst", "../bundle/main.roc"], bundle))?
	call!(["members", "escape.tar.zst", "escape.json"], False)?
	_ = Process.succeed!(Process.command("tar", ["--zstd", "-P", "-cf", "../absolute.tar.zst", "${bundle}/main.roc"], bundle))?
	call!(["members", "absolute.tar.zst", "absolute.json"], False)?
	call!(["members", "sample-artifact", "not-an-archive.json"], False)?
	Script.pass!("SPDX binding: read-only inputs, exclusive sidecars and manifests, regular-file subjects, bounds, hash, target and archive members")
}

## A source bundle: a module that imports a text file, and a LICENSE, which
## `roc bundle` packs without being told to.
bundle_files = [("main.roc", "module [hello]\n"), ("Example.roc", "import \"message.txt\" as message : Str\n"), ("LICENSE", "UPL-1.0\n"), ("message.txt", "hello\n")]

## The source supplier import as `expected.json` states it: every accepted
## consumer target's inventory byte for byte with target `source` kept on
## each component, the bound renderings equal to the committed case with
## the dependency build-only, and every refusal with its exact message.
source_import! = |tool, fixtures, work| {
	stated : Try(SbomTest.SourceImport, _)
	stated = Json.parse(Path.read_utf8!(Path.utf8("${fixtures}/expected.json"))?)
	expected = match stated {
		Ok(value) => value
		Err(_) => return Script.fail!("${fixtures}/expected.json does not state the source import contract")
	}
	names = [expected.inputs.spec, expected.inputs.lock, expected.inputs.composition, expected.bound.subject, expected.bound.context, expected.bound.artifact].concat(expected.accepted.map(|accepted| accepted.inventory)).concat(expected.refused.map(|refused| refused.composition))
	original = staged!(fixtures, work, names)?
	call! = |args, success| guarded!(tool, args, work, original, success)

	# Source into source and native consumers.
	for accepted in expected.accepted {
		output = "inspected-${accepted.target}.json"
		_ = call!(["inspect", expected.inputs.spec, expected.inputs.lock, expected.inputs.composition, accepted.target, output], True)?
		written = Path.read_utf8!(Path.utf8("${work}/${output}"))?
		if written != Path.read_utf8!(Path.utf8("${work}/${accepted.inventory}"))? {
			return Script.fail!("inspect for ${accepted.target} does not reproduce ${accepted.inventory}")
		}
		inventory : Try(Sbom.Inventory, _)
		inventory = Json.parse(written)
		match inventory {
			Ok(value) =>
				if value.target != accepted.target or !value.components.all(|entry| entry.target == "source") {
					return Script.fail!("the ${accepted.target} inventory does not keep target source on every component")
				}
			Err(_) => return Script.fail!("inspect for ${accepted.target} wrote no inventory")
		}
	}

	# The bound renderings are the committed case, and the build-only
	# dependency ships nothing.
	bound = expected.bound
	_ = call!(["bind", bound.inventory, bound.subject, bound.context, bound.artifact], True)?
	_ = call!(["bind", bound.inventory, bound.subject, bound.context, bound.artifact, "bound.spdx-2.3.json", "--spdx-2.3"], True)?
	for (written, name) in [("${bound.artifact}.spdx.json", "${bound.renderings}.spdx.json"), ("${bound.artifact}.cdx.json", "${bound.renderings}.cdx.json"), ("bound.spdx-2.3.json", "${bound.renderings}.spdx-2.3.json")] {
		if Path.read_utf8!(Path.utf8("${work}/${written}"))? != rendering!(name)? {
			return Script.fail!("bind of ${bound.inventory} does not write the committed ${name}")
		}
	}
	_ = call!(["check", "--artifacts", ".", "--inventory", bound.inventory, "${bound.artifact}.spdx.json", "${bound.artifact}.cdx.json", "bound.spdx-2.3.json"], True)?
	bom = Path.read_utf8!(Path.utf8("${work}/${bound.artifact}.cdx.json"))?
	document = match Sbom.read_cyclonedx(bom) {
		Ok(value) => value
		Err(_) => return Script.fail!("the bound CycloneDX sidecar does not read back")
	}
	build_only = document.relationships.any(|relation| relation.from == "Subject" and relation.to == "dep" and relation.relation == "dependsOn" and relation.scope == "build")
		and !document.relationships.any(|relation| relation.relation == "contains" and relation.to == "dep")
	if !build_only or !bom.contains("\"scope\":\"excluded\"") or bom.contains("\"scope\":\"required\"") {
		return Script.fail!("the bound CycloneDX sidecar does not keep the source dependency build-only")
	}

	# Each refusal, with its exact message and nothing written.
	for refused in expected.refused {
		output = "refused-${refused.composition}"
		result = call!(["inspect", expected.inputs.spec, expected.inputs.lock, refused.composition, refused.target, output], False)?
		message = Str.concat("SBOM: Invalid(\"", Str.concat(refused.refusal, "\")"))
		if !result.stderr.contains(message) {
			return Script.fail!("inspect of ${refused.composition} was expected to refuse with ${message}, got: ${result.stderr}")
		}
		if Path.exists!(Path.utf8("${work}/${output}"))? {
			return Script.fail!("inspect of ${refused.composition} wrote ${output} although it refused")
		}
	}
	Script.pass!("source supplier import: ${expected.accepted.len().to_str()} consumer targets accepted with source kept, the bound renderings committed, ${expected.refused.len().to_str()} refusals exact")
}

## Exercise every new reviewed field through the actual standalone executable.
reviewed_source! : Str, Str => Try({}, _)
reviewed_source! = |tool, work| {
	case = SbomTest.cases.find_first(|entry| entry.name == "reviewed-source") ?? crash "reviewed source case"
	composition : Sbom.Composition
	composition = { profile: Sbom.profile, imported_documents: [], unavailable_sboms: [], components: case.inventory.components, relationships: case.inventory.relationships, coverage: case.inventory.coverage, inputs: case.inventory.inputs }
	payload = SbomTest.input_files.find_first(|entry| entry.name == "sample-artifact") ?? crash "fixture bytes"
	for (name, text) in [("Spec", SbomTest.spec.to_str()), ("Lock", SbomTest.lock.to_str()), ("composition.json", Json.to_str(composition)), ("subject.json", Json.to_str(case.subject)), ("context.json", Json.to_str(case.context)), (case.subject.filename, payload.text)] {
		Path.write_utf8!(Path.utf8("${work}/${name}"), text)?
	}
	call! = |args| guarded!(tool, args, work, [], True).map_ok(|_| {})
	call!(["inspect", "Spec", "Lock", "composition.json", "source", "inventory.json"])?
	inspected : Try(Sbom.Inventory, _)
	inspected = Json.parse(Path.read_utf8!(Path.utf8("${work}/inventory.json"))?)
	if inspected != Ok(case.inventory) {
		return Script.fail!("inspect changed reviewed source metadata")
	}
	call!(["bind", "inventory.json", "subject.json", "context.json", case.subject.filename])?
	call!(["bind", "inventory.json", "subject.json", "context.json", case.subject.filename, "reviewed.spdx-2.3.json", "--spdx-2.3"])?
	for (path, name) in [("${case.subject.filename}.spdx.json", "reviewed-source.spdx.json"), ("${case.subject.filename}.cdx.json", "reviewed-source.cdx.json"), ("reviewed.spdx-2.3.json", "reviewed-source.spdx-2.3.json")] {
		if Path.read_utf8!(Path.utf8("${work}/${path}"))? != rendering!(name)? {
			return Script.fail!("bind changed reviewed source fields in ${name}")
		}
	}
	call!(["check", "--manifest", "${case.subject.filename}.sbom-manifest.json", "--artifacts", ".", "--inventory", "inventory.json", "reviewed.spdx-2.3.json"])?
	Script.pass!("reviewed source kinds, notices, package/source references and addressed coverage survive inspect, bind and check")
}
