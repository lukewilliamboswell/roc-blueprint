# Mutate SPDX 3.0.1 and 2.3 documents; reading them must be total and sound.
app [target] {
	core: "../../main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
import core.CycloneDx
import core.JsonTree
import core.Sbom
import core.Spdx3

## For any text, `JsonTree.parse` and `Sbom.read` return a result rather than
## crash or hang. JSON the tree accepts re-encodes to text that parses to the
## same tree. A document `Sbom.read` accepts is a sound package graph: package
## identifiers are unique local names, every relationship and root names a
## package, relationships use the composition vocabulary with a scope only on
## `dependsOn`, and an SPDX 3 document also passes `Spdx3.validate`.
## `CycloneDx.validate` is total too; a BOM it accepts declares each
## `bom-ref` once and depends only on declared ones, which this checks again
## independently; and `Sbom.read_cyclonedx` of it is a sound package graph.
##
## The input is raw bytes read as UTF-8, so the seeds in `corpus/` are the
## committed fixtures of every format, which the fuzzer mutates.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) => {
			match JsonTree.parse(text) {
				Ok(tree) => if JsonTree.parse(tree.to_str()) != Ok(tree) {
					crash "accepted JSON did not survive a re-encode"
				}
				Err(_) => {}
			}
			match CycloneDx.validate(text) {
				Ok(bom) => declared(bom)
				Err(_) => {}
			}
			match Sbom.read_cyclonedx(text) {
				Ok(document) => {
					_ = sound(document, text)
				}
				Err(_) => {}
			}
			match Sbom.read(text) {
				Ok(document) => sound(document, text)
				Err(_) => Fuzz.keep
			}
		}
	}

sound : Sbom.Document, Str -> Fuzz.Outcome
sound = |document, text| {
	ids = document.packages_.map(|entry| entry.id)
	if ids.len() != ids.fold([], |all, id| if (all.contains(id)) all else all.append(id)).len() {
		crash "read returned duplicate package identifiers"
	}
	if ids.any(|id| id.is_empty() or id.contains("#")) {
		crash "read returned a package identifier that is not a local name"
	}
	if document.roots.any(|root| !ids.contains(root)) {
		crash "read returned a root that is not a package"
	}
	for edge in document.relationships {
		if !ids.contains(edge.from) or !ids.contains(edge.to) {
			crash "read returned a relationship that names no package"
		}
		if !Sbom.relations.contains(edge.relation) {
			crash "read returned a relationship type outside the composition vocabulary"
		}
		if !edge.scope.is_empty() and (edge.relation != "dependsOn" or !Sbom.scopes.contains(edge.scope)) {
			crash "read returned a lifecycle scope outside dependsOn"
		}
	}
	if !["SPDX-${Spdx3.version}", "SPDX-2.2", "SPDX-2.3", "${CycloneDx.format}-${CycloneDx.version}"].contains(document.version) {
		crash "read returned an unsupported version"
	}
	if document.version == "SPDX-${Spdx3.version}" and Spdx3.validate(text).is_err() {
		crash "read accepted an SPDX 3 document the validator rejects"
	}
	Fuzz.keep
}

## The references of an accepted BOM, found without the validator's index.
declared : JsonTree -> {}
declared = |bom| {
	refs = all_refs(bom)
	if refs.len() != refs.fold([], |all, ref| if (all.contains(ref)) all else all.append(ref)).len() {
		crash "CycloneDx.validate accepted a repeated bom-ref"
	}
	for dependency in (bom.field("dependencies") ?? JsonTree.Array([])).items() ?? [] {
		named = ((dependency.field("dependsOn") ?? JsonTree.Array([])).items() ?? []).map(|item| item.text() ?? "").append((dependency.field("ref") ?? JsonTree.Null).text() ?? "")
		if named.any(|ref| !refs.contains(ref)) {
			crash "CycloneDx.validate accepted a dependency on an undeclared bom-ref"
		}
	}
	{}
}

all_refs : JsonTree -> List(Str)
all_refs = |tree|
	match tree {
		Object(members) => members.fold([], |all, entry| if (entry.key == "bom-ref") all.append(entry.value.text() ?? "") else if (entry.key == "dependencies" or entry.key == "properties") all else all.concat(all_refs(entry.value)))
		Array(items) => items.fold([], |all, item| all.concat(all_refs(item)))
		_ => []
	}

target = Fuzz.target_with({
	name: "sbom-read",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
