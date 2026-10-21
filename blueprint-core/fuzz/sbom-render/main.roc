# Render generated inventories as SPDX 3.0.1 and 2.3 and read them back.
app [target] {
	core: "../../main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
import core.CycloneDx
import core.JsonTree
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
	tree = match JsonTree.parse(three) {
		Ok(parsed) => parsed
		Err(problem) => crash "SPDX 3.0.1 rendering is not JSON: ${problem}"
	}
	if "${tree.to_str()}\n" != three {
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
		Err(problem) => crash "render_cyclonedx refused what render accepted: ${problem}"
	}
	bom = match JsonTree.parse(bom_text) {
		Ok(parsed) => parsed
		Err(problem) => crash "CycloneDX rendering is not JSON: ${problem}"
	}
	if "${bom.to_str()}\n" != bom_text {
		crash "CycloneDX rendering is not canonical JSON"
	}
	match CycloneDx.check(bom) {
		Ok(_) => {}
		Err(problem) => crash "CycloneDX rendering fails the schema: ${problem}"
	}
	if Sbom.read_cyclonedx(bom_text) != Ok({ ..wanted, version: "CycloneDX-${CycloneDx.version}" }) {
		crash "CycloneDX rendering reads back differently: ${Str.inspect(Sbom.read_cyclonedx(bom_text))}"
	}
	if seen(bom) != standard(inventory, subject) {
		crash "CycloneDX standard fields differ from the inventory:\n${Str.inspect(seen(bom))}\n${Str.inspect(standard(inventory, subject))}"
	}
	# A consumer of plain CycloneDX, without Blueprint's properties, imports
	# what the projection below says, and nothing else.
	plain = strip_properties(bom)
	if Sbom.read(plain.to_str()) != Ok(projected(inventory, subject, (bom.field("serialNumber") ?? JsonTree.Null).text() ?? "")) {
		crash "plain CycloneDX imports differently:\n${Str.inspect(Sbom.read(plain.to_str()))}\n${Str.inspect(projected(inventory, subject, (bom.field("serialNumber") ?? JsonTree.Null).text() ?? ""))}"
	}
	# Files beside the packages, as generators write them, change nothing in
	# the package graph and are counted in its gaps.
	with_file_3 = add_file_3(tree, context.namespace)
	if Sbom.read(with_file_3.to_str()) != Ok({ ..wanted, gaps: ["1 × file", "1 × relationship to an element that is not a package"] }) {
		crash "SPDX 3.0.1 with a file reads differently: ${Str.inspect(Sbom.read(with_file_3.to_str()))}"
	}
	two_tree = JsonTree.parse(two) ?? crash "SPDX 2.3 rendering is not JSON"
	if Sbom.read(add_file_2(two_tree).to_str()) != Ok({ ..wanted, version: "SPDX-2.3", gaps: ["1 × file", "1 × relationship to a file or snippet"] }) {
		crash "SPDX 2.3 with a file reads differently: ${Str.inspect(Sbom.read(add_file_2(two_tree).to_str()))}"
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
	subject_package = { id: "Subject", name: subject.filename, version: subject.version, supplier: "NOASSERTION", download: subject.url, license: "NOASSERTION", license_url: "", sha256: subject.sha256, identity: "", comment: Json.to_str({ target: subject.target, digest_kind: "final-deliverable-sha256" }) }
	components = inventory.components.map(
		|component| {
			id: component.id,
			name: component.name,
			version: component.version,
			supplier: component.producer,
			download: component.download,
			license: component.license,
			license_url: if (component.license.contains("LicenseRef-")) component.license_url else "",
			sha256: component.sha256,
			identity: if (component.identity.starts_with("pkg:")) component.identity else "",
			comment: Json.to_str({ identity: component.identity, origin: component.origin, target: component.target, modifications: component.modified }),
		},
	)
	evidence = Json.to_str({ profile: Sbom.profile, revision: context.revision, target: subject.target, coverage: inventory.coverage, inspected: inventory.inspected, dispositions: inventory.inputs })
	{ version: "SPDX-${Spdx3.version}", namespace: context.namespace, name: subject.filename, roots: ["Subject"], packages_: components.prepend(subject_package), relationships: inventory.relationships, evidence: [evidence], gaps: [] }
}

## What a reader of standard CycloneDX learns about each component, and the
## subject's digest.
Standard : { subject : Str, components : List({ ref : Str, scope : Str, purl : Str, sha256 : Str, license : Str, supplier : Str, depends : List(Str) }), dependents : List(Str) }

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
	depends = |ref| inventory.relationships.keep_if(|edge| edge.from == ref and (edge.relation == "contains" or edge.relation == "dependsOn")).map(|edge| edge.to).fold([], |all, to| if (all.contains(to)) all else all.append(to))
	{
		subject: subject.sha256,
		components: inventory.components.map(
			|component| {
				ref: component.id,
				scope: if ($needed.contains(component.id)) "required" else if (tools.contains(component.id)) "excluded" else "optional",
				purl: if (component.identity.starts_with("pkg:")) component.identity else "",
				sha256: component.sha256,
				license: if (component.license == "NOASSERTION" or component.license == "NONE") "" else component.license,
				supplier: if (component.producer.starts_with("Organization: ")) "supplier ${component.producer.drop_prefix("Organization: ")}" else if (component.producer.starts_with("Person: ")) "author ${component.producer.drop_prefix("Person: ")}" else "",
				depends: depends(component.id),
			},
		),
		dependents: depends("Subject"),
	}
}

