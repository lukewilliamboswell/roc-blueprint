import JsonData
import Project
import Sbom
import Sidecar
import CycloneDx
import Spdx3
import ArtifactName

## The evidence manifest `bind` writes beside the sidecars of one subject:
## which files it wrote, from which inventory, with the digest and size of
## each, so a publisher that rehashes every asset before signing can tie each
## sidecar to its subject and to the inventory it was bound from without
## reconstructing that mapping by hand. It is evidence about files, not a
## fourth rendering of the SBOM: it names files by name only, never by path,
## and holds no credential. `render` writes one deterministically, `read`
## takes it back, and `check` holds it to what a checker measured.
Manifest := [].{

	## One sidecar the manifest lists, by its name beside the manifest.
	Entry : { filename : Str, format : Str, sha256 : Str, size : U64 }

	Subject : { filename : Str, version : Str, target : Str, sha256 : Str, size : U64 }

	Context : { namespace : Str, revision : Str, created : Str, generator : Str }

	Manifest : { profile : Str, subject : Manifest.Subject, inventory_sha256 : Str, context : Manifest.Context, sidecars : List(Manifest.Entry) }

	## What a checker measured: the subject's bytes, the inventory file when
	## one was at hand, and each listed sidecar it found. A listed sidecar
	## missing from `sidecars` is absent.
	Observed : { subject : { sha256 : Str, size : U64 }, inventory : [Measured(Str), Unmeasured], sidecars : List({ filename : Str, sha256 : Str, size : U64 }) }

	## The manifest of `subject` sits beside its sidecars as `<subject>.sbom-manifest.json`.
	suffix = ".sbom-manifest.json"

	## One authoritative set for generation, conventional names and checking.
	renderings : List({ format : Str, suffix : Str })
	renderings = [
		{ format: "spdx-3.0.1", suffix: ".spdx.json" },
		{ format: "spdx-2.3", suffix: ".spdx-2.3.json" },
		{ format: "cyclonedx-1.7", suffix: ".cdx.json" },
	]

	formats = renderings.map(|rendering| rendering.format)

	## All standard sidecars for an artifact, in deterministic generation order.
	outputs : Str -> List((Str, Str))
	outputs = |artifact| renderings.map(|rendering| ("${artifact}${rendering.suffix}", rendering.format))

	## Directory discovery uses actual entry spelling, including ASCII case
	## variants of supported conventional names; it does not probe aliases twice.
	is_standard_sidecar : Str, Str -> Bool
	is_standard_sidecar = |artifact, candidate| outputs(artifact).any(|(name, _)| ArtifactName.key(name) == ArtifactName.key(candidate))

	## The manifest's name for the format a sidecar reads back as
	## (`Sbom.Document.version`).
	format_of : Str -> Try(Str, Str)
	format_of = |version|
		match version {
			"SPDX-3.0.1" => Ok("spdx-3.0.1")
			"SPDX-2.3" => Ok("spdx-2.3")
			"CycloneDX-1.7" => Ok("cyclonedx-1.7")
			other => Err("no manifest format for a ${other} document")
		}

	## The path of `name`, a file beside the manifest or subject at `path`:
	## what a manifest's file names resolve to.
	beside : Str, Str -> Str
	beside = |path, name| {
		directory = directory_of(path)
		if (directory.is_empty()) name else if (directory == "/") "/${name}" else "${directory}/${name}"
	}

	## The last component of a path, on either separator: the name a manifest
	## records for it.
	file_name_of : Str -> Str
	file_name_of = |path| path.replace_each("\\", "/").split_on("/").last() ?? ""

	## The directory a path names, "" for a bare file name.
	directory_of : Str -> Str
	directory_of = |path| {
		parts = path.replace_each("\\", "/").split_on("/")
		leading = parts.take_first(parts.len() - 1)
		if (leading.is_empty()) "" else if (leading == [""]) "/" else Str.join_with(leading, "/")
	}

	## The manifest as JSON text, one line with a trailing newline, keys in a
	## fixed order and sidecars by name, so the same evidence is the same
	## bytes. A manifest that `read` would refuse is not rendered.
	render : Manifest.Manifest -> Try(Str, Str)
	render = |manifest| {
		valid(manifest)?
		subject = manifest.subject
		context = manifest.context
		entry = |listed| JsonData.Object([member("filename", listed.filename), member("format", listed.format), member("sha256", listed.sha256), { name: "size", value: JsonData.Number(listed.size.to_str()) }])
		tree = JsonData.Object([
			member("profile", manifest.profile),
			{ name: "subject", value: JsonData.Object([member("filename", subject.filename), member("version", subject.version), member("target", subject.target), member("sha256", subject.sha256), { name: "size", value: JsonData.Number(subject.size.to_str()) }]) },
			member("inventory_sha256", manifest.inventory_sha256),
			{ name: "context", value: JsonData.Object([member("namespace", context.namespace), member("revision", context.revision), member("created", context.created), member("generator", context.generator)]) },
			{ name: "sidecars", value: JsonData.Array(manifest.sidecars.sort_with(|a, b| Project.bytewise(a.filename, b.filename)).map(entry)) },
		])
		text = "${JsonData.encode(tree).map_err(JsonData.message)?}\n"
		if leaks(text) {
			return Err("the manifest holds a developer path or credential")
		}
		Ok(text)
	}

	## A manifest from its text, refused unless it is one `render` writes:
	## this profile, files named by name only, lowercase SHA-256 digests, a
	## revision-qualified HTTPS or UUID namespace, and at least one sidecar of a known
	## format, each listed once.
	read : Str -> Try(Manifest.Manifest, Str)
	read = |text| {
		if text.to_utf8().len() > 65536 {
			return Err("the manifest exceeds 64 KiB")
		}
		if leaks(text) {
			return Err("the manifest holds a developer path or credential")
		}
		# Refuse duplicate keys before builtin typed decoding can discard them.
		_ = JsonData.decode_bounded(text, JsonData.defaults, 65536).map_err(JsonData.message)?
		decoded : Try(Manifest.Manifest, _)
		decoded = Json.parse(text)
		manifest = decoded.map_err(|_| "the manifest is not an evidence manifest")?
		valid(manifest)?
		Ok(manifest)
	}

	## Check the exact observed sidecar set. A filesystem caller must include
	## adjacent conventional sidecars in its observations, not just listed files.
	## Unlisted observations and ambiguous duplicate observations are refused.
	check : Str, Manifest.Observed -> Try(Manifest.Manifest, Str)
	check = |text, observed| {
		manifest = check_listed(text, observed)?
		for found in observed.sidecars {
			if !manifest.sidecars.any(|entry| entry.filename == found.filename) {
				return Err("${found.filename} is present but not listed in the manifest")
			}
		}
		Ok(manifest)
	}

	## Explicitly scoped legacy verification: verify the subject, inventory
	## when observed, and only declared sidecars. This proves no complete set.
	check_listed : Str, Manifest.Observed -> Try(Manifest.Manifest, Str)
	check_listed = |text, observed| {
		manifest = read(text)?
		names = observed.sidecars.map(|entry| ArtifactName.key(entry.filename))
		if names.len() != names.fold([], |all, name| if (all.contains(name)) all else all.append(name)).len() {
			return Err("a sidecar was observed twice")
		}
		if observed.subject.sha256 != manifest.subject.sha256 {
			return Err("the subject's bytes differ from what the manifest states")
		}
		if observed.subject.size != manifest.subject.size {
			return Err("the subject's size differs from what the manifest states")
		}
		for listed in manifest.sidecars {
			found = observed.sidecars.find_first(|entry| entry.filename == listed.filename).map_err(|_| "the manifest lists ${listed.filename}, which is absent")?
			if found.sha256 != listed.sha256 {
				return Err("${listed.filename} differs from what the manifest states")
			}
			if found.size != listed.size {
				return Err("the size of ${listed.filename} differs from what the manifest states")
			}
		}
		match observed.inventory {
			Measured(digest) if digest != manifest.inventory_sha256 => Err("the inventory differs from the one the manifest states")
			_ => Ok(manifest)
		}
	}

	## A checked sidecar describes the manifest's subject: the same file name,
	## version and final digest. Named as `filename` in the manifest, it is
	## also in the format listed for it; "" names no listed sidecar.
	describes : Manifest.Manifest, Str, Sidecar.Checked -> Try({}, Str)
	describes = |manifest, filename, checked| {
		subject = checked.subject
		if subject.name != manifest.subject.filename or subject.version != manifest.subject.version or subject.sha256 != manifest.subject.sha256 {
			return Err("the sidecar describes ${subject.name} ${subject.version}, not the manifest's ${manifest.subject.filename} ${manifest.subject.version}")
		}
		if checked.evidence.target != manifest.subject.target {
			return Err("the sidecar target differs from the manifest's subject target")
		}
		if checked.evidence.revision != manifest.context.revision {
			return Err("the sidecar revision differs from the manifest's context revision")
		}
		if checked.document.namespace != manifest.context.namespace {
			return Err("the sidecar namespace differs from the manifest's context namespace")
		}
		if checked.context.created != manifest.context.created {
			return Err("the sidecar creation time differs from the manifest's context time")
		}
		if checked.context.generator != manifest.context.generator {
			return Err("the sidecar generator differs from the manifest's context generator")
		}
		match manifest.sidecars.find_first(|entry| entry.filename == filename) {
			Ok(listed) => if (format_of(checked.document.version) == Ok(listed.format)) Ok({}) else Err("${filename} is a ${checked.document.version} document, not the ${listed.format} sidecar the manifest lists")
			Err(_) => if (filename.is_empty()) Ok({}) else Err("${filename} is not listed in the manifest")
		}
	}
}

