import JsonTree
import Lookup
import SbomLicenses
import Spdx3

## CycloneDX 1.7 JSON, checked against the published schema
## (https://github.com/CycloneDX/specification/blob/1.7.2/schema/bom-1.7.schema.json)
## for the objects below.
##
## A BOM holds `bomFormat` "CycloneDX" and `specVersion` "1.7". Each object
## holds only its definition's properties, with the kinds, enumerations,
## patterns and required members the schema gives them. Beyond the schema
## this applies rules the specification states in prose: every `bom-ref` is
## unique within the BOM, a dependency names components by `bom-ref`, a
## license expression is a valid SPDX expression, a hash has its algorithm's
## length, and a serial number is an RFC 4122 URN. Services, compositions,
## vulnerabilities, formulation and the other top-level sections are outside
## this profile and rejected rather than skimmed.
CycloneDx := [].{
	format : Str
	format = "CycloneDX"

	version : Str
	version = "1.7"

	validate : Str -> Try(JsonTree, Str)
	validate = |text| {
		tree = JsonTree.parse(text)?
		CycloneDx.check(tree)?
		Ok(tree)
	}

	## `validate` for a document already parsed.
	check : JsonTree -> Try({}, Str)
	check = |tree| {
		check_object(tree, "bom")?
		if tree.field("bomFormat") != Ok(JsonTree.Text(format)) or tree.field("specVersion") != Ok(JsonTree.Text(version)) {
			return Err("a CycloneDX ${version} BOM names bomFormat ${format} and specVersion ${version}")
		}
		refs = Lookup.index(bom_refs(tree).map(|ref| { key: ref, value: ref }))
		match Lookup.repeated(refs) {
			[] => {}
			[ref, ..] => return Err("duplicate bom-ref ${ref}")
		}
		for dependency in (tree.field("dependencies") ?? JsonTree.Array([])).items() ?? [] {
			named = [(dependency.field("ref") ?? JsonTree.Null).text() ?? ""].concat(((dependency.field("dependsOn") ?? JsonTree.Array([])).items() ?? []).map(|item| item.text() ?? ""))
			for ref in named {
				if !Lookup.contains(refs, ref) {
					return Err("dependency names ${ref}, which no component in the BOM declares")
				}
			}
			depends = ((dependency.field("dependsOn") ?? JsonTree.Array([])).items() ?? []).map(|item| item.text() ?? "")
			if Lookup.repeated(Lookup.index(depends.map(|ref| { key: ref, value: ref }))) != [] {
				return Err("dependsOn repeats a reference")
			}
		}
		dependents = ((tree.field("dependencies") ?? JsonTree.Array([])).items() ?? []).map(|dependency| (dependency.field("ref") ?? JsonTree.Null).text() ?? "")
		if Lookup.repeated(Lookup.index(dependents.map(|ref| { key: ref, value: ref }))) != [] {
			return Err("two dependency entries name one component")
		}
		Ok({})
	}

	## An RFC 3339 `date-time`, as the schema's format names it.
	date_time : Str -> Bool
	date_time = |text| {
		bytes = text.to_utf8()
		if bytes.len() < 20 {
			return False
		}
		base = Str.from_utf8_lossy(bytes.take_first(19))
		rest = Str.from_utf8_lossy(bytes.drop_first(19))
		zone = if rest.starts_with(".") {
			digits = rest.drop_prefix(".").to_utf8()
			count = digits.find_first_index(|byte| byte < '0' or byte > '9') ?? digits.len()
			if (count == 0) "!" else Str.from_utf8_lossy(digits.drop_first(count))
		} else {
			rest
		}
		offset_ok = zone == "Z" or match zone.to_utf8() {
			[sign, h1, h2, ':', m1, m2] => (sign == '+' or sign == '-') and [h1, h2, m1, m2].all(|byte| byte >= '0' and byte <= '9') and (h1 - '0') * 10 + (h2 - '0') <= 23 and (m1 - '0') * 10 + (m2 - '0') <= 59
			_ => False
		}
		offset_ok and Spdx3.timestamp("${base}Z")
	}

	## Each enumeration this profile checks, by its path in the schema's
	## `definitions` (`#/definitions/NAME`, then `properties` and `items`).
	vocabularies : List({ path : List(Str), values : List(Str) })
	vocabularies = [
		{ path: ["component", "type"], values: component_types },
		{ path: ["component", "scope"], values: scopes },
		{ path: ["hash-alg"], values: hash_algorithms },
		{ path: ["externalReference", "type"], values: reference_types },
	]

	## The members of each object this profile reads, by definition name, so a
	## test can hold them to the schema.
	objects : List({ definition : Str, members : List(Str) })
	objects = ["metadata", "component", "hash", "externalReference", "dependency", "property", "organizationalEntity", "organizationalContact"].map(|name| { definition: name, members: (class(name) ?? []).map(|property| property.name) })
}

