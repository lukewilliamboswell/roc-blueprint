import Spec
import Lock
import Project
import Value
import SbomLicenses

## Provider-neutral, pure SPDX inventory. No filesystem, Store or provider effects.
## Composition is reviewed data; locked references resolve identities from Lock.
Sbom := [].{
	Component : { id : Str, name : Str, producer : Str, version : Str, identity : Str, download : Str, sha256 : Str, license : Str, license_url : Str, modified : Str, target : Str, origin : Str }
	Edge : { from : Str, to : Str, relation : Str, basis : Str }
	Coverage : { scope : Str, status : Str, reason : Str, contact : Str }
	Disposition : { input : Str, component : Str, reason : Str }
	Imported : { id : Str, url : Str, sha256 : Str, namespace : Str, target : Str, document : Str, relation : Str, basis : Str, contact : Str }
	ImportedPackage : { spdxid : Str, name : Str, versionInfo : Str, supplier : Str, downloadLocation : Str, licenseDeclared : Str, checksums : List({ algorithm : Str, checksumValue : Str }) }
	ImportedDocument : { spdxVersion : Str, spdxid : Str, documentNamespace : Str, entries : List(ImportedPackage), hasExtractedLicensingInfos : Try(List({ licenseId : Str, seeAlsos : List(Str) }), [Missing]), relationships : List({ spdxElementId : Str, relatedSpdxElement : Str, relationshipType : Str, comment : Try(Str, [Missing]) }) }
	Composition : { profile : Str, imported_documents : List(Imported), components : List(Component), relationships : List(Edge), coverage : List(Coverage), inputs : List(Disposition) }
	Context : { namespace : Str, revision : Str, created : Str, author : Str, generator : Str }
	Subject : { filename : Str, version : Str, target : Str, sha256 : Str, url : Str }
	Inventory : { target : Str, components : List(Component), relationships : List(Edge), coverage : List(Coverage), inputs : List(Disposition), inspected : List(Str) }

	## Existing optional Spec extension seam: Custom("sbom-v1", SUBJECT, Str(JSON)).
	## No resolver pins live in this metadata; `origin` references the Lock.
	from_spec : Spec, Str -> Try(Composition, Str)
	from_spec = |spec, name| {
		matches = spec.extensions.keep_if(|extension| extension.kind == "sbom-v1" and extension.name == name)
		match matches {
			[extension] => match extension.value {
				Str(text) => if !json_within_bounds(text) Err("SBOM composition exceeds 1MiB") else Json.parse(text).map_err(|_| "invalid SBOM composition JSON")
				_ => Err("sbom-v1 extension must hold JSON in Str")
			}
			_ => Err("expected exactly one sbom-v1 extension for subject")
		}
	}

	## Preflight recursive JSON before built-in decoding, including ignored keys.
	json_within_bounds : Str -> Bool
	json_within_bounds = |text| {
		if text.to_utf8().len() > 1024 * 1024 {
			return False
		}
		var $depth = 0.U64
		var $quoted = not_analyzed
		var $escaped = not_analyzed
		for byte in text.to_utf8() {
			if $quoted {
				if $escaped {
					$escaped = False
				} else if byte == '\\' {
					$escaped = True
				} else if byte == '"' {
					$quoted = False
				}
			} else if byte == '"' {
				$quoted = True
			} else if byte == '{' or byte == '[' {
				$depth = $depth + 1
				if $depth > 64 {
					return False
				}
			} else if byte == '}' or byte == ']' {
				if $depth == 0 {
					return False
				}
				$depth = $depth - 1
			}
		}
		$depth == 0 and !$quoted
	}

	profile = "blueprint-spdx-2.3-v1"

	## Stable names for authoritative inputs; every known input needs a reviewed
	## disposition, even when it is excluded from this particular deliverable.
	known_inputs : Spec, Lock, Str -> List(Str)
	known_inputs = |spec, lock, target| {
		sources = lock.sources.map(|source| "source:${source.name}")
		programs = lock.fetched.keep_if(|program| program.system == target or target == "source").map(|program| "program:${program.name}:${program.system}")
		tools = spec.environments.fold([], |all, environment| all.concat(environment.tools.map(|tool| "tool:${tool.source}#${tool.name}")))
			.concat(spec.configured_tools.map(|entry| "tool:${entry.tool.source}#${entry.tool.name}"))
			.concat(spec.system_tools.keep_if(|entry| entry.system == target or target == "source").fold([], |all, entry| all.concat(entry.tools.map(|tool| "tool:${tool.source}#${tool.name}"))))
		entries = spec.roc_packages.map(|bundle| "roc-package:${bundle.name}")
		builds = spec.build_sources.map(|source| "build-source:${source.name}")
		unique(sources.concat(programs).concat(tools).concat(entries).concat(builds).concat(spec.tasks.map(|task| "task:${task.name}")).concat(spec.builds.map(|build| "build:${build.name}")))
	}

	## Resolve only reviewed source/program references. A component never chooses
	## a new pin; conflicting supplemental metadata is rejected.
	inspect : Spec, Lock, Str, Composition -> Try(Inventory, Str)
	inspect = |spec, lock, target, composition| {
		_ = Lock.stale(lock, spec)?
		for source in spec.sources {
			if !lock.sources.any(|pin| pin.name == source.name) {
				return Err("declared source absent from Lock")
			}
		}
		for program in spec.programs.keep_if(|entry| entry.system == target or target == "source") {
			_ = Lock.fetched_for(lock, program).map_err(|_| "declared program absent/stale in Lock")?
		}
		if composition.imported_documents.len() > 16 {
			return Err("too many imported SBOMs")
		}
		var $combined = { ..composition, imported_documents: [] }
		for imported in composition.imported_documents {
			expanded = expand_import(imported, target)?
			$combined = { ..$combined, components: $combined.components.concat(expanded.components), relationships: $combined.relationships.concat(expanded.relationships), coverage: $combined.coverage.append(expanded.coverage) }
		}
		inspect_composition(lock, target, $combined, known_inputs(spec, lock, target))
	}

	## Recipes outside a Blueprint project supply their observed authoritative
	## input identities explicitly. This is still pure inspection, not discovery.
	inspect_declared : Str, Composition, List(Str) -> Try(Inventory, Str)
	inspect_declared = |target, composition, known| {
		if !composition.imported_documents.is_empty() or composition.components.any(|entry| entry.origin != "reviewed") {
			return Err("declared inventory expects expanded reviewed components; use inspect for Lock/import binding")
		}
		if unique(known).len() != known.len() {
			return Err("duplicate known input")
		}
		inspect_composition(Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [], fetched: [], hints: [] }, target, composition, known)
	}

	## Shared validation path for provider-neutral supplemental/imported graphs.
	inspect_composition : Lock, Str, Composition, List(Str) -> Try(Inventory, Str)
	inspect_composition = |lock, target, composition, known| {
		if composition.profile != profile {
			return Err("unsupported SBOM composition profile")
		}
		if composition.components.len() > 4096 or composition.relationships.len() > 16384 or composition.coverage.len() > 1024 {
			return Err("SBOM input exceeds profile bounds")
		}
		identities = composition.components.map(|entry| "${entry.identity}:${entry.target}")
		if unique(identities).len() != identities.len() {
			return Err("duplicate/conflicting component identity; variants need distinct stable identities")
		}
		ids = composition.components.map(|component| component.id)
		if unique(ids).len() != ids.len() or ids.contains("SPDXRef-Subject") or ids.any(|id| !valid_id(id)) {
			return Err("duplicate or invalid component identifier")
		}
		var $components = []
		for component in composition.components {
			resolved = resolve(component, lock)?
			if component.id.to_utf8().len() > 256 or Json.to_str(component).to_utf8().len() > 16384 {
				return Err("component metadata exceeds profile bounds")
			}
			if !component.target.is_empty() and component.target != target {
				return Err("component target differs from subject target")
			}
			if !supplier(component.producer) or !license(component.license) {
				return Err("invalid SPDX supplier or license expression")
			}
			if !uri(resolved.download) or (!resolved.license_url.is_empty() and !uri(resolved.license_url)) or !identity(resolved.identity) {
				return Err("invalid or credential-bearing component URI/identity")
			}
			if component.name.is_empty() or component.producer.is_empty() or component.version.is_empty() or component.identity.is_empty() or component.download.is_empty() or component.license.is_empty() {
				return Err("component identity/license must be explicit, use NOASSERTION for unknown license")
			}
			if !component.sha256.is_empty() and !hex(component.sha256) {
				return Err("invalid component SHA-256")
			}
			if component.license.contains("LicenseRef-") and component.license_url.is_empty() {
				return Err("restricted license needs terms location")
			}
			$components = $components.append(resolved)
		}
		allowed = ids.append("SPDXRef-Subject")
		for edge in composition.relationships {
			if !allowed.contains(edge.from) or !allowed.contains(edge.to) or edge.from == edge.to or edge.basis.is_empty() {
				return Err("dangling relationship or missing relationship basis")
			}
			if !["CONTAINS", "DEPENDS_ON", "BUILD_DEPENDENCY_OF", "TEST_DEPENDENCY_OF", "GENERATED_FROM", "PATCH_FOR", "VARIANT_OF", "OTHER"].contains(edge.relation) {
				return Err("unsupported relationship type")
			}
		}
		if unique(composition.relationships.map(|edge| "${edge.from}:${edge.relation}:${edge.to}")).len() != composition.relationships.len() {
			return Err("duplicate relationship")
		}
		var $reached = ["SPDXRef-Subject"]
		var $changed = !ids.is_empty()
		while $changed {
			$changed = False
			for edge in composition.relationships {
				if $reached.contains(edge.from) and !$reached.contains(edge.to) {
					$reached = $reached.append(edge.to)
					$changed = True
				}
				if $reached.contains(edge.to) and !$reached.contains(edge.from) {
					$reached = $reached.append(edge.from)
					$changed = True
				}
			}
		}
		if ids.any(|id| !$reached.contains(id)) {
			return Err("component graph disconnected from subject")
		}
		if unique(composition.coverage.map(|scope| scope.scope)).len() != composition.coverage.len() {
			return Err("duplicate coverage scope")
		}
		for id in ids {
			if !composition.relationships.any(|edge| edge.from == id or edge.to == id) {
				return Err("unexplained disconnected component")
			}
		}
		if composition.coverage.is_empty() {
			return Err("coverage must distinguish verified empty from unknown inventory")
		}
		for scope in composition.coverage {
			if scope.scope.is_empty() or scope.reason.is_empty() or scope.contact.is_empty() or !["complete", "incomplete", "excluded", "verified-empty"].contains(scope.status) {
				return Err("invalid or unexplained coverage")
			}
		}
		declared = composition.inputs.map(|input| input.input)
		if unique(declared).len() != declared.len() or declared.len() != known.len() or known.any(|input| !declared.contains(input)) {
			return Err("known input omitted or unknown/duplicate input disposition")
		}
		for disposition in composition.inputs {
			if disposition.reason.is_empty() or (!disposition.component.is_empty() and !ids.contains(disposition.component)) {
				return Err("input needs component or explained exclusion")
			}
		}
		Ok({ target, components: $components.sort_with(|a, b| Project.bytewise(a.id, b.id)), relationships: composition.relationships.sort_with(|a, b| Project.bytewise("${a.from}:${a.relation}:${a.to}", "${b.from}:${b.relation}:${b.to}")), coverage: composition.coverage.sort_with(|a, b| Project.bytewise(a.scope, b.scope)), inputs: composition.inputs.sort_with(|a, b| Project.bytewise(a.input, b.input)), inspected: known.sort_with(Project.bytewise) })
	}

	## Bind caller-supplied digest of final bytes. Effects live in scripts/sbom.roc.
	## A revised document gets a distinct namespace while the subject stays fixed.
	render : Inventory, Subject, Context -> Try(Str, Str)
	render = |inventory, subject, context| {
		if !uri(subject.url) or !uri(context.namespace) {
			return Err("invalid or credential-bearing subject/document URI")
		}
		if inventory.target != subject.target {
			return Err("subject target differs from inspected target")
		}
		_ = inspect(Spec.empty("sbom-validation"), Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [], fetched: [], hints: [] }, subject.target, { profile, imported_documents: [], components: inventory.components.map(|entry| { ..entry, origin: "reviewed" }), relationships: inventory.relationships, coverage: inventory.coverage, inputs: [] })?
		if unique(inventory.inspected).len() != inventory.inspected.len() or inventory.inspected.sort_with(Project.bytewise) != inventory.inputs.map(|entry| entry.input).sort_with(Project.bytewise) {
			return Err("inventory evidence does not account for inspected inputs")
		}
		if subject.filename.is_empty() or subject.filename.contains("/") or subject.filename.contains("\\") or subject.filename == "." or subject.filename == ".." or subject.version.is_empty() or subject.target.is_empty() or !hex(subject.sha256) {
			return Err("invalid subject filename/version/target/SHA-256")
		}
		if !context.namespace.starts_with("https://") or !context.namespace.ends_with("revision-${context.revision}") or context.revision.is_empty() or !valid_date(context.created) or (!context.author.starts_with("Organization: ") and !context.author.starts_with("Person: ")) or !context.generator.starts_with("Tool: ") {
			return Err("explicit namespace/revision/time/author/generator required")
		}
		if inventory.components.any(|component| !component.target.is_empty() and component.target != subject.target) {
			return Err("subject target differs from inspected inventory")
		}
		entries = inventory.components.map(package_json).prepend(subject_json(subject))
		relationships = inventory.relationships.map(|edge| Json.to_str({ spdxElementId: edge.from, relatedSpdxElement: edge.to, relationshipType: edge.relation, comment: edge.basis })).prepend(Json.to_str({ spdxElementId: "SPDXRef-DOCUMENT", relatedSpdxElement: "SPDXRef-Subject", relationshipType: "DESCRIBES" }))
		evidence = Json.to_str({ profile, revision: context.revision, target: subject.target, coverage: inventory.coverage, inspected: inventory.inspected, dispositions: inventory.inputs })
		annotation = Json.to_str({ annotationType: "OTHER", annotator: context.author, annotationDate: context.created, comment: evidence })
		licenses = inventory.components.fold(
			[],
			|all, component| {
				custom_ids = component.license.replace_each("(", " ").replace_each(")", " ").split_on(" ").keep_if(|token| token.starts_with("LicenseRef-"))
				all.concat(custom_ids.map(|id| Json.to_str({ licenseId: id, extractedText: "NOASSERTION", name: id, seeAlsos: [component.license_url] })))
			},
		)
		text = "{\"spdxVersion\":\"SPDX-2.3\",\"dataLicense\":\"CC0-1.0\",\"SPDXID\":\"SPDXRef-DOCUMENT\",\"name\":${Json.to_str(subject.filename)},\"documentNamespace\":${Json.to_str(context.namespace)},\"creationInfo\":${Json.to_str({ created: context.created, creators: [context.author, context.generator], licenseListVersion: "3.26" })},\"packages\":[${Str.join_with(entries, ",")}],\"relationships\":[${Str.join_with(relationships, ",")}],\"annotations\":[${annotation}],\"hasExtractedLicensingInfos\":[${Str.join_with(unique(licenses), ",")}] }\n"
		if leaks(text) {
			return Err("SBOM contains credential or absolute developer path")
		}
		Ok(text)
	}
}

