#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	compilers: "../blueprint-cli/compilers.roc",
	core: "../blueprint-core/main.roc",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout
import core.Manifest
import core.Sbom
import src/Integrity
import src/SbomCheck

## Check written SBOM sidecars, SPDX 3.0.1, SPDX 2.3 or CycloneDX 1.7, offline.
##
##   scripts/check_sbom.roc [--release-root ROOT] [--manifest FILE] [--artifacts DIR] [--inventory FILE] DOCUMENT...
##
## Each document must be valid SPDX and meet the blueprint profile. With
## `--artifacts`, its subject is the file of that name in DIR, byte for byte.
## With `--inventory`, its evidence is that inventory's. With `--release-root`,
## it accounts for the release authorities committed there. Renderings of one
## document in different formats must state the same package graph. An
## evidence manifest, named with `--manifest` or found beside a document as
## `<subject>.sbom-manifest.json`, is held to the files it lists, and the
## sidecars it lists are checked as documents.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	match run!(args.map(OsStr.display), { root: "", artifacts: "", inventory: "", manifest: "" }) {
		Ok({}) => Ok({})
		Err(Usage) => {
			_ = Stderr.line!("usage: scripts/check_sbom.roc [--release-root ROOT] [--manifest FILE] [--artifacts DIR] [--inventory FILE] DOCUMENT...")
			Err(Exit(2))
		}
		Err(error) => {
			_ = Stderr.line!("SBOM: ${Str.inspect(error)}")
			Err(Exit(1))
		}
	}
}

run! = |args, options|
	match args {
		["--release-root", root, .. as rest] => run!(rest, { ..options, root })
		["--artifacts", artifacts, .. as rest] => run!(rest, { ..options, artifacts })
		["--inventory", inventory, .. as rest] => run!(rest, { ..options, inventory })
		["--manifest", manifest, .. as rest] => run!(rest, { ..options, manifest })
		[] if options.manifest.is_empty() => Err(Usage)
		documents => check!(documents, options)
	}

check! = |documents, options| {
	var $manifests = []
	var $listed = []
	if !options.manifest.is_empty() {
		verified = SbomCheck.manifest!(options.manifest, options.artifacts, options.inventory)?
		$manifests = $manifests.append((options.manifest, verified))
		$listed = verified.sidecars.map(|entry| Manifest.beside(options.manifest, entry.filename))
		Stdout.line!("Validated ${options.manifest} (manifest of ${verified.subject.filename})")?
	}
	listed = $listed
	var $checked = []
	for path in listed.concat(documents.drop_if(|path| listed.contains(path))) {
		text = Path.read_utf8!(Path.utf8(path))?
		checked = SbomCheck.profile(text).map_err(|problem| Invalid("${path}: ${problem}"))?
		if !options.artifacts.is_empty() {
			bytes = Path.read_bytes!(Path.utf8("${options.artifacts}/${checked.subject.name}")).map_err(|_| Invalid("${path}: no subject ${checked.subject.name} in ${options.artifacts}"))?
			if Integrity.digest(bytes) != checked.subject.sha256 {
				return Err(Invalid("${path}: subject bytes differ"))
			}
		}
		if !options.inventory.is_empty() {
			inventory : Sbom.Inventory
			inventory = Json.parse(Path.read_utf8!(Path.utf8(options.inventory))?).map_err(|_| Invalid("invalid inventory ${options.inventory}"))?
			SbomCheck.against_inventory(checked, inventory).map_err(|problem| Invalid("${path}: ${problem}"))?
		}
		if !options.root.is_empty() {
			SbomCheck.release!(checked, options.root).map_err(|problem| Invalid("${path}: ${Str.inspect(problem)}"))?
		}
		# The named manifest, or the one beside the document for its subject,
		# is verified once; the document then has to describe its subject.
		candidate = if (options.manifest.is_empty()) Manifest.beside(path, "${checked.subject.name}${Manifest.suffix}") else options.manifest
		if !options.manifest.is_empty() or (Path.is_file!(Path.utf8(candidate)) ?? False) {
			verified = match $manifests.find_first(|(known, _)| known == candidate) {
				Ok((_, known)) => known
				Err(_) => {
					fresh = SbomCheck.manifest!(candidate, options.artifacts, options.inventory)?
					$manifests = $manifests.append((candidate, fresh))
					Stdout.line!("Validated ${candidate} (manifest of ${fresh.subject.filename})")?
					fresh
				}
			}
			name = Manifest.file_name_of(path)
			if listed.contains(path) or checked.subject.name == verified.subject.filename {
				Manifest.describes(verified, if (Manifest.beside(candidate, name) == path) name else "", checked).map_err(|problem| Invalid("${path}: ${problem}"))?
			}
		}
		for earlier in $checked {
			if earlier.document.namespace == checked.document.namespace and earlier.document.version != checked.document.version and !SbomCheck.same_graph(earlier, checked) {
				return Err(Invalid("${path}: the ${earlier.document.version} and ${checked.document.version} sidecars of ${checked.subject.name} differ"))
			}
		}
		$checked = $checked.append(checked)
		Stdout.line!("Validated ${path} (${checked.document.version})")?
	}
	Ok({})
}