member : Str, Str -> { name : Str, value : JsonData }
member = |name, value| { name, value: JsonData.String(value) }

valid : Manifest.Manifest -> Try({}, Str)
valid = |manifest| {
	subject = manifest.subject
	if ![Sbom.profile, "blueprint-spdx-3.0-v1"].contains(manifest.profile) {
		return Err("the manifest names profile ${manifest.profile}, not ${Sbom.profile}")
	}
	if !ArtifactName.valid(subject.filename) {
		return Err("the manifest must name its subject by file name alone")
	}
	if subject.version.is_empty() or subject.target.is_empty() or !lowercase_sha256(subject.sha256) {
		return Err("the subject needs a version, a target and a lowercase SHA-256")
	}
	if !lowercase_sha256(manifest.inventory_sha256) {
		return Err("the inventory digest must be a lowercase SHA-256")
	}
	if manifest.context.revision.is_empty() or !(CycloneDx.serial_number(manifest.context.namespace) or (manifest.context.namespace.starts_with("https://") and manifest.context.namespace.ends_with("revision-${manifest.context.revision}"))) {
		return Err("namespace must be a UUID URN or HTTPS namespace ending with its revision")
	}
	if !Spdx3.timestamp(manifest.context.created) or !manifest.context.generator.starts_with("Tool: ") or manifest.context.generator == "Tool: " {
		return Err("the context needs a UTC creation time and a Tool: generator")
	}
	if manifest.sidecars.is_empty() {
		return Err("the manifest lists no sidecar")
	}
	names = manifest.sidecars.map(|entry| ArtifactName.key(entry.filename))
	if names.fold([], |all, name| if (all.contains(name)) all else all.append(name)).len() != names.len() {
		return Err("the manifest lists a sidecar twice")
	}
	listed_formats = manifest.sidecars.map(|entry| entry.format)
	if listed_formats.fold([], |all, format| if (all.contains(format)) all else all.append(format)).len() != listed_formats.len() {
		return Err("the manifest lists a format twice")
	}
	for entry in manifest.sidecars {
		if !ArtifactName.valid(entry.filename) or ArtifactName.key(entry.filename) == ArtifactName.key(subject.filename) {
			return Err("the manifest must name each sidecar by file name alone, apart from its subject")
		}
		if !Manifest.formats.contains(entry.format) {
			return Err("${entry.filename} has format ${entry.format}, not one of ${Str.join_with(Manifest.formats, ", ")}")
		}
		if !lowercase_sha256(entry.sha256) {
			return Err("${entry.filename} needs a lowercase SHA-256")
		}
	}
	Ok({})
}