unique : List(Str) -> List(Str)
unique = |values| values.fold([], |all, value| if all.contains(value) all else all.append(value))

valid_id : Str -> Bool
valid_id = |id| id.starts_with("SPDXRef-") and id != "SPDXRef-" and id.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.')

hex : Str -> Bool
hex = |value| value.to_utf8().len() == 64 and value.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))

leaks : Str -> Bool
leaks = |value| ["/Users/", "/home/", "/private/", "/tmp/", "/var/", "/nix/store/", "C:\\\\Users\\\\", "token=", "password=", "ghp_", "github_pat_", "BEGIN PRIVATE KEY"].any(|marker| value.contains(marker))

resolve : Sbom.Component, Lock -> Try(Sbom.Component, Str)
resolve = |component, lock| {
	if component.origin == "reviewed" {
		return Ok(component)
	}
	if component.origin.starts_with("source:") {
		name = component.origin.drop_prefix("source:")
		source = lock.sources.find_first(|candidate| candidate.name == name).map_err(|_| "unresolved locked source")?
		if component.version != (if source.rev.is_empty() source.digest else source.rev) or component.download != source.ref or component.identity != "${source.ref}@${source.rev}#${source.digest}" {
			return Err("supplemental metadata conflicts with locked source")
		}
		if source.provider == "file" {
			if !source.digest.starts_with("sha256:") or component.sha256 != source.digest.drop_prefix("sha256:") or !hex(component.sha256) {
				return Err("supplemental file SHA-256 conflicts with authoritative flat file pin")
			}
		} else if !component.sha256.is_empty() {
			return Err("tree identity is not an archive SHA-256")
		}
		canonical = if source.ref.starts_with("github:") and !source.rev.is_empty() {
			parts = source.ref.drop_prefix("github:").split_on("/")
			"https://github.com/${Str.join_with(parts.take_first(2), "/")}/tree/${source.rev}"
		} else if source.ref.starts_with("tarball+https://") source.ref.drop_prefix("tarball+") else if uri(source.ref) source.ref else "NOASSERTION"
		return Ok({ ..component, download: canonical, identity: "urn:blueprint:source:${source.name}:${source.rev}:${source.digest}" })
	}
	if component.origin.starts_with("program:") {
		entry = lock.fetched.find_first(|candidate| component.origin == "program:${candidate.name}:${candidate.system}").map_err(|_| "unresolved locked program")?
		if component.sha256 != entry.sha256 or !entry.urls.contains(component.download) or component.target != entry.system {
			return Err("supplemental metadata conflicts with locked program")
		}
		return Ok(component)
	}
	Err("unknown component origin; use reviewed or an authoritative lock reference")
}

