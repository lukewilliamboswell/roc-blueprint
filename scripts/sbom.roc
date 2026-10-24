#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	core: "../blueprint-core/main.roc",
}

import cli.OsStr
import src/SbomFiles
import cli.Stderr
import cli.Stdout
import core.Spec
import core.Lock
import core.Manifest
import core.Sbom
import core.Sidecar

## Offline report from already evaluated Spec/Lock; no provider/Store effects.
## members ARCHIVE OUTPUT
## `members` lists a produced `.tar.zst` archive, such as a `roc bundle`,
## with the system `tar`: each regular member's name, size and SHA-256, so
## the archive, not the bundler's argument list, says what a source bundle
## holds. Links, devices and unsafe names are refused.
## inspect SPEC LOCK COMPOSITION TARGET OUTPUT [--members LISTING]
## With `--members`, a `source` inventory must account for every member of
## the listing `members` wrote: a component that states its SHA-256, or an
## input disposition `archive-member:NAME:SHA256`.
## bind INVENTORY SUBJECT CONTEXT ARTIFACT [OUTPUT [--spdx-2.3 | --cyclonedx] [--manifest MANIFEST]]
## Without OUTPUT, `bind` writes ARTIFACT.spdx.json (SPDX 3.0.1 JSON-LD),
## ARTIFACT.cdx.json (CycloneDX 1.7) and ARTIFACT.sbom-manifest.json, the
## evidence manifest listing both, beside the artifact. With OUTPUT it writes
## SPDX 3.0.1 there, or SPDX 2.3 or CycloneDX 1.7 with a flag, and with
## `--manifest` the manifest of that one sidecar at MANIFEST, beside it.
## check [--manifest MANIFEST] [--artifacts DIR] [--inventory INVENTORY] DOCUMENT...
## `check` holds sidecars to the profile: valid in their format, one described
## subject (with `--artifacts`, the file of that name in DIR, byte for byte),
## evidence that is INVENTORY's, and one package graph across renderings.
## With `--manifest`, the sidecars MANIFEST lists are checked too, and the
## manifest is held to the files: the subject in DIR (or beside the manifest),
## each listed sidecar beside the manifest, and INVENTORY, rehashed.
## JSON input files are bounded to 1MiB. Output sidecars are separate from assets.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = run!(args.map(OsStr.display))
	match result {
		Ok({}) => Ok({})
		Err(error) => {
			_ = Stderr.line!("SBOM: ${Str.inspect(error)}")
			Err(Exit(1))
		}
	}
}

usage = "usage: scripts/sbom.roc members ARCHIVE OUTPUT | inspect SPEC LOCK COMPOSITION TARGET OUTPUT [--members LISTING] | bind INVENTORY SUBJECT CONTEXT ARTIFACT [OUTPUT [--spdx-2.3 | --cyclonedx] [--manifest MANIFEST]] | check [--manifest MANIFEST] [--artifacts DIR] [--inventory INVENTORY] DOCUMENT..."

read! = |name| {
	text = SbomFiles.read!(name)?
	if !Sbom.json_within_bounds(text) {
		return Err(InputTooLarge)
	}
	Ok(text)
}

run! = |args| match args {
	["members", archive, output] => {
		if archive == output {
			return Err(Invalid("listing must not overwrite archive"))
		}
		members = SbomFiles.archive_members!(archive)?
		listing : Sbom.Listing
		listing = { archive: archive.replace_each("\\", "/").split_on("/").last() ?? archive, sha256: SbomFiles.digest!(archive)?, members }
		SbomFiles.write_new!(output, "${Json.to_str(listing)}\n")?
		Stdout.line!(output)
	}
	["inspect", spec_path, lock_path, composition_path, target, output] => inspect!(spec_path, lock_path, composition_path, target, output, "")
	["inspect", spec_path, lock_path, composition_path, target, output, "--members", listing_path] => inspect!(spec_path, lock_path, composition_path, target, output, listing_path)
	["bind", inventory_path, subject_path, context_path, artifact] => bind!(inventory_path, subject_path, context_path, artifact, [("${artifact}.spdx.json", "spdx-3.0.1"), ("${artifact}.cdx.json", "cyclonedx-1.7")], "${artifact}${Manifest.suffix}")
	["bind", inventory_path, subject_path, context_path, artifact, output, .. as flags] => {
		options = bind_options(flags, { format: "spdx-3.0.1", manifest: "" })?
		bind!(inventory_path, subject_path, context_path, artifact, [(output, options.format)], options.manifest)
	}
	["check", .. as rest] => check!(rest, { artifacts: "", inventory: "", manifest: "" })
	_ => Err(Invalid(usage))
}

