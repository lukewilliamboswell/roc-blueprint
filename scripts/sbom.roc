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

## Offline report from already evaluated Spec/Lock; no provider/Store effects.
## inspect SPEC LOCK COMPOSITION TARGET OUTPUT
## bind INVENTORY SUBJECT CONTEXT ARTIFACT OUTPUT
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
	["bind", inventory_path, subject_path, context_path, artifact, output] => {
		inventory : Sbom.Inventory
		inventory = Json.parse(read!(inventory_path)?).map_err(|error| Invalid(Str.inspect(error)))?
		subject : Sbom.Subject
		subject = Json.parse(read!(subject_path)?).map_err(|error| Invalid(Str.inspect(error)))?
		context : Sbom.Context
		context = Json.parse(read!(context_path)?).map_err(|error| Invalid(Str.inspect(error)))?
		if artifact.replace_each("\\", "/").split_on("/").last() != Ok(subject.filename) {
			return Err(Invalid("subject filename differs from final artifact"))
		}
		if artifact == output {
			return Err(Invalid("sidecar must not overwrite subject"))
		}
		digest = SbomFiles.digest!(artifact)?
		if !subject.sha256.is_empty() and subject.sha256 != digest {
			return Err(Invalid("final subject SHA-256 mismatch"))
		}
		text = Sbom.render(inventory, { ..subject, sha256: digest }, context).map_err(|error| Invalid(error))?
		SbomFiles.write_new!(output, text)?
		Stdout.line!(output)
	}
	_ => Err(Invalid("usage: scripts/sbom.roc inspect SPEC LOCK COMPOSITION TARGET OUTPUT | bind INVENTORY SUBJECT CONTEXT ARTIFACT OUTPUT"))
}
