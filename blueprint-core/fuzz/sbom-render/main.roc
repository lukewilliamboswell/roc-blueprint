# Render generated inventories as SPDX 3.0.1 and 2.3 and read them back.
app [target] {
	core: "../../main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
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
##   rule of the SPDX 3.0.1 model in it, so the validator is not vacuous.
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
	{ version: "SPDX-${Spdx3.version}", namespace: context.namespace, roots: ["Subject"], packages_: components.prepend(subject_package), relationships: inventory.relationships }
}

context : Sbom.Context
context = { namespace: "https://example.org/sbom/fuzz/revision-1", revision: "1", created: "2026-10-21T00:00:00Z", author: "Organization: Fuzz producers", generator: "Tool: sbom-render-fuzz" }

## Free-form text: arbitrary, but never empty where a value is required.
filled : Str, Str -> Str
filled = |text, fallback| if (text.trim().is_empty()) fallback else text

Raw : { name : Str, version : Str, producer : U8, producer_name : Str, license : U8, sha : U8, identity : U8, download : U8, modified : Str, parent : U8, relation : U8, reverse : U8, basis : Str }

Input : { components : List(Raw), extra : List({ from : U8, to : U8, relation : U8 }), filename : Str, version : Str, target : U8, reason : Str, violation : U8, pick : U64 }

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
relationship : U8 -> { relation : Str, scope : Str }
relationship = |choice| {
	options = [("contains", ""), ("dependsOn", ""), ("dependsOn", "build"), ("dependsOn", "test"), ("dependsOn", "development"), ("dependsOn", "runtime"), ("generates", ""), ("patchedBy", ""), ("hasVariant", ""), ("copiedTo", ""), ("other", "")]
	(relation, scope) = options.get(choice.to_u64() % options.len()) ?? ("contains", "")
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
		chosen = licenses.get(raw.license.to_u64() % licenses.len()) ?? { expression: "MIT", url: "" }
		$components = $components.append({
			id,
			name: filled(raw.name, "component"),
			producer: match raw.producer % 3 {
				0 => "NOASSERTION"
				1 => "Organization: ${filled(raw.producer_name, "Upstream")}"
				_ => "Person: ${filled(raw.producer_name, "Maintainer")}"
			},
			version: filled(raw.version, "0"),
			identity: match raw.identity % 3 {
				0 => "pkg:generic/${id}@${(raw.version.to_utf8().len()).to_str()}"
				1 => "https://example.org/source/${id}"
				_ => "urn:example:${id}"
			},
			download: if (raw.download % 2 == 0) "NOASSERTION" else "https://example.org/download/${id}.tar.gz",
			sha256: if (raw.sha % 2 == 0) "" else Crypto.SHA256.hash(raw.name.to_utf8()).to_hex(),
			license: chosen.expression,
			license_url: chosen.url,
			modified: raw.modified,
			target: if (input.target % 2 == 0) "x86_64-linux" else "",
			origin: "reviewed",
		})
		parent = raw.parent.to_u64() % (index + 1)
		other = if (parent == 0) "Subject" else "c${(parent - 1).to_str()}"
		stated = relationship(raw.relation)
		(from, to) = if (raw.reverse % 2 == 0) (other, id) else (id, other)
		$edges = $edges.append({ from, to, relation: stated.relation, scope: stated.scope, basis: filled(raw.basis, "Generated relationship") })
	}
	count = $components.len()
	nodes = $components.map(|component| component.id).prepend("Subject")
	for extra in input.extra {
		from = nodes.get(extra.from.to_u64() % (count + 1)) ?? "Subject"
		to = nodes.get(extra.to.to_u64() % (count + 1)) ?? "Subject"
		stated = relationship(extra.relation)
		duplicate = $edges.any(|edge| edge.from == from and edge.to == to and edge.relation == stated.relation and edge.scope == stated.scope)
		if from != to and !duplicate {
			$edges = $edges.append({ from, to, relation: stated.relation, scope: stated.scope, basis: "Extra generated relationship" })
		}
	}
	{
		profile: Sbom.profile,
		imported_documents: [],
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
		pick: Fuzz.u64,
	}.Fuzz,
	test,
	show: |input| Str.inspect(input),
})