## Inspect the composition against the Spec and Lock, and against the
## archive's member listing when one is named.
inspect! = |spec_path, lock_path, composition_path, target, output, listing_path| {
	spec = Spec.parse(read!(spec_path)?).map_err(|error| Invalid(Str.inspect(error)))?
	lock = Lock.parse(read!(lock_path)?).map_err(|error| Invalid(Str.inspect(error)))?
	composition : Sbom.Composition
	composition = Json.parse(Sbom.normalize_input(read!(composition_path)?).map_err(|problem| Invalid(problem))?).map_err(|error| Invalid(Str.inspect(error)))?
	inventory = if listing_path.is_empty() {
		Sbom.inspect(spec, lock, target, composition).map_err(|error| Invalid(error))?
	} else {
		listing : Sbom.Listing
		listing = Json.parse(read!(listing_path)?).map_err(|error| Invalid(Str.inspect(error)))?
		Sbom.inspect_archive(spec, lock, target, composition, listing.members).map_err(|error| Invalid(error))?
	}
	SbomFiles.write_new!(output, "${Json.to_str(inventory)}\n")?
	Stdout.line!(output)
}

bind_options = |flags, options|
	match flags {
		["--spdx-2.3", .. as rest] => bind_options(rest, { ..options, format: "spdx-2.3" })
		["--cyclonedx", .. as rest] => bind_options(rest, { ..options, format: "cyclonedx-1.7" })
		["--manifest", manifest, .. as rest] => bind_options(rest, { ..options, manifest })
		[] => Ok(options)
		_ => Err(Invalid(usage))
	}

check! = |args, options|
	match args {
		["--artifacts", artifacts, .. as rest] => check!(rest, { ..options, artifacts })
		["--inventory", inventory, .. as rest] => check!(rest, { ..options, inventory })
		["--manifest", manifest, .. as rest] => check!(rest, { ..options, manifest })
		[] if options.manifest.is_empty() => Err(Invalid("check needs at least one SBOM document"))
		documents => {
			# A manifest is held to the files before its sidecars are read as
			# documents, so a tampered sidecar is reported as such.
			manifest = if options.manifest.is_empty() Err(NoManifest) else Ok(verify_manifest!(options)?)
			listed = match manifest {
				Ok(verified) => verified.sidecars.map(|entry| Manifest.beside(options.manifest, entry.filename))
				Err(NoManifest) => []
			}
			var $checked = []
			for path in listed.concat(documents.drop_if(|path| listed.contains(path))) {
				checked = Sidecar.check(read!(path)?).map_err(|problem| Invalid("${path}: ${problem}"))?
				if !options.artifacts.is_empty() and SbomFiles.digest!("${options.artifacts}/${checked.subject.name}")? != checked.subject.sha256 {
					return Err(Invalid("${path}: subject bytes differ from ${options.artifacts}/${checked.subject.name}"))
				}
				if !options.inventory.is_empty() {
					inventory : Sbom.Inventory
					inventory = Json.parse(Sbom.normalize_input(read!(options.inventory)?).map_err(|problem| Invalid(problem))?).map_err(|error| Invalid(Str.inspect(error)))?
					Sidecar.against_inventory(checked, inventory).map_err(|problem| Invalid("${path}: ${problem}"))?
				}
				match manifest {
					Ok(verified) if listed.contains(path) or checked.subject.name == verified.subject.filename =>
						Manifest.describes(verified, if (listed.contains(path)) Manifest.file_name_of(path) else "", checked).map_err(|problem| Invalid("${path}: ${problem}"))?
					_ => {}
				}
				for earlier in $checked {
					if earlier.document.namespace == checked.document.namespace and earlier.document.version != checked.document.version and !Sidecar.same_graph(earlier, checked) {
						return Err(Invalid("${path}: the ${earlier.document.version} and ${checked.document.version} renderings of ${checked.subject.name} differ"))
					}
				}
				$checked = $checked.append(checked)
				Stdout.line!("${path}: ${checked.document.version} sidecar of ${checked.subject.name} checks")?
			}
			match manifest {
				Ok(verified) => Stdout.line!("${options.manifest}: manifest of ${verified.subject.filename} checks")
				Err(NoManifest) => Ok({})
			}
		}
	}