package_json : Sbom.Component -> Str
package_json = |component| {
	checksums = if component.sha256.is_empty() [] else [{ algorithm: "SHA256", checksumValue: component.sha256 }]
	comment = Json.to_str({ identity: component.identity, origin: component.origin, target: component.target, modifications: component.modified })
	Json.to_str({ spdxid: component.id, name: component.name, versionInfo: component.version, supplier: component.producer, downloadLocation: component.download, filesAnalyzed: not_analyzed, licenseConcluded: "NOASSERTION", licenseDeclared: component.license, copyrightText: "NOASSERTION", checksums, comment, externalRefs: if component.identity.starts_with("pkg:") [{ referenceCategory: "PACKAGE-MANAGER", referenceType: "purl", referenceLocator: component.identity }] else [] }).replace_each("\"spdxid\":", "\"SPDXID\":")
}

subject_json : Sbom.Subject -> Str
subject_json = |subject| Json.to_str({ spdxid: "SPDXRef-Subject", name: subject.filename, versionInfo: subject.version, supplier: "NOASSERTION", downloadLocation: subject.url, filesAnalyzed: not_analyzed, licenseConcluded: "NOASSERTION", licenseDeclared: "NOASSERTION", copyrightText: "NOASSERTION", checksums: [{ algorithm: "SHA256", checksumValue: subject.sha256 }], comment: Json.to_str({ target: subject.target, digest_kind: "final-deliverable-sha256" }) }).replace_each("\"spdxid\":", "\"SPDXID\":")

