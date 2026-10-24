# Render generated inventories as SPDX 3.0.1 and 2.3 and read them back.
app [target] {
	core: "../../main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
import core.CycloneDx
import core.Project
import core.JsonData
import core.Sbom
import core.Spdx3

## For any inventory `Sbom.inspect_declared` accepts, with arbitrary text in
## every free-form field and an arbitrary connected graph:
##
## * `render` succeeds, and its text is SPDX 3.0.1 by `Spdx3.validate` and
##   canonical: re-encoding the parsed JSON gives the same bytes;
## * `render_spdx2` succeeds;
## * `Sbom.read` of each rendering gives exactly the packages and relationships
##   of the inventory, as `expected` below states them independently of the
##   renderers, so the two versions agree with each other and with the input;
## * `Spdx3.check` rejects the rendering after one of `violations` breaks a
##   rule of the SPDX 3.0.1 model in it, so the validator is not vacuous;
## * `render_cyclonedx` succeeds, with canonical CycloneDX 1.7 that
##   `CycloneDx.check` accepts and `Sbom.read_cyclonedx` reads back to the
##   same package graph; its standard fields (dependencies, scopes, hashes,
##   purls, licenses and suppliers) are what `standard` below derives from the
##   inventory; and `CycloneDx.check` rejects it after one of `bom_violations`.
test : Input -> Fuzz.Outcome
test = |input| {
	subject = subject_of(input)
	inventory = match Sbom.inspect_declared(subject.target, composition_of(input), []) {
		Ok(accepted) => accepted
		Err(_) => return Fuzz.reject
	}
	three = match Sbom.render(inventory, subject, context) {
		Ok(text) => text
		Err(problem) if problem.starts_with("SBOM contains credential") => return Fuzz.reject
		Err(problem) => crash "render refused an inspected inventory: ${problem}"
	}
	two = match Sbom.render_spdx2(inventory, subject, context) {
		Ok(text) => text
		Err(problem) => crash "render_spdx2 refused what render accepted: ${problem}"
	}
	tree = match JsonData.decode_with(three, JsonData.documents) {
		Ok(parsed) => parsed
		Err(problem) => crash "SPDX 3.0.1 rendering is not JSON: ${JsonData.message(problem)}"
	}
	if "${encoded(tree)}\n" != three {
		crash "SPDX 3.0.1 rendering is not canonical JSON"
	}
	match Spdx3.check(tree) {
		Ok(_) => {}
		Err(problem) => crash "SPDX 3.0.1 rendering fails the model: ${problem}"
	}
	wanted = expected(inventory, subject)
	if Sbom.read(three) != Ok(wanted) {
		crash "SPDX 3.0.1 rendering reads back differently: ${Str.inspect(Sbom.read(three))}"
	}
	if Sbom.read(two) != Ok({ ..wanted, version: "SPDX-2.3" }) {
		crash "SPDX 2.3 rendering reads back differently: ${Str.inspect(Sbom.read(two))}"
	}
	bom_text = match Sbom.render_cyclonedx(inventory, subject, context) {
		Ok(text) => text
		Err(problem) => {
			if representable(inventory.relationships) {
				crash "render_cyclonedx refused representable graph: ${problem}"
			}
			return Fuzz.keep
		}
	}
	if !representable(inventory.relationships) {
		crash "CycloneDX silently rendered unrepresentable containment"
	}
	bom = match JsonData.decode_with(bom_text, JsonData.documents) {
		Ok(parsed) => parsed
		Err(problem) => crash "CycloneDX rendering is not JSON: ${JsonData.message(problem)}"
	}
	if "${encoded(bom)}\n" != bom_text {
		crash "CycloneDX rendering is not canonical JSON"
	}
	match CycloneDx.check(bom) {
		Ok(_) => {}
		Err(problem) => crash "CycloneDX rendering fails the schema: ${problem}"
	}
	if Sbom.read_cyclonedx(bom_text).map_ok(ordered) != Ok(ordered({ ..wanted, version: "CycloneDX-${CycloneDx.version}" })) {
		crash "CycloneDX rendering reads back differently: ${Str.inspect(Sbom.read_cyclonedx(bom_text))}"
	}
	if seen(bom) != standard(inventory, subject) {
		crash "CycloneDX standard fields differ from the inventory:\n${Str.inspect(seen(bom))}\n${Str.inspect(standard(inventory, subject))}"
	}
	# A consumer of plain CycloneDX, without Blueprint's properties, imports
	# what the projection below says, and nothing else.
	plain = strip_properties(bom)
	if Sbom.read(encoded(plain)).map_ok(ordered) != Ok(ordered(projected(inventory, subject, (bom.field("serialNumber") ?? JsonData.Null).string() ?? ""))) {
		crash "plain CycloneDX imports differently:\n${Str.inspect(Sbom.read(encoded(plain)))}\n${Str.inspect(projected(inventory, subject, (bom.field("serialNumber") ?? JsonData.Null).string() ?? ""))}"
	}
	# Native SPDX files join the graph without inventing package declarations.
	with_file_3 = add_file_3(tree, context.namespace)
	if Sbom.read(encoded(with_file_3)) != Ok({ ..wanted, packages_: wanted.packages_.append(native_file), relationships: wanted.relationships.append({ from: "Subject", to: "File-added", relation: "contains", scope: "", basis: "" }) }) {
		crash "SPDX 3.0.1 with a file reads differently: ${Str.inspect(Sbom.read(encoded(with_file_3)))}"
	}
	two_tree = JsonData.decode_with(two, JsonData.documents) ?? crash "SPDX 2.3 rendering is not JSON"
	if Sbom.read(encoded(add_file_2(two_tree))) != Ok({ ..wanted, version: "SPDX-2.3", packages_: wanted.packages_.append(native_file), relationships: wanted.relationships.append({ from: "Subject", to: "File-added", relation: "contains", scope: "", basis: "" }) }) {
		crash "SPDX 2.3 with a file reads differently: ${Str.inspect(Sbom.read(encoded(add_file_2(two_tree))))}"
	}
	bom_violation = bom_violations.get(input.bom_violation.to_u64() % bom_violations.len()) ?? crash "no violations"
	match (bom_violation.apply)(bom, input.pick) {
		Ok(broken) =>
			if CycloneDx.check(broken).is_ok() {
				crash "CycloneDx.check accepted a BOM with ${bom_violation.name}"
			}
		Err(NotApplicable) => {}
	}
	violation = violations.get(input.violation.to_u64() % violations.len()) ?? crash "no violations"
	match (violation.apply)(tree, input.pick) {
		Ok(broken) => if Spdx3.check(broken).is_ok() {
			crash "Spdx3.check accepted a document with ${violation.name}"
		}
		Err(NotApplicable) => {}
	}
	Fuzz.keep
}

## What reading either rendering must give: one package per component after
## the subject, with only what SPDX can state about it.
expected : Sbom.Inventory, Sbom.Subject -> Sbom.Document
expected = |inventory, subject| {
	subject_package = { kind: subject.kind, copyright: subject.copyright, attribution: subject.attribution, source_refs: [], id: "Subject", name: subject.filename, version: subject.version, supplier: subject.producer, download: subject.url, license: subject.license, license_url: subject.license_url, sha256: subject.sha256, identity: "", comment: Json.to_str({ kind: subject.kind, copyright: subject.copyright, attribution: subject.attribution, target: subject.target, digest_kind: "final-deliverable-sha256" }) }
	components = inventory.components.map(
		|component| {
			kind: component.kind,
			copyright: component.copyright,
			attribution: component.attribution,
			source_refs: component.source_refs,
			id: component.id,
			name: component.name,
			version: component.version,
			supplier: component.producer,
			download: component.download,
			license: component.license,
			license_url: if (component.license.contains("LicenseRef-")) component.license_url else "",
			sha256: component.sha256,
			identity: purl(component),
			comment: Json.to_str({ kind: component.kind, copyright: component.copyright, attribution: component.attribution, package_url: purl(component), source_refs: component.source_refs, identity: component.identity, origin: component.origin, target: component.target, modifications: component.modified }),
		},
	)
	evidence = Json.to_str({ profile: Sbom.profile, revision: context.revision, target: subject.target, coverage: inventory.coverage, inspected: inventory.inspected, dispositions: inventory.inputs })
	{ version: "SPDX-${Spdx3.version}", namespace: context.namespace, name: subject.filename, roots: ["Subject"], packages_: components.prepend(subject_package), relationships: inventory.relationships, evidence: [evidence], gaps: [] }
}

## What a reader of standard CycloneDX learns about each component, and the
## subject's digest.
Standard : { subject : { sha256 : Str, kind : Str, copyright : Str, supplier : Str, license : Str }, components : List({ ref : Str, parent : Str, kind : Str, copyright : Str, source_refs : List(Sbom.SourceRef), scope : Str, purl : Str, sha256 : Str, license : Str, supplier : Str, depends : List(Str) }), dependents : List(Str), dependency_refs : List(Str), compositions : List({ aggregate : Str, assemblies : List(Str), dependencies : List(Str) }) }

## The standard fields as the CycloneDX specification says the inventory's
## facts are spelled: a component the subject needs at run time is required, a
## build, test or development tool excluded, anything else optional.
standard : Sbom.Inventory, Sbom.Subject -> Standard
standard = |inventory, subject| {
	runtime = |edge| edge.relation == "contains" or (edge.relation == "dependsOn" and (edge.scope == "" or edge.scope == "runtime"))
	var $needed = ["Subject"]
	var $grew = True
	while $grew {
		$grew = False
		for edge in inventory.relationships {
			if runtime(edge) and $needed.contains(edge.from) and !$needed.contains(edge.to) {
				$needed = $needed.append(edge.to)
				$grew = True
			}
		}
	}
	tools = inventory.relationships.keep_if(|edge| edge.relation == "dependsOn" and ["build", "test", "development"].contains(edge.scope)).map(|edge| edge.to)
	depends = |ref| inventory.relationships.keep_if(|edge| edge.from == ref and edge.relation == "dependsOn").map(|edge| edge.to).fold([], |all, to| if (all.contains(to)) all else all.append(to))
	{
		subject: { sha256: subject.sha256, kind: if (subject.kind == "unknown") "file" else subject.kind, copyright: if (subject.copyright == "NOASSERTION") "" else subject.copyright, supplier: supplied(subject.producer), license: expressed(subject.license) },
		components: inventory.components.map(
			|component| {
				ref: component.id,
				parent: inventory.relationships.find_first(|edge| edge.relation == "contains" and edge.to == component.id).map_ok(|edge| edge.from) ?? "",
				kind: if (component.kind == "unknown") "library" else component.kind,
				copyright: if (component.copyright == "NOASSERTION") "" else component.copyright,
				source_refs: component.source_refs,
				scope: if ($needed.contains(component.id)) "required" else if (tools.contains(component.id)) "excluded" else "optional",
				purl: purl(component),
				sha256: component.sha256,
				license: if (component.license == "NOASSERTION" or component.license == "NONE") "" else component.license,
				supplier: if (component.producer.starts_with("Organization: ")) "supplier ${component.producer.drop_prefix("Organization: ")}" else if (component.producer.starts_with("Person: ")) "author ${component.producer.drop_prefix("Person: ")}" else "",
				depends: depends(component.id),
			},
		).sort_with(|a, b| Project.bytewise(a.ref, b.ref)),
		dependents: depends("Subject"),
		dependency_refs: inventory.components.map(|component| component.id).prepend("Subject").keep_if(|id| !depends(id).is_empty() or inventory.coverage.any(|claim| claim.component == id and claim.aspect == "dependencies" and ["complete", "verified-empty"].contains(claim.status))),
		compositions: claims(inventory.coverage),
	}
}

## A BOM with every `properties` member removed, as a plain CycloneDX
## consumer that ignores them sees it.
strip_properties : JsonData -> JsonData
strip_properties = |tree|
	match tree {
		Object(members) => JsonData.Object(members.drop_if(|entry| entry.name == "properties").map(|entry| { name: entry.name, value: strip_properties(entry.value) }))
		Array(items) => JsonData.Array(items.map(strip_properties))
		_ => tree
	}

## What importing plain CycloneDX gives: each relationship CycloneDX can say,
## `contains` as assembly hierarchy and `dependsOn` as an unscoped dependency; a
## component nothing connects to the subject related to it as `other`; and
## only the facts plain CycloneDX carries.
projected : Sbom.Inventory, Sbom.Subject, Str -> Sbom.Document
projected = |inventory, subject, serial| {
	refs = inventory.components.map(|component| component.id).prepend("Subject")
	said = inventory.relationships.keep_if(|edge| edge.relation == "contains").map(|edge| { from: edge.from, to: edge.to, relation: "contains", scope: "", basis: "Nested in the CycloneDX component tree" }).concat(
		refs.fold(
			[],
			|all, ref| all.concat(
				inventory.relationships.keep_if(|edge| edge.from == ref and edge.relation == "dependsOn").map(|edge| edge.to).fold([], |kept, to| if (kept.contains(to)) kept else kept.append(to)).map(|to| { from: ref, to, relation: "dependsOn", scope: "", basis: "CycloneDX dependency; CycloneDX states no lifecycle scope for it" }),
			),
		),
	)
	var $reached = ["Subject"]
	var $grew = True
	while $grew {
		$grew = False
		for edge in said {
			if $reached.contains(edge.from) and !$reached.contains(edge.to) {
				$reached = $reached.append(edge.to)
				$grew = True
			}
			if $reached.contains(edge.to) and !$reached.contains(edge.from) {
				$reached = $reached.append(edge.from)
				$grew = True
			}
		}
	}
	listed = inventory.components.keep_if(|component| !$reached.contains(component.id) and !inventory.relationships.any(|edge| edge.relation == "contains" and edge.to == component.id)).map(|component| { from: "Subject", to: component.id, relation: "other", scope: "", basis: "Listed in the CycloneDX BOM's components; the BOM states no relationship to the described component" })
	scope_of = standard(inventory, subject).components
	{
		version: "CycloneDX-1.7",
		namespace: serial,
		name: subject.filename,
		roots: ["Subject"],
		packages_: inventory.components.map(
			|component| {
				kind: if (component.kind == "unknown") "library" else component.kind,
				copyright: component.copyright,
				attribution: "NOASSERTION",
				source_refs: component.source_refs,
				id: component.id,
				name: component.name,
				version: component.version,
				supplier: component.producer,
				download: component.download,
				license: if (component.license == "NONE") "NOASSERTION" else component.license,
				license_url: if (component.license.contains("LicenseRef-") and component.license_url != "NOASSERTION") component.license_url else "",
				sha256: component.sha256,
				identity: purl(component),
				comment: Json.to_str({ type: if (component.kind == "unknown") "library" else component.kind, scope: (scope_of.find_first(|entry| entry.ref == component.id) ?? crash "unscoped").scope }),
			},
		).prepend({ kind: if (subject.kind == "unknown") "file" else subject.kind, copyright: subject.copyright, attribution: "NOASSERTION", source_refs: [], id: "Subject", name: subject.filename, version: subject.version, supplier: subject.producer, download: subject.url, license: if (subject.license == "NONE") "NOASSERTION" else subject.license, license_url: subject.license_url, sha256: subject.sha256, identity: "", comment: Json.to_str({ type: if (subject.kind == "unknown") "file" else subject.kind, scope: "" }) }),
		relationships: said.concat(listed),
		evidence: projected_evidence(inventory.coverage),
		gaps: [],
	}
}

## An SPDX 3.0.1 rendering with a file in its graph and a relationship from
## the subject to it.
add_file_3 : JsonData, Str -> JsonData
add_file_3 = |tree, namespace| {
	objects = graph(tree)
	file = JsonData.Object([{ name: "type", value: JsonData.String("software_File") }, { name: "spdxId", value: JsonData.String("${namespace}#File-added") }, { name: "creationInfo", value: JsonData.String("_:creationinfo") }, { name: "name", value: JsonData.String("./README") }])
	relation = JsonData.Object([{ name: "type", value: JsonData.String("Relationship") }, { name: "spdxId", value: JsonData.String("${namespace}#spdx/relationship/added") }, { name: "creationInfo", value: JsonData.String("_:creationinfo") }, { name: "from", value: JsonData.String("${namespace}#Subject") }, { name: "relationshipType", value: JsonData.String("contains") }, { name: "to", value: JsonData.Array([JsonData.String("${namespace}#File-added")]) }])
	with_graph(tree, objects.concat([file, relation]))
}

## An SPDX 2.3 rendering with a file and the subject's CONTAINS of it.
add_file_2 : JsonData -> JsonData
add_file_2 = |tree| {
	file = JsonData.Object([{ name: "SPDXID", value: JsonData.String("SPDXRef-File-added") }, { name: "fileName", value: JsonData.String("./README") }, { name: "checksums", value: JsonData.Array([JsonData.Object([{ name: "algorithm", value: JsonData.String("SHA1") }, { name: "checksumValue", value: JsonData.String(Str.join_with(List.repeat("b", 40), "")) }])]) }])
	relation = JsonData.Object([{ name: "spdxElementId", value: JsonData.String("SPDXRef-Subject") }, { name: "relatedSpdxElement", value: JsonData.String("SPDXRef-File-added") }, { name: "relationshipType", value: JsonData.String("CONTAINS") }])
	with_files = set(tree, "files", JsonData.Array([file]))
	set(with_files, "relationships", JsonData.Array(((tree.field("relationships") ?? JsonData.Array([])).array() ?? []).append(relation)))
}

## The same fields read from a BOM with nothing but the CycloneDX schema.
seen : JsonData -> Standard
seen = |bom| {
	text_of = |tree, key| (tree.field(key) ?? JsonData.Null).string() ?? ""
	list_of = |tree, key| (tree.field(key) ?? JsonData.Array([])).array() ?? []
	sha = |tree| list_of(tree, "hashes").find_first(|hash| text_of(hash, "alg") == "SHA-256").map_ok(|hash| text_of(hash, "content")) ?? ""
	dependencies = list_of(bom, "dependencies")
	depends = |ref| dependencies.find_first(|entry| text_of(entry, "ref") == ref).map_ok(|entry| list_of(entry, "dependsOn").map(|item| item.string() ?? "")) ?? []
	subject = (bom.field("metadata") ?? JsonData.Null).field("component") ?? JsonData.Null
	entries = flatten(list_of(subject, "components"), "Subject").concat(flatten(list_of(bom, "components"), ""))
	license_ = |entry| list_of(entry, "licenses").first().map_ok(|choice| text_of(choice, "expression")) ?? ""
	supplier_ = |entry| match entry.field("supplier") {
		Ok(supplier) => "supplier ${text_of(supplier, "name")}"
		Err(_) => list_of(entry, "authors").first().map_ok(|author| "author ${text_of(author, "name")}") ?? ""
	}
	{
		subject: { sha256: sha(subject), kind: text_of(subject, "type"), copyright: text_of(subject, "copyright"), supplier: supplier_(subject), license: license_(subject) },
		components: entries.map(
			|found| {
				entry = found.tree
				{ ref: text_of(entry, "bom-ref"), parent: found.parent, kind: text_of(entry, "type"), copyright: text_of(entry, "copyright"), source_refs: list_of(entry, "externalReferences").keep_if(|ref| ["vcs", "source-distribution"].contains(text_of(ref, "type"))).map(|ref| { type: text_of(ref, "type"), url: text_of(ref, "url") }), scope: text_of(entry, "scope"), purl: text_of(entry, "purl"), sha256: sha(entry), license: license_(entry), supplier: supplier_(entry), depends: depends(text_of(entry, "bom-ref")) }
			},
		).sort_with(|a, b| Project.bytewise(a.ref, b.ref)),
		dependents: depends("Subject"),
		dependency_refs: dependencies.map(|entry| text_of(entry, "ref")),
		compositions: list_of(bom, "compositions").map(|entry| { aggregate: text_of(entry, "aggregate"), assemblies: list_of(entry, "assemblies").map(|ref| ref.string() ?? ""), dependencies: list_of(entry, "dependencies").map(|ref| ref.string() ?? "") }),
	}
}

context : Sbom.Context
context = { namespace: "https://example.org/sbom/fuzz/revision-1", revision: "1", created: "2026-10-21T00:00:00Z", author: "Organization: Fuzz producers", generator: "Tool: sbom-render-fuzz" }

## Free-form text: arbitrary, but never empty where a value is required.
filled : Str, Str -> Str
filled = |text, fallback| if (text.trim().is_empty()) fallback else text

Raw : { name : Str, version : Str, producer : U8, producer_name : Str, license : U8, sha : U8, identity : U8, download : U8, modified : Str, parent : U8, relation : U8, reverse : U8, basis : Str }

Input : { components : List(Raw), extra : List({ from : U8, to : U8, relation : U8 }), filename : Str, version : Str, target : U8, reason : Str, violation : U8, bom_violation : U8, pick : U64 }

licenses : List({ expression : Str, url : Str })
licenses = [
	{ expression: "MIT", url: "" },
	{ expression: "Apache-2.0 WITH LLVM-exception", url: "" },
	{ expression: "NOASSERTION", url: "" },
	{ expression: "NONE", url: "" },
	{ expression: "(MIT OR Apache-2.0) AND BSD-3-Clause", url: "" },
	{ expression: "LicenseRef-Vendor", url: "https://example.org/terms/vendor" },
	{ expression: "GPL-2.0-or-later AND LicenseRef-Vendor.Terms-2", url: "https://example.org/terms/vendor-2" },
	{ expression: "LGPL-2.1+", url: "" },
]

## A relationship as the composition states it, by choice.
relationship : U64 -> { relation : Str, scope : Str }
relationship = |choice| {
	options = [("contains", ""), ("dependsOn", ""), ("dependsOn", "build"), ("dependsOn", "test"), ("dependsOn", "development"), ("dependsOn", "runtime"), ("generates", ""), ("patchedBy", ""), ("hasVariant", ""), ("copiedTo", ""), ("other", "")]
	(relation, scope) = options.get(choice % options.len()) ?? ("contains", "")
	{ relation, scope }
}

subject_of : Input -> Sbom.Subject
subject_of = |input| {
	kind: if (input.target % 3 == 0) "application" else "file",
	producer: if (input.target % 2 == 0) "Organization: Fuzz archive producer" else "NOASSERTION",
	license: if (input.target % 2 == 0) "MIT" else "NOASSERTION",
	license_url: "",
	copyright: if (input.target % 2 == 0) "Copyright Fuzz producers" else "NOASSERTION",
	attribution: if (input.target % 2 == 0) "Reviewed archive notice" else "NOASSERTION",
	filename: {
		name = input.filename.replace_each("/", "_").replace_each("\\", "_")
		if (name.trim().is_empty() or name == "." or name == "..") "artifact" else name
	},
	version: filled(input.version, "1.0.0"),
	target: if (input.target % 2 == 0) "x86_64-linux" else "source",
	sha256: Crypto.SHA256.hash(input.filename.to_utf8()).to_hex(),
	url: "https://example.org/releases/artifact",
}

## Components `c0`, `c1`, … each attached to the subject or an earlier
## component, so the graph is connected, plus extra edges between any two.
composition_of : Input -> Sbom.Composition
composition_of = |input| {
	var $components = []
	var $edges = []
	for raw in input.components {
		index = $components.len()
		id = "c${index.to_str()}"
		# Each choice is salted with the position, so input the fuzzer has
		# exhausted (decoded as zeros) still varies every choice.
		pick = |byte, salt| byte.to_u64() + index * salt
		chosen = licenses.get(pick(raw.license, 3) % licenses.len()) ?? { expression: "MIT", url: "" }
		$components = $components.append({
			kind: ["file", "application", "library", "unknown"].get(pick(raw.identity, 1) % 4) ?? "unknown",
			copyright: if (pick(raw.sha, 1) % 2 == 0) "NOASSERTION" else filled(raw.modified, "Copyright Fuzz upstream"),
			attribution: if (pick(raw.sha, 2) % 2 == 0) "NOASSERTION" else filled(raw.basis, "Reviewed upstream notice"),
			package_url: if (pick(raw.identity, 2) % 3 == 0) "" else "pkg:generic/${id}@${raw.version.to_utf8().len().to_str()}",
			source_refs: if (pick(raw.download, 2) % 2 == 0) [] else [{ type: if (raw.download % 2 == 0) "vcs" else "source-distribution", url: "https://example.org/source/${id}/commit-abc" }],
			id,
			name: filled(raw.name, "component"),
			producer: match pick(raw.producer, 1) % 3 {
				0 => "NOASSERTION"
				1 => "Organization: ${filled(raw.producer_name, "Upstream")}"
				_ => "Person: ${filled(raw.producer_name, "Maintainer")}"
			},
			version: filled(raw.version, "0"),
			identity: match pick(raw.identity, 2) % 3 {
				0 => "pkg:generic/${id}@${(raw.version.to_utf8().len()).to_str()}"
				1 => "https://example.org/source/${id}"
				_ => "urn:example:${id}"
			},
			download: if (pick(raw.download, 1) % 2 == 0) "NOASSERTION" else "https://example.org/download/${id}.tar.gz",
			sha256: if (pick(raw.sha, 1) % 2 == 0) "" else Crypto.SHA256.hash(raw.name.to_utf8()).to_hex(),
			license: chosen.expression,
			license_url: chosen.url,
			modified: raw.modified,
			target: if (input.target % 2 == 0) "x86_64-linux" else "",
			origin: "reviewed",
		})
		parent = pick(raw.parent, 1) % (index + 1)
		other = if (parent == 0) "Subject" else "c${(parent - 1).to_str()}"
		stated = relationship(pick(raw.relation, 2))
		# Point from the earlier node unless the input says otherwise, so every
		# relation kind also occurs where the subject reaches it.
		(from, to) = if (raw.reverse % 2 == 0) (other, id) else (id, other)
		$edges = $edges.append({ from, to, relation: stated.relation, scope: stated.scope, basis: filled(raw.basis, "Generated relationship") })
	}
	count = $components.len()
	nodes = $components.map(|component| component.id).prepend("Subject")
	for extra in input.extra {
		from = nodes.get(extra.from.to_u64() % (count + 1)) ?? "Subject"
		to = nodes.get(extra.to.to_u64() % (count + 1)) ?? "Subject"
		stated = relationship(extra.relation.to_u64())
		duplicate = $edges.any(|edge| edge.from == from and edge.to == to and edge.relation == stated.relation and edge.scope == stated.scope)
		if from != to and !duplicate {
			$edges = $edges.append({ from, to, relation: stated.relation, scope: stated.scope, basis: "Extra generated relationship" })
		}
	}
	{
		profile: Sbom.profile,
		imported_documents: [],
		unavailable_sboms: [],
		components: $components,
		relationships: $edges,
		coverage: [{ scope: "all", component: "Subject", aspect: if (input.target % 2 == 0) "assembly" else "dependencies", status: if (count == 0) "verified-empty" else if (input.target % 3 == 0) "complete" else "incomplete", reason: filled(input.reason, "Generated coverage"), contact: "https://example.org/support" }].concat($components.map(|component| { scope: "closure-${component.id}", component: component.id, aspect: "dependencies", status: if (component.kind == "file" and !$edges.any(|edge| edge.from == component.id and edge.relation == "dependsOn")) "verified-empty" else if (component.kind == "application") "unknown" else "incomplete", reason: "Generated component dependency review", contact: "https://example.org/support" })),
		inputs: [],
	}
}

## A document this target built, as text; it must encode under the rules
## Blueprint reads documents with.
encoded : JsonData -> Str
encoded = |tree|
	match JsonData.encode_with(tree, JsonData.documents) {
		Ok(text) => text
		Err(problem) => crash "a built document does not encode: ${JsonData.message(problem)}"
	}

## Violations

Members : List({ name : Str, value : JsonData })

## The `@graph` objects of a rendering.
graph : JsonData -> List(JsonData)
graph = |tree| (tree.field("@graph") ?? JsonData.Array([])).array() ?? []

with_graph : JsonData, List(JsonData) -> JsonData
with_graph = |tree, objects| set(tree, "@graph", JsonData.Array(objects))

set : JsonData, Str, JsonData -> JsonData
set = |tree, key, value|
	match tree {
		Object(members) => if (members.any(|entry| entry.name == key)) JsonData.Object(members.map(|entry| if (entry.name == key) { name: key, value } else entry)) else JsonData.Object(members.append({ name: key, value }))
		_ => tree
	}

remove : JsonData, Str -> JsonData
remove = |tree, key|
	match tree {
		Object(members) => JsonData.Object(members.drop_if(|entry| entry.name == key))
		_ => tree
	}

## Change the `pick`th object of `@graph` that `chosen` accepts, if any.
edit_one : JsonData, U64, (JsonData -> Bool), (JsonData -> JsonData) -> Try(JsonData, [NotApplicable])
edit_one = |tree, pick, chosen, change| {
	objects = graph(tree)
	count = objects.keep_if(chosen).len()
	if count == 0 {
		return Err(NotApplicable)
	}
	wanted = pick % count
	var $seen = 0
	var $edited = []
	for object in objects {
		if chosen(object) {
			$edited = $edited.append(if ($seen == wanted) change(object) else object)
			$seen = $seen + 1
		} else {
			$edited = $edited.append(object)
		}
	}
	Ok(with_graph(tree, $edited))
}

of_type : List(Str) -> (JsonData -> Bool)
of_type = |types| |object| types.contains((object.field("type") ?? JsonData.Null).string() ?? "")

elements : JsonData -> Bool
elements = |object| object.field("spdxId").is_ok()

relationships : List(Str)
relationships = ["Relationship", "LifecycleScopedRelationship"]

## Each breaks a rule the SPDX 3.0.1 schema or model states.
violations : List({ name : Str, apply : JsonData, U64 -> Try(JsonData, [NotApplicable]) })
violations = [
	{ name: "an element without creationInfo", apply: |tree, pick| edit_one(tree, pick, elements, |object| remove(object, "creationInfo")) },
	{ name: "a relationship to an element outside the document", apply: |tree, pick| edit_one(tree, pick, of_type(relationships), |object| set(object, "to", JsonData.Array([JsonData.String("${context.namespace}#missing")]))) },
	{ name: "a relationship with no target", apply: |tree, pick| edit_one(tree, pick, of_type(relationships), |object| set(object, "to", JsonData.Array([]))) },
	{ name: "an SPDX 2 relationship type", apply: |tree, pick| edit_one(tree, pick, of_type(relationships), |object| set(object, "relationshipType", JsonData.String("DEPENDS_ON"))) },
	{ name: "a relationship without relationshipType", apply: |tree, pick| edit_one(tree, pick, of_type(relationships), |object| remove(object, "relationshipType")) },
	{ name: "an SPDX 2 package property", apply: |tree, pick| edit_one(tree, pick, of_type(["software_Package"]), |object| set(object, "versionInfo", JsonData.String("1"))) },
	{ name: "a single value where an array is required", apply: |tree, pick| edit_one(tree, pick, of_type(relationships), |object| set(object, "to", (object.field("to") ?? JsonData.Array([])).array().map_ok(|items| items.first() ?? JsonData.Null) ?? JsonData.Null)) },
	{
		name: "a duplicate spdxId",
		apply: |tree, pick| {
			objects = graph(tree).keep_if(elements)
			match objects.get(pick % (if (objects.is_empty()) 1 else objects.len())) {
				Ok(copy) => Ok(with_graph(tree, graph(tree).append(copy)))
				Err(_) => Err(NotApplicable)
			}
		},
	},
	{ name: "a blank-node spdxId", apply: |tree, pick| edit_one(tree, pick, elements, |object| set(object, "spdxId", JsonData.String("_:element"))) },
	{ name: "an unknown class", apply: |tree, pick| edit_one(tree, pick, of_type(["software_Package"]), |object| set(object, "type", JsonData.String("software_Packages"))) },
	{ name: "a 3.0.0 context", apply: |tree, _| Ok(set(tree, "@context", JsonData.String("https://spdx.org/rdf/3.0.0/spdx-context.jsonld"))) },
	{ name: "a member beside @context and @graph", apply: |tree, _| Ok(set(tree, "spdxVersion", JsonData.String("SPDX-3.0"))) },
	{ name: "a specVersion other than 3.0.1", apply: |tree, pick| edit_one(tree, pick, of_type(["CreationInfo"]), |object| set(object, "specVersion", JsonData.String("3.0.0"))) },
	{ name: "an impossible creation date", apply: |tree, pick| edit_one(tree, pick, of_type(["CreationInfo"]), |object| set(object, "created", JsonData.String("2026-02-30T00:00:00Z"))) },
	{ name: "a non-UTC creation date", apply: |tree, pick| edit_one(tree, pick, of_type(["CreationInfo"]), |object| set(object, "created", JsonData.String("2026-10-21T00:00:00+01:00"))) },
	{ name: "a truncated SHA-256", apply: |tree, pick| edit_one(tree, pick, |object| object.field("verifiedUsing").is_ok(), |object| set(object, "verifiedUsing", JsonData.Array([JsonData.Object([{ name: "type", value: JsonData.String("Hash") }, { name: "algorithm", value: JsonData.String("sha256") }, { name: "hashValue", value: JsonData.String("abc") }])]))) },
	{ name: "an invalid license expression", apply: |tree, pick| edit_one(tree, pick, of_type(["simplelicensing_LicenseExpression"]), |object| set(object, "simplelicensing_licenseExpression", JsonData.String("MIT OR"))) },
	{ name: "a license list version that is not SemVer", apply: |tree, pick| edit_one(tree, pick, of_type(["simplelicensing_LicenseExpression"]), |object| set(object, "simplelicensing_licenseListVersion", JsonData.String("3.26"))) },
	{ name: "a declared license that is a package", apply: |tree, pick| edit_one(tree, pick, |object| (object.field("relationshipType") ?? JsonData.Null) == JsonData.String("hasDeclaredLicense"), |object| set(object, "to", JsonData.Array([object.field("from") ?? JsonData.Null]))) },
	{ name: "a supplier that is a package", apply: |tree, pick| edit_one(tree, pick, |object| object.field("suppliedBy").is_ok(), |object| set(object, "suppliedBy", object.field("spdxId") ?? JsonData.Null)) },
	{ name: "a lifecycle scope outside the vocabulary", apply: |tree, pick| edit_one(tree, pick, of_type(["LifecycleScopedRelationship"]), |object| set(object, "scope", JsonData.String("compile"))) },
	{ name: "a creationInfo that names no CreationInfo", apply: |tree, pick| edit_one(tree, pick, elements, |object| set(object, "creationInfo", JsonData.String("_:elsewhere"))) },
	{ name: "a number where text is required", apply: |tree, pick| edit_one(tree, pick, of_type(["software_Package"]), |object| set(object, "name", JsonData.Number("1"))) },
]

## Each breaks a rule the CycloneDX 1.7 schema or specification states.
bom_violations : List({ name : Str, apply : JsonData, U64 -> Try(JsonData, [NotApplicable]) })
bom_violations = [
	{ name: "a composition aggregate outside the vocabulary", apply: |bom, pick| edit_list(bom, "compositions", pick, |_| True, |entry| set(entry, "aggregate", JsonData.String("asserted-empty"))) },
	{ name: "a composition naming an undeclared assembly", apply: |bom, pick| edit_list(bom, "compositions", pick, |_| True, |entry| set(entry, "assemblies", JsonData.Array([JsonData.String("missing")]))) },
	{ name: "another bomFormat", apply: |bom, _| Ok(set(bom, "bomFormat", JsonData.String("SPDX"))) },
	{ name: "a 1.6 specVersion", apply: |bom, _| Ok(set(bom, "specVersion", JsonData.String("1.6"))) },
	{ name: "a BOM version of 0", apply: |bom, _| Ok(set(bom, "version", JsonData.Number("0"))) },
	{ name: "a fractional BOM version", apply: |bom, _| Ok(set(bom, "version", JsonData.Number("1.5"))) },
	{ name: "an uppercase serial number", apply: |bom, _| Ok(set(bom, "serialNumber", JsonData.String(((bom.field("serialNumber") ?? JsonData.Null).string() ?? "").replace_each("a", "A").replace_each("b", "B").replace_each("c", "C").replace_each("d", "D").replace_each("e", "E").replace_each("f", "F").replace_each("8", "F")))) },
	{ name: "a services section", apply: |bom, _| Ok(set(bom, "services", JsonData.Array([]))) },
	{ name: "a timestamp without a zone", apply: |bom, _| Ok(set(bom, "metadata", set(bom.field("metadata") ?? JsonData.Null, "timestamp", JsonData.String("2026-10-21T00:00:00")))) },
	{ name: "a dependency on an undeclared bom-ref", apply: |bom, pick| edit_list(bom, "dependencies", pick, |_| True, |entry| set(entry, "dependsOn", JsonData.Array([JsonData.String("missing")]))) },
	{ name: "a dependency entry for an undeclared bom-ref", apply: |bom, pick| edit_list(bom, "dependencies", pick, |_| True, |entry| set(entry, "ref", JsonData.String("missing"))) },
	{ name: "a repeated dependsOn reference", apply: |bom, pick| edit_list(bom, "dependencies", pick, |entry| entry.field("dependsOn").is_ok(), |entry| set(entry, "dependsOn", JsonData.Array(((entry.field("dependsOn") ?? JsonData.Array([])).array() ?? []).concat(((entry.field("dependsOn") ?? JsonData.Array([])).array() ?? []).take_first(1))))) },
	{ name: "a duplicate bom-ref", apply: |bom, pick| edit_list(bom, "components", pick, |_| True, |entry| set(entry, "bom-ref", JsonData.String("Subject"))) },
	{ name: "a component without a name", apply: |bom, pick| edit_list(bom, "components", pick, |_| True, |entry| remove(entry, "name")) },
	{ name: "a component type outside the vocabulary", apply: |bom, pick| edit_list(bom, "components", pick, |_| True, |entry| set(entry, "type", JsonData.String("crate"))) },
	{ name: "a scope outside the vocabulary", apply: |bom, pick| edit_list(bom, "components", pick, |_| True, |entry| set(entry, "scope", JsonData.String("build"))) },
	{ name: "an unknown component property", apply: |bom, pick| edit_list(bom, "components", pick, |_| True, |entry| set(entry, "versionInfo", JsonData.String("1"))) },
	{ name: "a truncated SHA-256", apply: |bom, pick| edit_list(bom, "components", pick, |entry| entry.field("hashes").is_ok(), |entry| set(entry, "hashes", JsonData.Array([JsonData.Object([{ name: "alg", value: JsonData.String("SHA-256") }, { name: "content", value: JsonData.String("abc") }])]))) },
	{ name: "a hash algorithm outside the vocabulary", apply: |bom, pick| edit_list(bom, "components", pick, |entry| entry.field("hashes").is_ok(), |entry| set(entry, "hashes", JsonData.Array([JsonData.Object([{ name: "alg", value: JsonData.String("SHA256") }, { name: "content", value: JsonData.String(Str.join_with(List.repeat("a", 64), "")) }])]))) },
	{ name: "an invalid license expression", apply: |bom, pick| edit_list(bom, "components", pick, |entry| entry.field("licenses").is_ok(), |entry| set(entry, "licenses", JsonData.Array([JsonData.Object([{ name: "expression", value: JsonData.String("MIT AND") }])]))) },
	{ name: "a purl without its scheme", apply: |bom, pick| edit_list(bom, "components", pick, |entry| entry.field("purl").is_ok(), |entry| set(entry, "purl", JsonData.String(((entry.field("purl") ?? JsonData.Null).string() ?? "").drop_prefix("pkg:")))) },
	{ name: "an external reference type outside the vocabulary", apply: |bom, pick| edit_list(bom, "components", pick, |entry| entry.field("externalReferences").is_ok(), |entry| set(entry, "externalReferences", JsonData.Array([JsonData.Object([{ name: "type", value: JsonData.String("download") }, { name: "url", value: JsonData.String("https://example.org") }])]))) },
	{ name: "a property without a name", apply: |bom, _| Ok(set(bom, "properties", JsonData.Array([JsonData.Object([{ name: "value", value: JsonData.String("v") }])]))) },
]

## Change the `pick`th item of the top-level array `key` that `chosen` accepts.
edit_list : JsonData, Str, U64, (JsonData -> Bool), (JsonData -> JsonData) -> Try(JsonData, [NotApplicable])
edit_list = |bom, key, pick, chosen, change| {
	if key == "components" {
		subject = (bom.field("metadata") ?? JsonData.Null).field("component") ?? JsonData.Null
		children = (subject.field("components") ?? JsonData.Array([])).array() ?? []
		roots = (bom.field("components") ?? JsonData.Array([])).array() ?? []
		count = flatten(children, "Subject").concat(flatten(roots, "")).keep_if(|entry| chosen(entry.tree)).len()
		if count == 0 {
			return Err(NotApplicable)
		}
		first = mutate_components(children, pick % count, 0, chosen, change)
		last = mutate_components(roots, pick % count, first.seen, chosen, change)
		metadata = set(bom.field("metadata") ?? JsonData.Null, "component", set(subject, "components", JsonData.Array(first.trees)))
		return Ok(set(set(bom, "metadata", metadata), "components", JsonData.Array(last.trees)))
	}
	items = (bom.field(key) ?? JsonData.Array([])).array() ?? []
	count = items.keep_if(chosen).len()
	if count == 0 {
		return Err(NotApplicable)
	}
	wanted = pick % count
	var $seen = 0
	var $edited = []
	for item in items {
		if chosen(item) {
			$edited = $edited.append(if ($seen == wanted) change(item) else item)
			$seen = $seen + 1
		} else {
			$edited = $edited.append(item)
		}
	}
	Ok(set(bom, key, JsonData.Array($edited)))
}

target = Fuzz.target_with({
	name: "sbom-render",
	generator: {
		components: Fuzz.list({ name: Fuzz.str, version: Fuzz.str, producer: Fuzz.u8, producer_name: Fuzz.str, license: Fuzz.u8, sha: Fuzz.u8, identity: Fuzz.u8, download: Fuzz.u8, modified: Fuzz.str, parent: Fuzz.u8, relation: Fuzz.u8, reverse: Fuzz.u8, basis: Fuzz.str }.Fuzz, 6),
		extra: Fuzz.list({ from: Fuzz.u8, to: Fuzz.u8, relation: Fuzz.u8 }.Fuzz, 6),
		filename: Fuzz.str,
		version: Fuzz.str,
		target: Fuzz.u8,
		reason: Fuzz.str,
		violation: Fuzz.u8,
		bom_violation: Fuzz.u8,
		pick: Fuzz.u64,
	}.Fuzz,
	test,
	show: |input| Str.inspect(input),
})

purl : Sbom.Component -> Str
purl = |component| if (!component.package_url.is_empty()) component.package_url else if (component.identity.starts_with("pkg:")) component.identity else ""

expressed : Str -> Str
expressed = |license| if (["NOASSERTION", "NONE"].contains(license)) "" else license

supplied : Str -> Str
supplied = |producer| if (producer.starts_with("Organization: ")) "supplier ${producer.drop_prefix("Organization: ")}" else if (producer.starts_with("Person: ")) "author ${producer.drop_prefix("Person: ")}" else ""

ordered : Sbom.Document -> Sbom.Document
ordered = |document| { ..document, packages_: document.packages_.sort_with(|a, b| Project.bytewise(a.id, b.id)), relationships: document.relationships.sort_with(|a, b| Project.bytewise(Json.to_str(a), Json.to_str(b))) }

flatten : List(JsonData), Str -> List({ tree : JsonData, parent : Str })
flatten = |trees, parent| trees.fold([], |all, tree| all.append({ tree, parent }).concat(flatten((tree.field("components") ?? JsonData.Array([])).array() ?? [], (tree.field("bom-ref") ?? JsonData.Null).string() ?? "")))

claims : List(Sbom.Coverage) -> List({ aggregate : Str, assemblies : List(Str), dependencies : List(Str) })
claims = |coverage| coverage.keep_if(|claim| !claim.component.is_empty()).map(|claim| { aggregate: if (["complete", "verified-empty"].contains(claim.status)) "complete" else if (claim.status == "incomplete") "incomplete" else "unknown", assemblies: if (claim.aspect == "assembly") [claim.component] else [], dependencies: if (claim.aspect == "dependencies") [claim.component] else [] })

projected_evidence : List(Sbom.Coverage) -> List(Str)
projected_evidence = |coverage| {
	var $index = 0.U64
	var $claims = []
	for claim in coverage.keep_if(|entry| !entry.component.is_empty()) {
		aggregate = if (["complete", "verified-empty"].contains(claim.status)) "complete" else if (claim.status == "incomplete") "incomplete" else "unknown"
		aspect = if (claim.aspect == "assembly") "assemblies" else "dependencies"
		$claims = $claims.append({ scope: "cyclonedx:${$index.to_str()}:${aspect}:${claim.component}", component: claim.component, aspect: claim.aspect, status: aggregate, reason: "Upstream CycloneDX composition aggregate ${aggregate}; supplier assertion", contact: "NOASSERTION" })
		$index = $index + 1
	}
	if ($claims.is_empty()) [] else [Json.to_str({ coverage: $claims })]
}

## Independently explore child reachability to detect cycles; each child has
## one assembly parent and the delivered Subject cannot itself be contained.
representable : List(Sbom.Edge) -> Bool
representable = |edges| {
	contains = edges.keep_if(|edge| edge.relation == "contains")
	for edge in contains {
		if edge.to == "Subject" or contains.any(|other| other.to == edge.to and other.from != edge.from) {
			return False
		}
		var $reachable = [edge.to]
		for _ in contains {
			for next in contains {
				if $reachable.contains(next.from) and !$reachable.contains(next.to) {
					$reachable = $reachable.append(next.to)
				}
			}
		}
		if $reachable.contains(edge.from) {
			return False
		}
	}
	True
}

native_file : Sbom.Package
native_file = { kind: "file", copyright: "NOASSERTION", attribution: "NOASSERTION", source_refs: [], id: "File-added", name: "./README", version: "NOASSERTION", supplier: "NOASSERTION", download: "NOASSERTION", license: "NOASSERTION", license_url: "", sha256: "", identity: "", comment: "" }

## Visit every inventory component, including nested assemblies, once. The
## metadata Subject is deliberately excluded from component-only mutations.
mutate_components : List(JsonData), U64, U64, (JsonData -> Bool), (JsonData -> JsonData) -> { trees : List(JsonData), seen : U64 }
mutate_components = |trees, wanted, previous_count, chosen, change| {
	var $seen = previous_count
	var $out = []
	for tree in trees {
		edited = if chosen(tree) {
			selected = $seen == wanted
			$seen = $seen + 1
			if (selected) change(tree) else tree
		} else tree
		children = (edited.field("components") ?? JsonData.Array([])).array() ?? []
		nested = mutate_components(children, wanted, $seen, chosen, change)
		$seen = nested.seen
		$out = $out.append(if (edited.field("components").is_ok()) set(edited, "components", JsonData.Array(nested.trees)) else edited)
	}
	{ trees: $out, seen: $seen }
}