component_types = ["application", "framework", "library", "container", "platform", "operating-system", "device", "device-driver", "firmware", "file", "machine-learning-model", "data", "cryptographic-asset"]

scopes = ["required", "optional", "excluded"]

hash_algorithms = ["MD5", "SHA-1", "SHA-256", "SHA-384", "SHA-512", "SHA3-256", "SHA3-384", "SHA3-512", "BLAKE2b-256", "BLAKE2b-384", "BLAKE2b-512", "BLAKE3", "Streebog-256", "Streebog-512"]

reference_types = ["vcs", "issue-tracker", "website", "advisories", "bom", "mailing-list", "social", "chat", "documentation", "support", "source-distribution", "distribution", "distribution-intake", "license", "build-meta", "build-system", "release-notes", "security-contact", "model-card", "log", "configuration", "evidence", "formulation", "attestation", "threat-model", "adversary-model", "risk-assessment", "vulnerability-assertion", "exploitability-statement", "pentest-report", "static-analysis-report", "dynamic-analysis-report", "runtime-analysis-report", "component-analysis-report", "maturity-report", "certification-report", "codified-infrastructure", "quality-metrics", "poam", "electronic-signature", "digital-signature", "rfc-9116", "patent", "patent-family", "patent-assertion", "citation", "other"]

phases = ["design", "pre-build", "build", "post-build", "operations", "discovery", "decommission"]

Kind : [Text, Bool, Integer, DateTime, Ref, Iri, Purl, Serial, Version, Expression, Enum(List(Str)), Inline(Str), Unsupported]

Property : { name : Str, kind : Kind, count : [One, Many], required : Bool }

one : Str, Kind -> Property
one = |name, kind| { name, kind, count: One, required: False }

many : Str, Kind -> Property
many = |name, kind| { name, kind, count: Many, required: False }

needs : Property -> Property
needs = |property| { ..property, required: True }

## The properties of each object, from the 1.7 schema's definitions. A
## property the schema allows but this profile does not read is Unsupported.
class : Str -> Try(List(Property), Str)
class = |name|
	match name {
		"bom" => Ok([one("$schema", Text), needs(one("bomFormat", Enum(["CycloneDX"]))), needs(one("specVersion", Text)), one("serialNumber", Serial), one("version", Integer), one("metadata", Inline("metadata")), many("components", Inline("component")), many("dependencies", Inline("dependency")), many("properties", Inline("property"))].concat(["services", "externalReferences", "compositions", "vulnerabilities", "annotations", "formulation", "declarations", "definitions", "citations", "signature"].map(|unread| one(unread, Unsupported))))
		"metadata" => Ok([one("timestamp", DateTime), many("lifecycles", Inline("lifecycle")), one("tools", Inline("tools")), one("manufacturer", Inline("organizationalEntity")), many("authors", Inline("organizationalContact")), one("component", Inline("component")), one("supplier", Inline("organizationalEntity")), many("properties", Inline("property"))].concat(["manufacture", "licenses", "distributionConstraints"].map(|unread| one(unread, Unsupported))))
		"lifecycle" => Ok([needs(one("phase", Enum(phases)))])
		"tools" => Ok([many("components", Inline("component")), one("services", Unsupported)])
		"component" => Ok(
			[
				needs(one("type", Enum(component_types))),
				one("mime-type", Text),
				one("bom-ref", Ref),
				one("supplier", Inline("organizationalEntity")),
				one("manufacturer", Inline("organizationalEntity")),
				many("authors", Inline("organizationalContact")),
				one("publisher", Text),
				one("group", Text),
				needs(one("name", Text)),
				one("version", Version),
				one("isExternal", Bool),
				one("description", Text),
				one("scope", Enum(scopes)),
				many("hashes", Inline("hash")),
				many("licenses", Inline("license")),
				one("copyright", Text),
				one("cpe", Text),
				one("purl", Purl),
				many("externalReferences", Inline("externalReference")),
				many("components", Inline("component")),
				many("properties", Inline("property")),
			].concat(["author", "versionRange", "patentAssertions", "omniborId", "swhid", "swid", "modified", "pedigree", "evidence", "releaseNotes", "modelCard", "data", "cryptoProperties", "tags", "signature"].map(|unread| one(unread, Unsupported))),
		)
		"hash" => Ok([needs(one("alg", Enum(hash_algorithms))), needs(one("content", Text))])
		"license" => Ok([needs(one("expression", Expression))].concat(["expressionDetails", "acknowledgement", "bom-ref", "licensing", "properties"].map(|unread| one(unread, Unsupported))))
		"externalReference" => Ok([needs(one("url", Iri)), one("comment", Text), needs(one("type", Enum(reference_types))), many("hashes", Inline("hash")), many("properties", Inline("property"))])
		"dependency" => Ok([needs(one("ref", Ref)), many("dependsOn", Ref), many("provides", Unsupported)])
		"property" => Ok([needs(one("name", Text)), one("value", Text)])
		"organizationalEntity" => Ok([one("bom-ref", Ref), one("name", Text), many("url", Iri), many("contact", Inline("organizationalContact")), one("address", Unsupported)])
		"organizationalContact" => Ok([one("bom-ref", Ref), one("name", Text), one("email", Text), one("phone", Text)])
		_ => Err("CycloneDX object ${name} is outside this profile")
	}