valid_date : Str -> Bool
valid_date = |text| {
	if text.to_utf8().len() != 20 {
		return False
	}
	parts = text.drop_suffix("Z").split_on("T")
	match parts {
		[date, time] => match (date.split_on("-"), time.split_on(":")) {
			([year, month, day], [hour, minute, second]) => {
				numbers = [year, month, day, hour, minute, second]
				if !numbers.all(|number| number.to_utf8().all(|byte| byte >= '0' and byte <= '9')) {
					return False
				}
				m = U64.from_str(month) ?? 0
				d = U64.from_str(day) ?? 0
				h = U64.from_str(hour) ?? 99
				minute_number = U64.from_str(minute) ?? 99
				s = U64.from_str(second) ?? 99
				m >= 1 and m <= 12 and d >= 1 and d <= 31 and h <= 23 and minute_number <= 59 and s <= 60
			}
			_ => False
		}
		_ => False
	}
}

# Reviewed URI profile: HTTPS only, no userinfo, query, backslash or whitespace.
# Immutable versions/revisions belong in the path; explicit unknown is allowed.
uri : Str -> Bool
uri = |value| {
	if value == "NOASSERTION" {
		return True
	}
	if !value.starts_with("https://") or value.contains("?") or value.contains("\\") or value.to_utf8().any(|byte| byte <= 32 or byte == 127) {
		return False
	}
	host = value.drop_prefix("https://").split_on("/").first() ?? ""
	!host.is_empty() and !host.contains("@") and !host.contains("%") and host != "localhost" and !host.starts_with("127.") and host != "[::1]"
}