lowercase_sha256 : Str -> Bool
lowercase_sha256 = |value| value.to_utf8().len() == 64 and value.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))

leaks : Str -> Bool
leaks = |text| ["/Users/", "/home/", "/private/", "/tmp/", "/var/", "/nix/store/", "C:\\\\Users\\\\", "token=", "password=", "ghp_", "github_pat_", "BEGIN PRIVATE KEY"].any(|marker| text.contains(marker))

# A caller must supply the actual observed set. The explicit legacy method
# remains available, but strict checking cannot silently omit another format.
manifest_example : Manifest.Manifest
manifest_example = {
	profile: Sbom.profile,
	subject: { filename: "app.tar.zst", version: "1.0.0", target: "source", sha256: "a".repeat(64), size: 100 },
	inventory_sha256: "b".repeat(64),
	context: { namespace: "https://example.org/sbom/revision-1", revision: "1", created: "2026-11-04T00:00:00Z", generator: "Tool: blueprint-sbom" },
	sidecars: [{ filename: "app.tar.zst.spdx.json", format: "spdx-3.0.1", sha256: "c".repeat(64), size: 10 }],
}

manifest_example_text = Manifest.render(manifest_example) ?? crash "example manifest"

manifest_example_observed : Manifest.Observed
manifest_example_observed = {
	subject: { sha256: "a".repeat(64), size: 100 },
	inventory: Measured("b".repeat(64)),
	sidecars: [{ filename: "app.tar.zst.spdx.json", sha256: "c".repeat(64), size: 10 }],
}