check_object : JsonTree, Str -> Try({}, Str)
check_object = |tree, kind| {
	properties = class(kind)?
	match tree {
		Object(_) => {}
		_ => return Err("${kind} must be an object")
	}
	for key in tree.keys() {
		match properties.find_first(|property| property.name == key) {
			Ok(property) =>
				match property.kind {
					Unsupported => return Err("${kind}.${key} is outside this profile")
					_ => {}
				}
			Err(_) => return Err("${kind} has no property ${key} in CycloneDX ${CycloneDx.version}")
		}
	}
	for property in properties {
		match tree.field(property.name) {
			Err(Missing) =>
				if property.required {
					return Err("${kind} requires ${property.name}")
				}
			Ok(value) =>
				match (property.count, value) {
					(One, _) => check_value(value, property.kind).map_err(|problem| "${kind}.${property.name}: ${problem}")?
					(Many, Array(values)) =>
						for item in values {
							check_value(item, property.kind).map_err(|problem| "${kind}.${property.name}: ${problem}")?
						}
					(Many, _) => return Err("${kind}.${property.name} must be an array")
				}
		}
	}
	if kind == "hash" {
		algorithm = (tree.field("alg") ?? JsonTree.Null).text() ?? ""
		content = (tree.field("content") ?? JsonTree.Null).text() ?? ""
		expected = match algorithm {
			"MD5" => 32
			"SHA-1" => 40
			"SHA-256" | "SHA3-256" | "BLAKE2b-256" | "BLAKE3" | "Streebog-256" => 64
			"SHA-384" | "SHA3-384" | "BLAKE2b-384" => 96
			_ => 128
		}
		if content.to_utf8().len() != expected or !content.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f') or (byte >= 'A' and byte <= 'F')) {
			return Err("${algorithm} hash is not ${expected.to_str()} hex digits")
		}
	}
	Ok({})
}

check_value : JsonTree, Kind -> Try({}, Str)
check_value = |value, kind|
	match (kind, value) {
		(Text, Text(_)) => Ok({})
		(Bool, Bool(_)) => Ok({})
		# JSON Schema draft-07 counts any number with no fractional part as an integer.
		(Integer, Num(number)) => if (number >= 1 and Dec.to_str(number).ends_with(".0") and Dec.to_str(number).drop_suffix(".0").to_utf8().all(|byte| byte >= '0' and byte <= '9')) Ok({}) else Err("not an integer of at least 1")
		(DateTime, Text(text)) => if (CycloneDx.date_time(text)) Ok({}) else Err("not an RFC 3339 date-time")
		(Ref, Text(text)) => if (!text.is_empty() and !text.starts_with("urn:cdx:")) Ok({}) else Err("a bom-ref is non-empty and is not a BOM-Link")
		(Iri, Text(text)) => if (!text.is_empty() and !text.to_utf8().any(|byte| byte <= 32 or byte == 127)) Ok({}) else Err("not an IRI reference")
		(Purl, Text(text)) => if (text.starts_with("pkg:") and text.drop_prefix("pkg:").contains("/") and !text.to_utf8().any(|byte| byte <= 32)) Ok({}) else Err("not a package URL")
		(Serial, Text(text)) => if (serial(text)) Ok({}) else Err("not a urn:uuid serial number")
		(Version, Text(text)) => if (text.to_utf8().len() <= 1024) Ok({}) else Err("version longer than 1024 bytes")
		(Expression, Text(text)) => if (SbomLicenses.expression(text)) Ok({}) else Err("invalid SPDX license expression ${Json.to_str(text)}")
		(Enum(allowed), Text(text)) => if (allowed.contains(text)) Ok({}) else Err("${text} is not a permitted value")
		(Inline(name), _) => check_object(value, name)
		_ => Err("wrong JSON kind")
	}