identity : Str -> Bool
identity = |value| {
	if value.starts_with("https://") {
		return uri(value)
	}
	if value.starts_with("pkg:") {
		return !value.contains("?") and !value.contains("\\") and !value.contains(" ") and value.contains("@")
	}
	if value.starts_with("urn:") {
		return !value.contains(" ") and !value.contains("\\")
	}
	# Source identity is the provider reference + immutable revision + tree digest.
	value.starts_with("github:") and !value.contains("?") and !value.contains(" ") and value.contains("#sha256-")
}

supplier : Str -> Bool
supplier = |value| value == "NOASSERTION" or (value.starts_with("Organization: ") and value != "Organization: ") or (value.starts_with("Person: ") and value != "Person: ")

license : Str -> Bool
license = |value| {
	if value == "NOASSERTION" or value == "NONE" {
		return True
	}
	tokens = value.replace_each("(", " ( ").replace_each(")", " ) ").split_on(" ").keep_if(|token| !token.is_empty())
	if tokens.len() > 128 {
		return False
	}
	match license_expr(tokens, 0) {
		Ok([]) => True
		_ => False
	}
}

license_expr : List(Str), U64 -> Try(List(Str), [InvalidLicense])
license_expr = |tokens, depth| {
	if depth > 32 {
		return Err(InvalidLicense)
	}
	rest = license_atom(tokens, depth + 1)?
	match rest {
		["AND", .. as remaining] | ["OR", .. as remaining] => license_expr(remaining, depth + 1)
		_ => Ok(rest)
	}
}