## The manifest, once the subject, each listed sidecar and the inventory are
## rehashed and are what it states. The subject is read from `--artifacts`,
## or beside the manifest; the sidecars beside the manifest; the inventory
## from `--inventory`, when given.
verify_manifest! = |options| {
	text = read!(options.manifest)?
	manifest = Manifest.read(text).map_err(|problem| Invalid("${options.manifest}: ${problem}"))?
	subject_path = if (options.artifacts.is_empty()) Manifest.beside(options.manifest, manifest.subject.filename) else "${options.artifacts}/${manifest.subject.filename}"
	subject = SbomFiles.measure!(subject_path).map_err(|_| Invalid("${options.manifest}: no regular file ${subject_path} to hold its subject to"))?
	var $sidecars = []
	for entry in manifest.sidecars {
		match SbomFiles.measure!(Manifest.beside(options.manifest, entry.filename)) {
			Ok(measured) => {
				$sidecars = $sidecars.append({ filename: entry.filename, sha256: measured.sha256, size: measured.size })
			}
			Err(_) => {}
		}
	}
	inventory = if options.inventory.is_empty() Unmeasured else Measured(SbomFiles.digest!(options.inventory)?)
	Manifest.check(text, { subject, inventory, sidecars: $sidecars }).map_err(|problem| Invalid("${options.manifest}: ${problem}"))
}

## Render every requested document, and the manifest that lists them, before
## writing any, so a refusal leaves no partial set of sidecars.
bind! = |inventory_path, subject_path, context_path, artifact, outputs, manifest_path| {
	inventory_text = read!(inventory_path)?
	inventory : Sbom.Inventory
	inventory = Json.parse(Sbom.normalize_input(inventory_text).map_err(|problem| Invalid(problem))?).map_err(|error| Invalid(Str.inspect(error)))?
	subject : Sbom.Subject
	subject = Json.parse(Sbom.normalize_input(read!(subject_path)?).map_err(|problem| Invalid(problem))?).map_err(|error| Invalid(Str.inspect(error)))?
	context : Sbom.Context
	context = Json.parse(read!(context_path)?).map_err(|error| Invalid(Str.inspect(error)))?
	if Manifest.file_name_of(artifact) != subject.filename {
		return Err(Invalid("subject filename differs from final artifact"))
	}
	if outputs.any(|(output, _)| output == artifact) or manifest_path == artifact {
		return Err(Invalid("sidecar must not overwrite subject"))
	}
	if outputs.any(|(output, _)| output == manifest_path) {
		return Err(Invalid("manifest must not overwrite a sidecar"))
	}
	if !manifest_path.is_empty() and outputs.any(|(output, _)| Manifest.directory_of(output) != Manifest.directory_of(manifest_path)) {
		return Err(Invalid("the manifest must sit beside the sidecars it lists"))
	}
	measured = SbomFiles.measure!(artifact)?
	if !subject.sha256.is_empty() and subject.sha256 != measured.sha256 {
		return Err(Invalid("final subject SHA-256 mismatch"))
	}
	bound = { ..subject, sha256: measured.sha256 }
	var $documents = []
	for (output, format) in outputs {
		render = match format {
			"spdx-2.3" => Sbom.render_spdx2
			"cyclonedx-1.7" => Sbom.render_cyclonedx
			_ => Sbom.render
		}
		text = render(inventory, bound, context).map_err(|error| Invalid(error))?
		$documents = $documents.append({ output, format, text })
	}
	manifest_text = if manifest_path.is_empty() {
		""
	} else {
		sidecars = $documents.map(|document| { filename: Manifest.file_name_of(document.output), format: document.format, sha256: Crypto.SHA256.hash(document.text.to_utf8()).to_hex(), size: document.text.to_utf8().len() })
		Manifest.render({
			profile: Sbom.profile,
			subject: { filename: bound.filename, version: bound.version, target: bound.target, sha256: bound.sha256, size: measured.size },
			inventory_sha256: Crypto.SHA256.hash(inventory_text.to_utf8()).to_hex(),
			context: { namespace: context.namespace, revision: context.revision, created: context.created, generator: context.generator },
			sidecars,
		}).map_err(|error| Invalid(error))?
	}
	for document in $documents {
		SbomFiles.write_new!(document.output, document.text)?
		Stdout.line!(document.output)?
	}
	if !manifest_path.is_empty() {
		SbomFiles.write_new!(manifest_path, manifest_text)?
		Stdout.line!(manifest_path)?
	}
	Ok({})
}