## The schema's pattern `^urn:uuid:` then 8-4-4-4-12 lowercase hex digits.
serial : Str -> Bool
serial = |text|
	match text.drop_prefix("urn:uuid:").split_on("-") {
		[a, b, c, d, e] if text.starts_with("urn:uuid:") => [(a, 8), (b, 4), (c, 4), (d, 4), (e, 12)].all(|(group, len)| group.to_utf8().len() == len and group.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f')))
		_ => False
	}

## Every `bom-ref` the BOM declares, wherever it is.
bom_refs : JsonTree -> List(Str)
bom_refs = |tree|
	match tree {
		Object(members) => members.fold([], |all, member| all.concat(if (member.key == "bom-ref") [member.value.text() ?? ""] else if (member.key == "dependencies" or member.key == "properties") [] else bom_refs(member.value)))
		Array(items) => items.fold([], |all, item| all.concat(bom_refs(item)))
		_ => []
	}

minimal : Str
minimal = "{\"bomFormat\":\"CycloneDX\",\"specVersion\":\"1.7\",\"serialNumber\":\"urn:uuid:3e671687-395b-41f5-a30f-a58921a69b79\",\"version\":1,\"metadata\":{\"timestamp\":\"2026-10-21T00:00:00Z\",\"component\":{\"type\":\"file\",\"bom-ref\":\"Subject\",\"name\":\"a\",\"hashes\":[{\"alg\":\"SHA-256\",\"content\":\"${Str.join_with(List.repeat("a", 64), "")}\"}]}},\"components\":[{\"type\":\"library\",\"bom-ref\":\"p\",\"name\":\"p\",\"licenses\":[{\"expression\":\"MIT\"}],\"purl\":\"pkg:generic/p@1\"}],\"dependencies\":[{\"ref\":\"Subject\",\"dependsOn\":[\"p\"]},{\"ref\":\"p\"}]}"

expect CycloneDx.validate(minimal).is_ok()
expect CycloneDx.validate(minimal.replace_each("\"1.7\"", "\"1.6\"")).is_err()
expect CycloneDx.validate(minimal.replace_each("\"dependsOn\":[\"p\"]", "\"dependsOn\":[\"q\"]")).is_err()
expect CycloneDx.validate(minimal.replace_each("\"dependsOn\":[\"p\"]", "\"dependsOn\":[\"p\",\"p\"]")).is_err()
expect CycloneDx.validate(minimal.replace_each("\"bom-ref\":\"p\"", "\"bom-ref\":\"Subject\"")).is_err()
expect CycloneDx.validate(minimal.replace_each("\"MIT\"", "\"MIT OR\"")).is_err()
expect CycloneDx.validate(minimal.replace_each("\"content\":\"a", "\"content\":\"")).is_err()
expect CycloneDx.validate(minimal.replace_each("\"type\":\"library\"", "\"type\":\"crate\"")).is_err()
expect CycloneDx.validate(minimal.replace_each("\"version\":1", "\"version\":0")).is_err()
expect CycloneDx.validate(minimal.replace_each("\"version\":1", "\"version\":1.5")).is_err()
expect CycloneDx.validate(minimal.replace_each("urn:uuid:3e67", "urn:uuid:3E67")).is_err()
expect CycloneDx.validate(minimal.replace_each("\"purl\"", "\"pedigree\"")).is_err()
expect CycloneDx.validate(minimal.replace_each("\"components\":[", "\"services\":[],\"components\":[")).is_err()
expect CycloneDx.date_time("2026-10-21T00:00:00Z") and CycloneDx.date_time("2026-10-21T10:00:00.25+10:00") and !CycloneDx.date_time("2026-10-21T00:00:00") and !CycloneDx.date_time("2026-02-30T00:00:00Z") and !CycloneDx.date_time("2026-10-21T00:00:00.Z")