## A BOM with every `properties` member removed, as a plain CycloneDX
## consumer that ignores them sees it.
strip_properties : JsonTree -> JsonTree
strip_properties = |tree|
	match tree {
		Object(members) => JsonTree.Object(members.drop_if(|entry| entry.key == "properties").map(|entry| { key: entry.key, value: strip_properties(entry.value) }))
		Array(items) => JsonTree.Array(items.map(strip_properties))
		_ => tree
	}

## What importing plain CycloneDX gives: each relationship CycloneDX can say,
## `contains` and `dependsOn`, as an unscoped dependency, once per pair; a
## component nothing connects to the subject related to it as `other`; and
## only the facts plain CycloneDX carries.
projected : Sbom.Inventory, Sbom.Subject, Str -> Sbom.Document
projected = |inventory, subject, serial| {
	refs = inventory.components.map(|component| component.id).prepend("Subject")
	said = refs.fold(
		[],
		|all, ref| all.concat(
			inventory.relationships.keep_if(|edge| edge.from == ref and (edge.relation == "contains" or edge.relation == "dependsOn")).map(|edge| edge.to).fold([], |kept, to| if (kept.contains(to)) kept else kept.append(to)).map(|to| { from: ref, to, relation: "dependsOn", scope: "", basis: "CycloneDX dependency; CycloneDX states no lifecycle scope for it" }),
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
	listed = inventory.components.keep_if(|component| !$reached.contains(component.id)).map(|component| { from: "Subject", to: component.id, relation: "other", scope: "", basis: "Listed in the CycloneDX BOM's components; the BOM states no relationship to the described component" })
	scope_of = standard(inventory, subject).components
	{
		version: "CycloneDX-1.7",
		namespace: serial,
		name: subject.filename,
		roots: ["Subject"],
		packages_: inventory.components.map(
			|component| {
				id: component.id,
				name: component.name,
				version: component.version,
				supplier: component.producer,
				download: component.download,
				license: if (component.license == "NONE") "NOASSERTION" else component.license,
				license_url: if (component.license.contains("LicenseRef-") and component.license_url != "NOASSERTION") component.license_url else "",
				sha256: component.sha256,
				identity: if (component.identity.starts_with("pkg:")) component.identity else "",
				comment: Json.to_str({ type: "library", scope: (scope_of.find_first(|entry| entry.ref == component.id) ?? crash "unscoped").scope }),
			},
		).prepend({ id: "Subject", name: subject.filename, version: subject.version, supplier: "NOASSERTION", download: subject.url, license: "NOASSERTION", license_url: "", sha256: subject.sha256, identity: "", comment: Json.to_str({ type: "file", scope: "" }) }),
		relationships: said.concat(listed),
		evidence: [],
		gaps: [],
	}
}

## An SPDX 3.0.1 rendering with a file in its graph and a relationship from
## the subject to it.
add_file_3 : JsonTree, Str -> JsonTree
add_file_3 = |tree, namespace| {
	objects = graph(tree)
	file = JsonTree.Object([{ key: "type", value: JsonTree.Text("software_File") }, { key: "spdxId", value: JsonTree.Text("${namespace}#spdx/file/added") }, { key: "creationInfo", value: JsonTree.Text("_:creationinfo") }, { key: "name", value: JsonTree.Text("./README") }])
	relation = JsonTree.Object([{ key: "type", value: JsonTree.Text("Relationship") }, { key: "spdxId", value: JsonTree.Text("${namespace}#spdx/relationship/added") }, { key: "creationInfo", value: JsonTree.Text("_:creationinfo") }, { key: "from", value: JsonTree.Text("${namespace}#Subject") }, { key: "relationshipType", value: JsonTree.Text("contains") }, { key: "to", value: JsonTree.Array([JsonTree.Text("${namespace}#spdx/file/added")]) }])
	with_graph(tree, objects.concat([file, relation]))
}

## An SPDX 2.3 rendering with a file and the subject's CONTAINS of it.
add_file_2 : JsonTree -> JsonTree
add_file_2 = |tree| {
	file = JsonTree.Object([{ key: "SPDXID", value: JsonTree.Text("SPDXRef-File-added") }, { key: "fileName", value: JsonTree.Text("./README") }, { key: "checksums", value: JsonTree.Array([JsonTree.Object([{ key: "algorithm", value: JsonTree.Text("SHA1") }, { key: "checksumValue", value: JsonTree.Text(Str.join_with(List.repeat("b", 40), "")) }])]) }])
	relation = JsonTree.Object([{ key: "spdxElementId", value: JsonTree.Text("SPDXRef-Subject") }, { key: "relatedSpdxElement", value: JsonTree.Text("SPDXRef-File-added") }, { key: "relationshipType", value: JsonTree.Text("CONTAINS") }])
	with_files = set(tree, "files", JsonTree.Array([file]))
	set(with_files, "relationships", JsonTree.Array(((tree.field("relationships") ?? JsonTree.Array([])).items() ?? []).append(relation)))
}

## The same fields read from a BOM with nothing but the CycloneDX schema.
seen : JsonTree -> Standard
seen = |bom| {
	text_of = |tree, key| (tree.field(key) ?? JsonTree.Null).text() ?? ""
	list_of = |tree, key| (tree.field(key) ?? JsonTree.Array([])).items() ?? []
	sha = |tree| list_of(tree, "hashes").find_first(|hash| text_of(hash, "alg") == "SHA-256").map_ok(|hash| text_of(hash, "content")) ?? ""
	dependencies = list_of(bom, "dependencies")
	depends = |ref| dependencies.find_first(|entry| text_of(entry, "ref") == ref).map_ok(|entry| list_of(entry, "dependsOn").map(|item| item.text() ?? "")) ?? ["<no dependency entry>"]
	{
		subject: sha((bom.field("metadata") ?? JsonTree.Null).field("component") ?? JsonTree.Null),
		components: list_of(bom, "components").map(
			|entry| {
				ref: text_of(entry, "bom-ref"),
				scope: text_of(entry, "scope"),
				purl: text_of(entry, "purl"),
				sha256: sha(entry),
				license: list_of(entry, "licenses").first().map_ok(|choice| text_of(choice, "expression")) ?? "",
				supplier: match entry.field("supplier") {
					Ok(supplier) => "supplier ${text_of(supplier, "name")}"
					Err(_) => list_of(entry, "authors").first().map_ok(|author| "author ${text_of(author, "name")}") ?? ""
				},
				depends: depends(text_of(entry, "bom-ref")),
			},
		),
		dependents: depends("Subject"),
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
		coverage: [{ scope: "all", status: if (count == 0) "verified-empty" else "incomplete", reason: filled(input.reason, "Generated coverage"), contact: "https://example.org/support" }],
		inputs: [],
	}
}

## Violations

Members : List({ key : Str, value : JsonTree })

## The `@graph` objects of a rendering.
graph : JsonTree -> List(JsonTree)
graph = |tree| (tree.field("@graph") ?? JsonTree.Array([])).items() ?? []

with_graph : JsonTree, List(JsonTree) -> JsonTree
with_graph = |tree, objects| set(tree, "@graph", JsonTree.Array(objects))

set : JsonTree, Str, JsonTree -> JsonTree
set = |tree, key, value|
	match tree {
		Object(members) => if (members.any(|entry| entry.key == key)) JsonTree.Object(members.map(|entry| if (entry.key == key) { key, value } else entry)) else JsonTree.Object(members.append({ key, value }))
		_ => tree
	}

remove : JsonTree, Str -> JsonTree
remove = |tree, key|
	match tree {
		Object(members) => JsonTree.Object(members.drop_if(|entry| entry.key == key))
		_ => tree
	}

## Change the `pick`th object of `@graph` that `chosen` accepts, if any.
edit_one : JsonTree, U64, (JsonTree -> Bool), (JsonTree -> JsonTree) -> Try(JsonTree, [NotApplicable])
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

of_type : List(Str) -> (JsonTree -> Bool)
of_type = |types| |object| types.contains((object.field("type") ?? JsonTree.Null).text() ?? "")

elements : JsonTree -> Bool
elements = |object| object.field("spdxId").is_ok()

relationships : List(Str)
relationships = ["Relationship", "LifecycleScopedRelationship"]

## Each breaks a rule the SPDX 3.0.1 schema or model states.
violations : List({ name : Str, apply : JsonTree, U64 -> Try(JsonTree, [NotApplicable]) })
violations = [
	{ name: "an element without creationInfo", apply: |tree, pick| edit_one(tree, pick, elements, |object| remove(object, "creationInfo")) },
	{ name: "a relationship to an element outside the document", apply: |tree, pick| edit_one(tree, pick, of_type(relationships), |object| set(object, "to", JsonTree.Array([JsonTree.Text("${context.namespace}#missing")]))) },
	{ name: "a relationship with no target", apply: |tree, pick| edit_one(tree, pick, of_type(relationships), |object| set(object, "to", JsonTree.Array([]))) },
	{ name: "an SPDX 2 relationship type", apply: |tree, pick| edit_one(tree, pick, of_type(relationships), |object| set(object, "relationshipType", JsonTree.Text("DEPENDS_ON"))) },
	{ name: "a relationship without relationshipType", apply: |tree, pick| edit_one(tree, pick, of_type(relationships), |object| remove(object, "relationshipType")) },
	{ name: "an SPDX 2 package property", apply: |tree, pick| edit_one(tree, pick, of_type(["software_Package"]), |object| set(object, "versionInfo", JsonTree.Text("1"))) },
	{ name: "a single value where an array is required", apply: |tree, pick| edit_one(tree, pick, of_type(relationships), |object| set(object, "to", (object.field("to") ?? JsonTree.Array([])).items().map_ok(|items| items.first() ?? JsonTree.Null) ?? JsonTree.Null)) },
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
	{ name: "a blank-node spdxId", apply: |tree, pick| edit_one(tree, pick, elements, |object| set(object, "spdxId", JsonTree.Text("_:element"))) },
	{ name: "an unknown class", apply: |tree, pick| edit_one(tree, pick, of_type(["software_Package"]), |object| set(object, "type", JsonTree.Text("software_Packages"))) },
	{ name: "a 3.0.0 context", apply: |tree, _| Ok(set(tree, "@context", JsonTree.Text("https://spdx.org/rdf/3.0.0/spdx-context.jsonld"))) },
	{ name: "a member beside @context and @graph", apply: |tree, _| Ok(set(tree, "spdxVersion", JsonTree.Text("SPDX-3.0"))) },
	{ name: "a specVersion other than 3.0.1", apply: |tree, pick| edit_one(tree, pick, of_type(["CreationInfo"]), |object| set(object, "specVersion", JsonTree.Text("3.0.0"))) },
	{ name: "an impossible creation date", apply: |tree, pick| edit_one(tree, pick, of_type(["CreationInfo"]), |object| set(object, "created", JsonTree.Text("2026-02-30T00:00:00Z"))) },
	{ name: "a non-UTC creation date", apply: |tree, pick| edit_one(tree, pick, of_type(["CreationInfo"]), |object| set(object, "created", JsonTree.Text("2026-10-21T00:00:00+01:00"))) },
	{ name: "a truncated SHA-256", apply: |tree, pick| edit_one(tree, pick, |object| object.field("verifiedUsing").is_ok(), |object| set(object, "verifiedUsing", JsonTree.Array([JsonTree.Object([{ key: "type", value: JsonTree.Text("Hash") }, { key: "algorithm", value: JsonTree.Text("sha256") }, { key: "hashValue", value: JsonTree.Text("abc") }])]))) },
	{ name: "an invalid license expression", apply: |tree, pick| edit_one(tree, pick, of_type(["simplelicensing_LicenseExpression"]), |object| set(object, "simplelicensing_licenseExpression", JsonTree.Text("MIT OR"))) },
	{ name: "a license list version that is not SemVer", apply: |tree, pick| edit_one(tree, pick, of_type(["simplelicensing_LicenseExpression"]), |object| set(object, "simplelicensing_licenseListVersion", JsonTree.Text("3.26"))) },
	{ name: "a declared license that is a package", apply: |tree, pick| edit_one(tree, pick, |object| (object.field("relationshipType") ?? JsonTree.Null) == JsonTree.Text("hasDeclaredLicense"), |object| set(object, "to", JsonTree.Array([object.field("from") ?? JsonTree.Null]))) },
	{ name: "a supplier that is a package", apply: |tree, pick| edit_one(tree, pick, |object| object.field("suppliedBy").is_ok(), |object| set(object, "suppliedBy", object.field("spdxId") ?? JsonTree.Null)) },
	{ name: "a lifecycle scope outside the vocabulary", apply: |tree, pick| edit_one(tree, pick, of_type(["LifecycleScopedRelationship"]), |object| set(object, "scope", JsonTree.Text("compile"))) },
	{ name: "a creationInfo that names no CreationInfo", apply: |tree, pick| edit_one(tree, pick, elements, |object| set(object, "creationInfo", JsonTree.Text("_:elsewhere"))) },
	{ name: "a number where text is required", apply: |tree, pick| edit_one(tree, pick, of_type(["software_Package"]), |object| set(object, "name", JsonTree.Num(1))) },
]

## Each breaks a rule the CycloneDX 1.7 schema or specification states.
bom_violations : List({ name : Str, apply : JsonTree, U64 -> Try(JsonTree, [NotApplicable]) })
bom_violations = [
	{ name: "another bomFormat", apply: |bom, _| Ok(set(bom, "bomFormat", JsonTree.Text("SPDX"))) },
	{ name: "a 1.6 specVersion", apply: |bom, _| Ok(set(bom, "specVersion", JsonTree.Text("1.6"))) },
	{ name: "a BOM version of 0", apply: |bom, _| Ok(set(bom, "version", JsonTree.Num(0))) },
	{ name: "a fractional BOM version", apply: |bom, _| Ok(set(bom, "version", JsonTree.Num(1.5))) },
	{ name: "an uppercase serial number", apply: |bom, _| Ok(set(bom, "serialNumber", JsonTree.Text(((bom.field("serialNumber") ?? JsonTree.Null).text() ?? "").replace_each("a", "A").replace_each("b", "B").replace_each("c", "C").replace_each("d", "D").replace_each("e", "E").replace_each("f", "F").replace_each("8", "F")))) },
	{ name: "a services section", apply: |bom, _| Ok(set(bom, "services", JsonTree.Array([]))) },
	{ name: "a timestamp without a zone", apply: |bom, _| Ok(set(bom, "metadata", set(bom.field("metadata") ?? JsonTree.Null, "timestamp", JsonTree.Text("2026-10-21T00:00:00")))) },
	{ name: "a dependency on an undeclared bom-ref", apply: |bom, pick| edit_list(bom, "dependencies", pick, |_| True, |entry| set(entry, "dependsOn", JsonTree.Array([JsonTree.Text("missing")]))) },
	{ name: "a dependency entry for an undeclared bom-ref", apply: |bom, pick| edit_list(bom, "dependencies", pick, |_| True, |entry| set(entry, "ref", JsonTree.Text("missing"))) },
	{ name: "a repeated dependsOn reference", apply: |bom, pick| edit_list(bom, "dependencies", pick, |entry| entry.field("dependsOn").is_ok(), |entry| set(entry, "dependsOn", JsonTree.Array(((entry.field("dependsOn") ?? JsonTree.Array([])).items() ?? []).concat(((entry.field("dependsOn") ?? JsonTree.Array([])).items() ?? []).take_first(1))))) },
	{ name: "a duplicate bom-ref", apply: |bom, pick| edit_list(bom, "components", pick, |_| True, |entry| set(entry, "bom-ref", JsonTree.Text("Subject"))) },
	{ name: "a component without a name", apply: |bom, pick| edit_list(bom, "components", pick, |_| True, |entry| remove(entry, "name")) },
	{ name: "a component type outside the vocabulary", apply: |bom, pick| edit_list(bom, "components", pick, |_| True, |entry| set(entry, "type", JsonTree.Text("crate"))) },
	{ name: "a scope outside the vocabulary", apply: |bom, pick| edit_list(bom, "components", pick, |_| True, |entry| set(entry, "scope", JsonTree.Text("build"))) },
	{ name: "an unknown component property", apply: |bom, pick| edit_list(bom, "components", pick, |_| True, |entry| set(entry, "versionInfo", JsonTree.Text("1"))) },
	{ name: "a truncated SHA-256", apply: |bom, pick| edit_list(bom, "components", pick, |entry| entry.field("hashes").is_ok(), |entry| set(entry, "hashes", JsonTree.Array([JsonTree.Object([{ key: "alg", value: JsonTree.Text("SHA-256") }, { key: "content", value: JsonTree.Text("abc") }])]))) },
	{ name: "a hash algorithm outside the vocabulary", apply: |bom, pick| edit_list(bom, "components", pick, |entry| entry.field("hashes").is_ok(), |entry| set(entry, "hashes", JsonTree.Array([JsonTree.Object([{ key: "alg", value: JsonTree.Text("SHA256") }, { key: "content", value: JsonTree.Text(Str.join_with(List.repeat("a", 64), "")) }])]))) },
	{ name: "an invalid license expression", apply: |bom, pick| edit_list(bom, "components", pick, |entry| entry.field("licenses").is_ok(), |entry| set(entry, "licenses", JsonTree.Array([JsonTree.Object([{ key: "expression", value: JsonTree.Text("MIT AND") }])]))) },
	{ name: "a purl without its scheme", apply: |bom, pick| edit_list(bom, "components", pick, |entry| entry.field("purl").is_ok(), |entry| set(entry, "purl", JsonTree.Text(((entry.field("purl") ?? JsonTree.Null).text() ?? "").drop_prefix("pkg:")))) },
	{ name: "an external reference type outside the vocabulary", apply: |bom, pick| edit_list(bom, "components", pick, |entry| entry.field("externalReferences").is_ok(), |entry| set(entry, "externalReferences", JsonTree.Array([JsonTree.Object([{ key: "type", value: JsonTree.Text("download") }, { key: "url", value: JsonTree.Text("https://example.org") }])]))) },
	{ name: "a property without a name", apply: |bom, _| Ok(set(bom, "properties", JsonTree.Array([JsonTree.Object([{ key: "value", value: JsonTree.Text("v") }])]))) },
]

## Change the `pick`th item of the top-level array `key` that `chosen` accepts.
edit_list : JsonTree, Str, U64, (JsonTree -> Bool), (JsonTree -> JsonTree) -> Try(JsonTree, [NotApplicable])
edit_list = |bom, key, pick, chosen, change| {
	items = (bom.field(key) ?? JsonTree.Array([])).items() ?? []
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
	Ok(set(bom, key, JsonTree.Array($edited)))
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