expect Manifest.outputs("app.tar.zst") == [("app.tar.zst.spdx.json", "spdx-3.0.1"), ("app.tar.zst.spdx-2.3.json", "spdx-2.3"), ("app.tar.zst.cdx.json", "cyclonedx-1.7")]
expect {
	extra = { filename: "app.tar.zst.spdx-2.3.json", sha256: "d".repeat(64), size: 20 }
	observed = { ..manifest_example_observed, sidecars: manifest_example_observed.sidecars.append(extra) }
	Manifest.check(manifest_example_text, observed) == Err("app.tar.zst.spdx-2.3.json is present but not listed in the manifest")
		and Manifest.check_listed(manifest_example_text, observed) == Ok(manifest_example)
}
expect Manifest.check(manifest_example_text, { ..manifest_example_observed, sidecars: manifest_example_observed.sidecars.concat(manifest_example_observed.sidecars) }) == Err("a sidecar was observed twice")
expect Manifest.render({ ..manifest_example, sidecars: manifest_example.sidecars.append({ filename: "another.spdx.json", format: "spdx-3.0.1", sha256: "d".repeat(64), size: 20 }) }) == Err("the manifest lists a format twice")
expect Manifest.read(manifest_example_text.replace_each("\"inventory_sha256\":", "\"inventory_sha256\":\"${"d".repeat(64)}\",\"inventory_sha256\":")).is_err()

expect Manifest.render({ ..manifest_example, context: { ..manifest_example.context, namespace: "urn:uuid:7bd0b7ae-19a2-8fed-9240-d791b640377b" } }).is_ok()
expect Manifest.render({ ..manifest_example, context: { ..manifest_example.context, namespace: "urn:uuid:invalid" } }).is_err()

expect ["C:sidecar.json", "artifact:stream", "NUL", "cOn.txt", "COM¹.log", "LPT9.tar.gz", "report?x.json", "report*.json", "report|x.json", "report<.json", "report>.json", "report\".json", "report.", "report ", "bad\nname", "bad\u(0000)name", "bad\u(007f)name"].all(|name| Manifest.render({ ..manifest_example, sidecars: [{ ..manifest_example.sidecars.first() ?? crash "entry", filename: name }] }).is_err())
expect Manifest.render({ ..manifest_example, subject: { ..manifest_example.subject, filename: "C:artifact" } }).is_err()
expect Manifest.render({ ..manifest_example, sidecars: [{ ..manifest_example.sidecars.first() ?? crash "entry", filename: "révision 中文 report.spdx.json" }] }).is_ok()
expect Manifest.render({ ..manifest_example, sidecars: [{ ..manifest_example.sidecars.first() ?? crash "entry", filename: "APP.TAR.ZST" }] }).is_err()
expect Manifest.render({ ..manifest_example, sidecars: manifest_example.sidecars.append({ filename: "APP.TAR.ZST.SPDX.JSON", format: "spdx-2.3", sha256: "d".repeat(64), size: 20 }) }) == Err("the manifest lists a sidecar twice")
expect Manifest.check(manifest_example_text, { ..manifest_example_observed, sidecars: manifest_example_observed.sidecars.append({ filename: "APP.TAR.ZST.SPDX.JSON", sha256: "d".repeat(64), size: 20 }) }) == Err("a sidecar was observed twice")

expect Manifest.is_standard_sidecar("app.tar.zst", "APP.TAR.ZST.SPDX-2.3.JSON") and !Manifest.is_standard_sidecar("app.tar.zst", "unrelated.spdx-2.3.json")
expect Manifest.render({ ..manifest_example, context: { ..manifest_example.context, created: "not a timestamp" } }).is_err()
expect ["", "Tool: ", "different-generator"].all(|generator| Manifest.render({ ..manifest_example, context: { ..manifest_example.context, generator } }).is_err())
