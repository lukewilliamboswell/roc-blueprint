#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	core: "../blueprint-core/main.roc",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.OsStr
import src/SbomFiles
import cli.Stderr
import cli.Stdout
import core.Spec
import core.Lock
import core.Sbom
import core.Sidecar

## Offline report from already evaluated Spec/Lock; no provider/Store effects.
## inspect SPEC LOCK COMPOSITION TARGET OUTPUT
## bind INVENTORY SUBJECT CONTEXT ARTIFACT [OUTPUT [--spdx-2.3 | --cyclonedx]]
## Without OUTPUT, `bind` writes ARTIFACT.spdx.json (SPDX 3.0.1 JSON-LD) and
## ARTIFACT.cdx.json (CycloneDX 1.7) beside the artifact. With OUTPUT it
## writes SPDX 3.0.1 there, or SPDX 2.3 or CycloneDX 1.7 with a flag.
## check [--artifacts DIR] [--inventory INVENTORY] DOCUMENT...
## `check` holds sidecars to the profile: valid in their format, one described
## subject (with `--artifacts`, the file of that name in DIR, byte for byte),
## evidence that is INVENTORY's, and one package graph across renderings.
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

read! = |name| {
	text = SbomFiles.read!(name)?
	if !Sbom.json_within_bounds(text) {
		return Err(InputTooLarge)
	}
	Ok(text)
}

run! = |args| match args {
	["inspect", spec_path, lock_path, composition_path, target, output] => {
		spec = Spec.parse(read!(spec_path)?).map_err(|error| Invalid(Str.inspect(error)))?
		lock = Lock.parse(read!(lock_path)?).map_err(|error| Invalid(Str.inspect(error)))?
		composition : Sbom.Composition
		composition = Json.parse(read!(composition_path)?).map_err(|error| Invalid(Str.inspect(error)))?
		inventory = Sbom.inspect(spec, lock, target, composition).map_err(|error| Invalid(error))?
		SbomFiles.write_new!(output, "${Json.to_str(inventory)}\n")?
		Stdout.line!(output)
	}
	["bind", inventory_path, subject_path, context_path, artifact] => bind!(inventory_path, subject_path, context_path, artifact, [("${artifact}.spdx.json", Sbom.render), ("${artifact}.cdx.json", Sbom.render_cyclonedx)])
	["bind", inventory_path, subject_path, context_path, artifact, output] => bind!(inventory_path, subject_path, context_path, artifact, [(output, Sbom.render)])
	["bind", inventory_path, subject_path, context_path, artifact, output, "--spdx-2.3"] => bind!(inventory_path, subject_path, context_path, artifact, [(output, Sbom.render_spdx2)])
	["bind", inventory_path, subject_path, context_path, artifact, output, "--cyclonedx"] => bind!(inventory_path, subject_path, context_path, artifact, [(output, Sbom.render_cyclonedx)])
	["check", .. as rest] => check!(rest, { artifacts: "", inventory: "" })
	_ => Err(Invalid("usage: scripts/sbom.roc inspect SPEC LOCK COMPOSITION TARGET OUTPUT | bind INVENTORY SUBJECT CONTEXT ARTIFACT [OUTPUT [--spdx-2.3 | --cyclonedx]] | check [--artifacts DIR] [--inventory INVENTORY] DOCUMENT..."))
}

check! = |args, options|
	match args {
		["--artifacts", artifacts, .. as rest] => check!(rest, { ..options, artifacts })
		["--inventory", inventory, .. as rest] => check!(rest, { ..options, inventory })
		[] => Err(Invalid("check needs at least one SBOM document"))
		documents => {
			var $checked = []
			for path in documents {
				checked = Sidecar.check(read!(path)?).map_err(|problem| Invalid("${path}: ${problem}"))?
				if !options.artifacts.is_empty() and SbomFiles.digest!("${options.artifacts}/${checked.subject.name}")? != checked.subject.sha256 {
					return Err(Invalid("${path}: subject bytes differ from ${options.artifacts}/${checked.subject.name}"))
				}
				if !options.inventory.is_empty() {
					inventory : Sbom.Inventory
					inventory = Json.parse(read!(options.inventory)?).map_err(|error| Invalid(Str.inspect(error)))?
					Sidecar.against_inventory(checked, inventory).map_err(|problem| Invalid("${path}: ${problem}"))?
				}
				for earlier in $checked {
					if earlier.document.namespace == checked.document.namespace and earlier.document.version != checked.document.version and !Sidecar.same_graph(earlier, checked) {
						return Err(Invalid("${path}: the ${earlier.document.version} and ${checked.document.version} renderings of ${checked.subject.name} differ"))
					}
				}
				$checked = $checked.append(checked)
				Stdout.line!("${path}: ${checked.document.version} sidecar of ${checked.subject.name} checks")?
			}
			Ok({})
		}
	}

## Render every requested document before writing any, so a refusal leaves
## no partial set of sidecars.
bind! = |inventory_path, subject_path, context_path, artifact, outputs| {
	inventory : Sbom.Inventory
	inventory = Json.parse(read!(inventory_path)?).map_err(|error| Invalid(Str.inspect(error)))?
	subject : Sbom.Subject
	subject = Json.parse(read!(subject_path)?).map_err(|error| Invalid(Str.inspect(error)))?
	context : Sbom.Context
	context = Json.parse(read!(context_path)?).map_err(|error| Invalid(Str.inspect(error)))?
	if artifact.replace_each("\\", "/").split_on("/").last() != Ok(subject.filename) {
		return Err(Invalid("subject filename differs from final artifact"))
	}
	if outputs.any(|(output, _)| output == artifact) {
		return Err(Invalid("sidecar must not overwrite subject"))
	}
	digest = SbomFiles.digest!(artifact)?
	if !subject.sha256.is_empty() and subject.sha256 != digest {
		return Err(Invalid("final subject SHA-256 mismatch"))
	}
	var $documents = []
	for (output, render) in outputs {
		$documents = $documents.append((output, render(inventory, { ..subject, sha256: digest }, context).map_err(|error| Invalid(error))?))
	}
	for (output, text) in $documents {
		SbomFiles.write_new!(output, text)?
		Stdout.line!(output)?
	}
	Ok({})
}