license_atom : List(Str), U64 -> Try(List(Str), [InvalidLicense])
license_atom = |tokens, depth| {
	match tokens {
		["(", .. as after] => {
			rest = license_expr(after, depth + 1)?
			match rest {
				[")", .. as remaining] => Ok(remaining)
				_ => Err(InvalidLicense)
			}
		}
		[token, .. as after] => {
			custom = token.starts_with("LicenseRef-") and token != "LicenseRef-" and token.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.')
			if !SbomLicenses.licenses.contains(token.drop_suffix("+")) and !custom {
				return Err(InvalidLicense)
			}
			match after {
				["WITH", exception, .. as remaining] => if SbomLicenses.exceptions.contains(exception) Ok(remaining) else Err(InvalidLicense)
				_ => Ok(after)
			}
		}
		_ => Err(InvalidLicense)
	}
}

# Import inert, caller-supplied bytes only. Namespace and checksum are distinct
# identities; imports never download a URI or execute a document's contents.
expand_import : Sbom.Imported, Str -> Try({ components : List(Sbom.Component), relationships : List(Sbom.Edge), coverage : Sbom.Coverage }, Str)
expand_import = |imported, target| {
	if !valid_id(imported.id) or !uri(imported.url) or !uri(imported.namespace) or !hex(imported.sha256) or !Sbom.json_within_bounds(imported.document) or imported.contact.is_empty() or imported.basis.is_empty() {
		return Err("invalid or oversized imported reference")
	}
	if imported.target != target {
		return Err("import target differs from subject")
	}
	if Crypto.SHA256.hash(imported.document.to_utf8()).to_hex() != imported.sha256 {
		return Err("imported SBOM content digest mismatch")
	}
	decoded : Sbom.ImportedDocument
	decoded = Json.parse(imported.document.replace_each("\"SPDXID\":", "\"spdxid\":").replace_each("\"packages\":", "\"entries\":")).map_err(|_| "imported SBOM outside supported SPDX package profile")?
	if decoded.spdxVersion != "SPDX-2.3" or decoded.documentNamespace != imported.namespace or decoded.spdxid != "SPDXRef-DOCUMENT" or decoded.entries.is_empty() or decoded.entries.len() > 4096 or decoded.relationships.len() > 16384 {
		return Err("invalid imported document identity or bounds")
	}
	ids = decoded.entries.map(|entry| entry.spdxid)
	if unique(ids).len() != ids.len() or ids.any(|id| !valid_id(id)) {
		return Err("duplicate/invalid imported component identifier")
	}
	map_id = |id| "${imported.id}-${id.drop_prefix("SPDXRef-")}"
	var $edges = []
	var $roots = []
	for relation in decoded.relationships {
		if relation.spdxElementId == "SPDXRef-DOCUMENT" and relation.relationshipType == "DESCRIBES" {
			if !ids.contains(relation.relatedSpdxElement) {
				return Err("dangling imported subject")
			}
			$roots = $roots.append(relation.relatedSpdxElement)
			$edges = $edges.append({ from: "SPDXRef-Subject", to: map_id(relation.relatedSpdxElement), relation: imported.relation, basis: imported.basis })
		} else {
			if !ids.contains(relation.spdxElementId) or !ids.contains(relation.relatedSpdxElement) {
				return Err("dangling/external imported relationship; provide referenced graph explicitly")
			}
			$edges = $edges.append({ from: map_id(relation.spdxElementId), to: map_id(relation.relatedSpdxElement), relation: relation.relationshipType, basis: relation.comment ?? "Verified imported SPDX relationship" })
		}
	}
	if $roots.is_empty() {
		return Err("imported SBOM lacks DESCRIBES subject")
	}
	components = decoded.entries.map(
		|entry| {
			digest = entry.checksums.find_first(|checksum| checksum.algorithm == "SHA256").map_ok(|checksum| checksum.checksumValue) ?? ""
			{ id: map_id(entry.spdxid), name: entry.name, version: entry.versionInfo, producer: entry.supplier, download: entry.downloadLocation, license: entry.licenseDeclared, license_url: (decoded.hasExtractedLicensingInfos ?? []).find_first(|terms| entry.licenseDeclared.contains(terms.licenseId)).map_ok(|terms| terms.seeAlsos.first() ?? "") ?? "", sha256: digest, identity: "${imported.namespace}#${entry.spdxid}", origin: "reviewed", target, modified: "Imported inert SPDX graph from ${imported.url}; document SHA256 ${imported.sha256}" }
		},
	)
	Ok({ components, relationships: $edges, coverage: { scope: "import:${imported.id}", status: "incomplete", reason: "Imported graph is verified by digest; upstream completeness and undisclosed closure are not independently established", contact: imported.contact } })
}

# Keep JSON boolean nominal rather than an inferred single tag.
not_analyzed : Bool
not_analyzed = False
