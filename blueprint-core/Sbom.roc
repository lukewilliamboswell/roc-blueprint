import Spec
import Lock
import Project
import CycloneDx
import JsonTree
import Lookup
import SbomLicenses
import Spdx2
import Spdx3

## Provider-neutral, pure SPDX inventory. No filesystem, Store or provider effects.
## Composition is reviewed data; locked references resolve identities from Lock.
##
## An inventory is independent of SPDX versions. `render` writes it as SPDX
## 3.0.1, `render_spdx2` as SPDX 2.3, for consumers that have not moved, and
## `render_cyclonedx` as CycloneDX 1.7; `read` takes SPDX 3.0.1, 2.3 or 2.2
## back, and `read_cyclonedx` Blueprint's own CycloneDX, to the same
## `Document`. Component
## and relationship identifiers are local names: `name` becomes `SPDXRef-name`
## in SPDX 2 and `NAMESPACE#name` in SPDX 3. Relationships use the SPDX 3.0.1
## vocabulary; a lifecycle `scope` on `dependsOn` is how SPDX 3 says what SPDX
## 2 said with `BUILD_DEPENDENCY_OF` and its siblings.
Sbom := [].{
	Component : { id : Str, name : Str, producer : Str, version : Str, identity : Str, download : Str, sha256 : Str, license : Str, license_url : Str, modified : Str, target : Str, origin : Str }
	Edge : { from : Str, to : Str, relation : Str, scope : Str, basis : Str }
	Coverage : { scope : Str, status : Str, reason : Str, contact : Str }
	Disposition : { input : Str, component : Str, reason : Str }
	Imported : { subject : { component : Str, filename : Str, version : Str, sha256 : Str }, id : Str, url : Str, sha256 : Str, namespace : Str, target : Str, document : Str, relation : Str, basis : Str, contact : Str }

	## A locked dependency whose supplier publishes no SBOM, and why. Every
	## other locked dependency needs one, imported and bound to it.
	Unavailable : { component : Str, reason : Str, contact : Str }
	Composition : { profile : Str, imported_documents : List(Imported), unavailable_sboms : List(Unavailable), components : List(Component), relationships : List(Edge), coverage : List(Coverage), inputs : List(Disposition) }
	Context : { namespace : Str, revision : Str, created : Str, author : Str, generator : Str }
	Subject : { filename : Str, version : Str, target : Str, sha256 : Str, url : Str }
	Inventory : { target : Str, components : List(Component), relationships : List(Edge), coverage : List(Coverage), inputs : List(Disposition), inspected : List(Str) }

	## A package as an SPDX document states it, whichever version wrote it.
	## Unstated supplier, download and license read as `NOASSERTION`; an
	## unstated SHA-256, package URL or comment reads as "".
	Package : { id : Str, name : Str, version : Str, supplier : Str, download : Str, license : Str, license_url : Str, sha256 : Str, identity : Str, comment : Str }

	## The package graph of an SPDX document. `roots` are the packages it
	## describes. Identifiers are local, as in a Composition. `evidence` holds
	## the text of each `other` annotation on the document itself, where
	## `render` records the profile's coverage and input dispositions. `gaps`
	## counts what the reader left out of the package graph, and why: files,
	## snippets, relationships to them or into other documents, relationship
	## types with no composition meaning, and the sections of a CycloneDX BOM
	## that are not composition. Blueprint's own documents have none.
	Document : { version : Str, namespace : Str, name : Str, roots : List(Str), packages_ : List(Package), relationships : List(Edge), evidence : List(Str), gaps : List(Str) }

	## Existing optional Spec extension seam: Custom("sbom-v1", SUBJECT, Str(JSON)).
	## No resolver pins live in this metadata; `origin` references the Lock.
	from_spec : Spec, Str -> Try(Composition, Str)
	from_spec = |spec, name| {
		matches = spec.extensions.keep_if(|extension| extension.kind == "sbom-v1" and extension.name == name)
		match matches {
			[extension] => match extension.value {
				Str(text) => if (!json_within_bounds(text)) Err("SBOM composition exceeds 1MiB") else Json.parse(text).map_err(|_| "invalid SBOM composition JSON")
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

	profile = "blueprint-spdx-3.0-v1"

	## The SPDX 3.0.1 relationship types a composition may state. Each has an
	## SPDX 2.3 spelling, so both renderings say the same thing.
	relations : List(Str)
	relations = ["contains", "dependsOn", "generates", "patchedBy", "hasVariant", "copiedTo", "other"]

	## The lifecycle scopes a `dependsOn` may carry.
	scopes : List(Str)
	scopes = ["build", "test", "development", "runtime"]

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
		if target != "source" and !spec.systems.contains(target) {
			return Err("inventory target is not declared by Spec")
		}
		if unique(lock.sources.map(|entry| entry.name)).len() != lock.sources.len() or unique(lock.fetched.map(|entry| "${entry.name}:${entry.system}")).len() != lock.fetched.len() {
			return Err("duplicate authoritative locked identity")
		}
		unsupported = spec.unsupported_features(["explicit-sources", "sources", "programs", "expects", "builds", "workflows", "system-tools", "commands", "roc-packages", "configured-tools", "raw", "source-files"])
		if !unsupported.is_empty() {
			return Err("unsupported required inventory feature: ${Str.join_with(unsupported, ", ")}")
		}
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
		# A dependency you consume from someone else comes with their SBOM,
		# bound to the bytes you locked, unless the composition says why not.
		consumed = composition.components.keep_if(|entry| entry.origin.starts_with("source:") or entry.origin.starts_with("program:"))
		bound = composition.imported_documents.map(|imported| imported.subject.component).keep_if(|id| !id.is_empty())
		exempt = composition.unavailable_sboms.map(|entry| entry.component)
		for entry in composition.unavailable_sboms {
			if !consumed.any(|component| component.id == entry.component) {
				return Err("unavailable_sboms names ${entry.component}, which is not a locked dependency")
			}
			if entry.reason.is_empty() or entry.contact.is_empty() {
				return Err("unavailable_sboms entry for ${entry.component} needs a reason and a contact")
			}
			if bound.contains(entry.component) {
				return Err("${entry.component} has a bound supplier SBOM and an unavailable_sboms entry")
			}
		}
		if unique(exempt).len() != exempt.len() {
			return Err("unavailable_sboms names a dependency twice")
		}
		for entry in consumed {
			if !bound.contains(entry.id) and !exempt.contains(entry.id) {
				tree = match entry.origin.split_on(":") {
					["source", name] => lock.sources.any(|source| source.name == name and source.provider != "file")
					_ => False
				}
				hint = if (tree) " Its Lock pin is a tree digest, which no supplier SBOM can bind to; pin the file by its published SHA-256 to bind one." else ""
				return Err("dependency ${entry.id} (${entry.origin}) has no supplier SBOM. Import one in imported_documents with subject.component ${Json.to_str(entry.id)}, or list it in unavailable_sboms with the reason none is available.${hint}")
			}
		}
		gaps = composition.unavailable_sboms.map(|entry| { scope: "sbom:${entry.component}", status: "incomplete", reason: "No supplier SBOM: ${entry.reason}", contact: entry.contact })
		var $combined = { ..composition, imported_documents: [], unavailable_sboms: [], coverage: composition.coverage.concat(gaps) }
		for imported in composition.imported_documents {
			binding = if imported.subject.component.is_empty() {
				Err(Unbound)
			} else {
				declared = composition.components.find_first(|entry| entry.id == imported.subject.component).map_err(|_| "import subject binding references missing component")?
				Ok(resolve(declared, lock)?)
			}
			expanded = expand_import(imported, target, binding)?
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
		ids = composition.components.map(|component| component.id)
		if unique(ids).len() != ids.len() or ids.any(|id| !valid_id(id)) {
			return Err("duplicate or invalid component identifier")
		}
		var $components = []
		for component in composition.components {
			resolved = resolve(component, lock)?
			if component.id.to_utf8().len() > 256 or Json.to_str(component).to_utf8().len() > 16384 {
				return Err("component metadata exceeds profile bounds")
			}
			if target != "source" and !resolved.target.is_empty() and resolved.target != target {
				return Err("component target differs from subject target")
			}
			if !supplier(component.producer) or !license(component.license) {
				return Err("invalid SPDX supplier or license expression")
			}
			if !uri(resolved.download) or (!resolved.license_url.is_empty() and !uri(resolved.license_url)) or !identity(resolved.identity) {
				return Err("invalid or credential-bearing component URI/identity")
			}
			if resolved.name.is_empty() or resolved.producer.is_empty() or resolved.version.is_empty() or resolved.identity.is_empty() or resolved.download.is_empty() or resolved.license.is_empty() {
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
		# SPDX 2 declares each LicenseRef- once per document, with one location.
		terms = $components.fold([], |all, entry| all.concat(SbomLicenses.custom_ids(entry.license).map(|id| "${id} ${entry.license_url}")))
		if unique(terms.map(|entry| entry.split_on(" ").first() ?? "")).len() != unique(terms).len() {
			return Err("one LicenseRef- identifier names different terms locations")
		}
		identities = $components.map(|entry| "${entry.identity}:${entry.target}")
		if unique(identities).len() != identities.len() {
			return Err("duplicate/conflicting resolved component identity; variants need distinct identities")
		}
		allowed = ids.append(subject_id)
		for edge in composition.relationships {
			if !allowed.contains(edge.from) or !allowed.contains(edge.to) or edge.from == edge.to or edge.basis.is_empty() {
				return Err("dangling relationship or missing relationship basis")
			}
			if !relations.contains(edge.relation) {
				return Err("unsupported relationship type")
			}
			if !edge.scope.is_empty() and (edge.relation != "dependsOn" or !scopes.contains(edge.scope)) {
				return Err("a lifecycle scope is one of ${Str.join_with(scopes, ", ")} on dependsOn")
			}
		}
		if unique(composition.relationships.map(edge_key)).len() != composition.relationships.len() {
			return Err("duplicate relationship")
		}
		var $reached = [subject_id]
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
		Ok({ target, components: $components.sort_with(|a, b| Project.bytewise(a.id, b.id)), relationships: composition.relationships.sort_with(|a, b| Project.bytewise(edge_key(a), edge_key(b))), coverage: composition.coverage.sort_with(|a, b| Project.bytewise(a.scope, b.scope)), inputs: composition.inputs.sort_with(|a, b| Project.bytewise(a.input, b.input)), inspected: known.sort_with(Project.bytewise) })
	}

	## Bind caller-supplied digest of final bytes as SPDX 3.0.1 JSON-LD. Effects
	## live in scripts/sbom.roc. A revised document gets a distinct namespace
	## while the subject stays fixed. The text is checked against the 3.0.1
	## model before it is returned.
	render : Inventory, Subject, Context -> Try(Str, Str)
	render = |inventory, subject, context| {
		bindable(inventory, subject, context)?
		text = "${spdx3(inventory, subject, context).to_str()}\n"
		_ = Spdx3.validate(text).map_err(|problem| "rendered SPDX 3.0.1 is invalid: ${problem}")?
		no_leaks(text)
	}

	## `render` as SPDX 2.3 JSON, for consumers that read only SPDX 2.
	render_spdx2 : Inventory, Subject, Context -> Try(Str, Str)
	render_spdx2 = |inventory, subject, context| {
		bindable(inventory, subject, context)?
		text = spdx2(inventory, subject, context)
		_ = Spdx2.validate(JsonTree.parse(text)?).map_err(|problem| "rendered SPDX 2.3 is invalid: ${problem}")?
		no_leaks(text)
	}

	## `render` as CycloneDX 1.7 JSON. The subject is the metadata component
	## and each inventory component a component with its hashes, purl,
	## license expression, supplier or authors, download and license terms
	## locations. `contains` and `dependsOn` relationships are dependencies.
	## A component's scope is `required` when the subject reaches it through
	## `contains` or a `dependsOn` without a lifecycle scope or with `runtime`,
	## `excluded` when it is otherwise the target of a build, test or
	## development dependency, and `optional` otherwise. CycloneDX has no
	## relationship types, so every relationship, the evidence and each
	## component's identity also travel as `blueprint:` properties, which
	## `read_cyclonedx` reads back without loss.
	render_cyclonedx : Inventory, Subject, Context -> Try(Str, Str)
	render_cyclonedx = |inventory, subject, context| {
		bindable(inventory, subject, context)?
		text = "${cyclonedx(inventory, subject, context).to_str()}\n"
		_ = CycloneDx.validate(text).map_err(|problem| "rendered CycloneDX ${CycloneDx.version} is invalid: ${problem}")?
		no_leaks(text)
	}

	## The package graph of a CycloneDX BOM that `render_cyclonedx` wrote,
	## after checking it against CycloneDX 1.7 and checking that its
	## dependencies and scopes are what its relationships state. A BOM without the
	## `blueprint:` properties is not one of these and is refused.
	read_cyclonedx : Str -> Try(Document, Str)
	read_cyclonedx = |text| {
		if !json_within_bounds(text) {
			return Err("CycloneDX document exceeds 1MiB or nests deeper than 64 levels")
		}
		read_bom(CycloneDx.validate(text)?)
	}

	## The package graph of an SPDX 3.0.1, 2.3 or 2.2 JSON document, or of a
	## CycloneDX 1.4 to 1.7 JSON BOM, after checking it against that format.
	## A BOM Blueprint wrote is read through its `blueprint:` properties. Only a package graph is read: other
	## element kinds, and relationships without a Composition spelling, are
	## outside this profile and rejected.
	read : Str -> Try(Document, Str)
	read = |text| {
		if !json_within_bounds(text) {
			return Err("SPDX document exceeds 1MiB or nests deeper than 64 levels")
		}
		tree = JsonTree.parse(text)?
		if tree.field("@context").is_ok() {
			read_spdx3(Spdx3.check(tree)?)
		} else if tree.field("spdxVersion").is_ok() {
			Spdx2.validate(tree)?
			read_spdx2(tree)
		} else if tree.field("bomFormat").is_ok() {
			ignored = CycloneDx.check_import(tree)?
			if (text.contains("\"blueprint:namespace\"")) read_bom(tree) else read_foreign_bom(tree, ignored)
		} else {
			Err("not an SPDX 3 JSON-LD, SPDX 2 JSON or CycloneDX JSON document")
		}
	}
}

## The delivered subject's local identifier.
subject_id = "Subject"

edge_key : Sbom.Edge -> Str
edge_key = |edge| "${edge.from}:${edge.relation}:${edge.scope}:${edge.to}"

unique : List(Str) -> List(Str)
unique = |values| values.fold([], |all, value| if (all.contains(value)) all else all.append(value))

## A local identifier: the SPDX 2 `idstring` characters, so `SPDXRef-${id}` is
## an SPDX 2 identifier and `NAMESPACE#${id}` an IRI. Generated SPDX 3
## elements live under `spdx/`, which no local identifier can spell.
valid_id : Str -> Bool
valid_id = |id| !id.is_empty() and id != subject_id and id != "DOCUMENT" and id.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.')

hex : Str -> Bool
hex = |value| value.to_utf8().len() == 64 and value.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))

leaks : Str -> Bool
leaks = |value| ["/Users/", "/home/", "/private/", "/tmp/", "/var/", "/nix/store/", "C:\\\\Users\\\\", "token=", "password=", "ghp_", "github_pat_", "BEGIN PRIVATE KEY"].any(|marker| value.contains(marker))

no_leaks : Str -> Try(Str, Str)
no_leaks = |text| if (leaks(text)) Err("SBOM contains credential or absolute developer path") else Ok(text)

## What both renderings require of their inputs.
bindable : Sbom.Inventory, Sbom.Subject, Sbom.Context -> Try({}, Str)
bindable = |inventory, subject, context| {
	if !uri(subject.url) or !uri(context.namespace) or context.namespace.contains("#") {
		return Err("invalid or credential-bearing subject/document URI")
	}
	if inventory.target != subject.target {
		return Err("subject target differs from inspected target")
	}
	_ = Sbom.inspect_declared(subject.target, { profile: Sbom.profile, imported_documents: [], unavailable_sboms: [], components: inventory.components.map(|entry| { ..entry, origin: "reviewed" }), relationships: inventory.relationships, coverage: inventory.coverage, inputs: inventory.inputs }, inventory.inspected)?
	if unique(inventory.inspected).len() != inventory.inspected.len() or inventory.inspected.sort_with(Project.bytewise) != inventory.inputs.map(|entry| entry.input).sort_with(Project.bytewise) {
		return Err("inventory evidence does not account for inspected inputs")
	}
	if subject.filename.is_empty() or subject.filename.contains("/") or subject.filename.contains("\\") or subject.filename == "." or subject.filename == ".." or subject.version.is_empty() or subject.target.is_empty() or !hex(subject.sha256) {
		return Err("invalid subject filename/version/target/SHA-256")
	}
	if !context.namespace.starts_with("https://") or !context.namespace.ends_with("revision-${context.revision}") or context.revision.is_empty() or !Spdx3.timestamp(context.created) or !agent(context.author) or !context.generator.starts_with("Tool: ") or context.generator == "Tool: " {
		return Err("explicit namespace/revision/time/author/generator required")
	}
	if inventory.components.any(|component| subject.target != "source" and !component.target.is_empty() and component.target != subject.target) {
		return Err("subject target differs from inspected inventory")
	}
	Ok({})
}

agent : Str -> Bool
agent = |value| (value.starts_with("Organization: ") and value != "Organization: ") or (value.starts_with("Person: ") and value != "Person: ")

evidence : Sbom.Inventory, Sbom.Subject, Sbom.Context -> Str
evidence = |inventory, subject, context| Json.to_str({ profile: Sbom.profile, revision: context.revision, target: subject.target, coverage: inventory.coverage, inspected: inventory.inspected, dispositions: inventory.inputs })

component_comment : Sbom.Component -> Str
component_comment = |component| Json.to_str({ identity: component.identity, origin: component.origin, target: component.target, modifications: component.modified })

subject_comment : Sbom.Subject -> Str
subject_comment = |subject| Json.to_str({ target: subject.target, digest_kind: "final-deliverable-sha256" })

## The packages of a rendering, the subject first.
packages_of : Sbom.Inventory, Sbom.Subject -> List(Sbom.Package)
packages_of = |inventory, subject| inventory.components.map(|component| { id: component.id, name: component.name, version: component.version, supplier: component.producer, download: component.download, license: component.license, license_url: component.license_url, sha256: component.sha256, identity: if (component.identity.starts_with("pkg:")) component.identity else "", comment: component_comment(component) }).prepend({ id: subject_id, name: subject.filename, version: subject.version, supplier: "NOASSERTION", download: subject.url, license: "NOASSERTION", license_url: "", sha256: subject.sha256, identity: "", comment: subject_comment(subject) })

## SPDX 3.0.1

member : Str, JsonTree -> { key : Str, value : JsonTree }
member = |key, value| { key, value }

text : Str -> JsonTree
text = |value| JsonTree.Text(value)

texts : List(Str) -> JsonTree
texts = |values| JsonTree.Array(values.map(text))

## The members present when `condition` holds.
when : Bool, List({ key : Str, value : JsonTree }) -> List({ key : Str, value : JsonTree })
when = |condition, members| if (condition) members else []

spdx3 : Sbom.Inventory, Sbom.Subject, Sbom.Context -> JsonTree
spdx3 = |inventory, subject, context| {
	iri = |local| "${context.namespace}#${local}"
	creation = member("creationInfo", text("_:creationinfo"))
	element = |type, local, members| JsonTree.Object([member("type", text(type)), member("spdxId", text(iri(local))), creation].concat(members))
	listed_packages = packages_of(inventory, subject)
	agents = unique(listed_packages.map(|entry| entry.supplier).keep_if(agent).prepend(context.author))
	agent_local = |name| "spdx/agent/${(agents.find_first_index(|candidate| candidate == name) ?? 0).to_str()}"
	agent_nodes = agents.map(
		|name|
			if name.starts_with("Person: ") {
				element("Person", agent_local(name), [member("name", text(name.drop_prefix("Person: ")))])
			} else {
				element("Organization", agent_local(name), [member("name", text(name.drop_prefix("Organization: ")))])
			},
	)
	package_nodes = listed_packages.map(
		|entry| element(
			"software_Package",
			entry.id,
			[member("name", text(entry.name)), member("comment", text(entry.comment)), member("software_packageVersion", text(entry.version))]
				.concat(when(entry.download != "NOASSERTION", [member("software_downloadLocation", text(entry.download))]))
				.concat(when(entry.supplier != "NOASSERTION", [member("suppliedBy", text(iri(agent_local(entry.supplier))))]))
				.concat(when(!entry.identity.is_empty(), [member("software_packageUrl", text(entry.identity))]))
				.concat(when(!entry.sha256.is_empty(), [member("verifiedUsing", JsonTree.Array([JsonTree.Object([member("type", text("Hash")), member("algorithm", text("sha256")), member("hashValue", text(entry.sha256))])]))])),
		),
	)
	# One license element for each distinct expression and terms location.
	terms = |entry| "${entry.license} ${entry.license_url}"
	expressed = listed_packages.keep_if(|entry| entry.license != "NOASSERTION" and entry.license != "NONE").fold([], |all, entry| if (all.any(|seen| terms(seen) == terms(entry))) all else all.append(entry))
	license_local = |entry| "spdx/license/${(expressed.find_first_index(|seen| terms(seen) == terms(entry)) ?? 0).to_str()}"
	license_nodes = expressed.map(
		|entry| element(
			"simplelicensing_LicenseExpression",
			license_local(entry),
			[member("simplelicensing_licenseExpression", text(entry.license)), member("simplelicensing_licenseListVersion", text("3.26.0"))]
				.concat(when(!SbomLicenses.custom_ids(entry.license).is_empty() and entry.license_url != "NOASSERTION", [member("simplelicensing_customIdToUri", JsonTree.Array(SbomLicenses.custom_ids(entry.license).map(|id| JsonTree.Object([member("type", text("DictionaryEntry")), member("key", text(id)), member("value", text(entry.license_url))]))))])),
		),
	)
	declared = listed_packages.map(
		|entry| {
			license_target = if (entry.license == "NOASSERTION") "expandedlicensing_NoAssertionLicense" else if (entry.license == "NONE") "expandedlicensing_NoneLicense" else iri(license_local(entry))
			{ from: iri(entry.id), relation: "hasDeclaredLicense", scope: "", to: license_target, basis: "" }
		},
	)
	stated = declared.concat(inventory.relationships.map(|edge| { from: iri(edge.from), relation: edge.relation, scope: edge.scope, to: iri(edge.to), basis: edge.basis }))
	var $relationship_nodes = []
	for edge in stated {
		local = "spdx/relationship/${$relationship_nodes.len().to_str()}"
		$relationship_nodes = $relationship_nodes.append(
			element(
				if (edge.scope.is_empty()) "Relationship" else "LifecycleScopedRelationship",
				local,
				[member("from", text(edge.from)), member("relationshipType", text(edge.relation)), member("to", texts([edge.to]))]
					.concat(when(!edge.scope.is_empty(), [member("scope", text(edge.scope))]))
					.concat(when(!edge.basis.is_empty(), [member("comment", text(edge.basis))])),
			),
		)
	}
	contents = package_nodes.concat(license_nodes).concat($relationship_nodes)
	ids_of = |nodes| nodes.map(|node| (node.field("spdxId") ?? JsonTree.Null).text() ?? "")
	creation_info = JsonTree.Object([member("type", text("CreationInfo")), member("@id", text("_:creationinfo")), member("specVersion", text(Spdx3.version)), member("created", text(context.created)), member("createdBy", texts([iri(agent_local(context.author))])), member("createdUsing", texts([iri("spdx/tool")]))])
	tool = element("Tool", "spdx/tool", [member("name", text(context.generator.drop_prefix("Tool: ")))])
	data_license = element("simplelicensing_LicenseExpression", "spdx/license/data", [member("simplelicensing_licenseExpression", text("CC0-1.0")), member("simplelicensing_licenseListVersion", text("3.26.0"))])
	bom = element("software_Sbom", "spdx/sbom", [member("software_sbomType", texts(["build"])), member("rootElement", texts([iri(subject_id)])), member("element", texts(ids_of(contents)))])
	annotation = element("Annotation", "spdx/annotation", [member("annotationType", text("other")), member("contentType", text("application/json")), member("subject", text(iri("spdx/document"))), member("statement", text(evidence(inventory, subject, context)))])
	listed = agent_nodes.append(tool).append(bom).append(data_license).concat(contents).append(annotation)
	document = element("SpdxDocument", "spdx/document", [member("name", text(subject.filename)), member("dataLicense", text(iri("spdx/license/data"))), member("profileConformance", texts(["core", "simpleLicensing", "software"])), member("rootElement", texts([iri("spdx/sbom")])), member("element", texts(ids_of(listed)))])
	JsonTree.Object([member("@context", text(Spdx3.context)), member("@graph", JsonTree.Array(agent_nodes.prepend(creation_info).append(tool).append(document).append(bom).append(data_license).concat(contents).append(annotation)))])
}

read_spdx3 : List(Spdx3.Node) -> Try(Sbom.Document, Str)
read_spdx3 = |nodes| {
	documents = nodes.keep_if(|node| node.type == "SpdxDocument")
	document = match documents {
		[only] => only
		_ => return Err("an SPDX 3 document holds exactly one SpdxDocument")
	}
	namespace = match document.id.split_on("#") {
		[base, _] => base
		_ => return Err("SpdxDocument spdxId must be NAMESPACE#fragment")
	}
	local = |id| {
		fragment = id.drop_prefix("${namespace}#")
		if (id.starts_with("${namespace}#") and !fragment.is_empty() and !fragment.contains("#")) Ok(local_ref(fragment)) else Err("${id} is not NAMESPACE#name in the document namespace ${namespace}")
	}
	by_id = Lookup.index(nodes.keep_if(|node| !node.id.is_empty()).map(|node| { key: node.id, value: node }))
	field_text = |tree, key| (tree.field(key) ?? JsonTree.Null).text() ?? ""
	field_texts = |tree, key| ((tree.field(key) ?? JsonTree.Array([])).items() ?? []).map(|item| item.text() ?? "")
	declared = nodes.keep_if(|node| (node.type == "Relationship" or node.type == "LifecycleScopedRelationship") and field_text(node.tree, "relationshipType") == "hasDeclaredLicense")
	var $found = []
	for node in nodes.keep_if(|candidate| candidate.type == "software_Package") {
		id = local(node.id)?
		supplied = field_text(node.tree, "suppliedBy")
		supplied_by = match Lookup.find(by_id, supplied) {
			Ok(agent_node) => if (agent_node.type == "Person") "Person: ${field_text(agent_node.tree, "name")}" else "Organization: ${field_text(agent_node.tree, "name")}"
			Err(_) => if (supplied == "SpdxOrganization") "Organization: SPDX" else "NOASSERTION"
		}
		licenses = declared.keep_if(|relationship| field_text(relationship.tree, "from") == node.id).fold([], |all, relationship| all.concat(field_texts(relationship.tree, "to")))
		(license_text, license_url) = match licenses {
			[] | ["expandedlicensing_NoAssertionLicense"] => ("NOASSERTION", "")
			["expandedlicensing_NoneLicense"] => ("NONE", "")
			[expression_id] => {
				expression = (Lookup.find(by_id, expression_id) ?? { type: "", id: "", tree: JsonTree.Null }).tree
				value = field_text(expression, "simplelicensing_licenseExpression")
				first = SbomLicenses.custom_ids(value).first() ?? ""
				entries = (expression.field("simplelicensing_customIdToUri") ?? JsonTree.Array([])).items() ?? []
				(value, entries.find_first(|entry| field_text(entry, "key") == first).map_ok(|entry| field_text(entry, "value")) ?? (if (first.is_empty()) "" else "NOASSERTION"))
			}
			_ => return Err("package ${id} declares more than one license")
		}
		hashes = (node.tree.field("verifiedUsing") ?? JsonTree.Array([])).items() ?? []
		sha256 = hashes.find_first(|hash| field_text(hash, "algorithm") == "sha256").map_ok(|hash| field_text(hash, "hashValue")) ?? ""
		purl = match node.tree.field("software_packageUrl") {
			Ok(Text(value)) => value
			_ => ((node.tree.field("externalIdentifier") ?? JsonTree.Array([])).items() ?? []).find_first(|entry| field_text(entry, "externalIdentifierType") == "packageUrl").map_ok(|entry| field_text(entry, "identifier")) ?? ""
		}
		$found = $found.append({
			id,
			name: field_text(node.tree, "name"),
			version: field_text(node.tree, "software_packageVersion"),
			supplier: supplied_by,
			download: if (node.tree.field("software_downloadLocation").is_ok()) field_text(node.tree, "software_downloadLocation") else "NOASSERTION",
			license: license_text,
			license_url,
			sha256,
			identity: purl,
			comment: field_text(node.tree, "comment"),
		})
	}
	package_iris = nodes.keep_if(|node| node.type == "software_Package").map(|node| node.id)
	var $roots = []
	for root in field_texts(document.tree, "rootElement") {
		match Lookup.find(by_id, root) {
			Ok(node) if node.type == "software_Sbom" => {
				$roots = $roots.concat(field_texts(node.tree, "rootElement"))
			}
			_ => {
				$roots = $roots.append(root)
			}
		}
	}
	var $edges = []
	var $gaps = []
	for node in nodes.keep_if(|candidate| candidate.type == "Relationship" or candidate.type == "LifecycleScopedRelationship") {
		relation = field_text(node.tree, "relationshipType")
		from = field_text(node.tree, "from")
		destinations = field_texts(node.tree, "to")
		scope = field_text(node.tree, "scope")
		if relation == "describes" {
			$roots = $roots.concat(destinations)
		} else if relation == "hasDeclaredLicense" or relation == "hasConcludedLicense" {
			{}
		} else if !Sbom.relations.contains(relation) {
			$gaps = $gaps.concat(destinations.map(|_| "relationship of type ${relation}, which has no composition meaning"))
		} else if !scope.is_empty() and (relation != "dependsOn" or !Sbom.scopes.contains(scope)) {
			$gaps = $gaps.concat(destinations.map(|_| "${relation} relationship with lifecycle scope ${scope}"))
		} else {
			for destination in destinations {
				if !package_iris.contains(from) or !package_iris.contains(destination) {
					$gaps = $gaps.append("relationship to an element that is not a package")
				} else {
					$edges = $edges.append({ from: local(from)?, to: local(destination)?, relation, scope, basis: field_text(node.tree, "comment") })
				}
			}
		}
	}
	var $root_ids = []
	for root in unique($roots) {
		if package_iris.contains(root) {
			$root_ids = $root_ids.append(local(root)?)
		} else {
			$gaps = $gaps.append("described element that is not a package")
		}
	}
	files = nodes.keep_if(|node| node.type == "software_File").len()
	file_gaps = List.repeat("file", files)
	statements = nodes.keep_if(|node| node.type == "Annotation" and field_text(node.tree, "annotationType") == "other" and field_text(node.tree, "subject") == document.id).map(|node| field_text(node.tree, "statement"))
	Ok({ version: "SPDX-${Spdx3.version}", namespace, name: field_text(document.tree, "name"), roots: $root_ids, packages_: $found, relationships: $edges, evidence: statements, gaps: tally(file_gaps.concat($gaps)) })
}

## SPDX 2.3

## An SPDX 2 relationship stating `edge`: `dependsOn` with a lifecycle scope,
## and the relationships SPDX 3 names from the other end, reverse.
spdx2_relationship : Sbom.Edge -> { from : Str, to : Str, type : Str }
spdx2_relationship = |edge| {
	forward = |type| { from: edge.from, to: edge.to, type }
	reverse = |type| { from: edge.to, to: edge.from, type }
	match (edge.relation, edge.scope) {
		("contains", _) => forward("CONTAINS")
		("dependsOn", "build") => reverse("BUILD_DEPENDENCY_OF")
		("dependsOn", "test") => reverse("TEST_DEPENDENCY_OF")
		("dependsOn", "development") => reverse("DEV_DEPENDENCY_OF")
		("dependsOn", "runtime") => reverse("RUNTIME_DEPENDENCY_OF")
		("dependsOn", _) => forward("DEPENDS_ON")
		("generates", _) => forward("GENERATES")
		("patchedBy", _) => reverse("PATCH_FOR")
		("hasVariant", _) => reverse("VARIANT_OF")
		("copiedTo", _) => reverse("COPY_OF")
		_ => forward("OTHER")
	}
}

## The Composition spelling of an SPDX 2 relationship, or Missing when it
## has none.
from_spdx2 : Str, Str, Str, Str -> Try(Sbom.Edge, [Missing])
from_spdx2 = |from, type, to, basis| {
	forward = |relation, scope| Ok({ from, to, relation, scope, basis })
	reverse = |relation, scope| Ok({ from: to, to: from, relation, scope, basis })
	match type {
		"CONTAINS" => forward("contains", "")
		"CONTAINED_BY" => reverse("contains", "")
		"DEPENDS_ON" => forward("dependsOn", "")
		"DEPENDENCY_OF" => reverse("dependsOn", "")
		"BUILD_DEPENDENCY_OF" => reverse("dependsOn", "build")
		"TEST_DEPENDENCY_OF" => reverse("dependsOn", "test")
		"DEV_DEPENDENCY_OF" => reverse("dependsOn", "development")
		"RUNTIME_DEPENDENCY_OF" => reverse("dependsOn", "runtime")
		"GENERATES" => forward("generates", "")
		"GENERATED_FROM" => reverse("generates", "")
		"PATCH_FOR" => reverse("patchedBy", "")
		"VARIANT_OF" => reverse("hasVariant", "")
		"COPY_OF" => reverse("copiedTo", "")
		"OTHER" => forward("other", "")
		_ => Err(Missing)
	}
}

spdx2 : Sbom.Inventory, Sbom.Subject, Sbom.Context -> Str
spdx2 = |inventory, subject, context| {
	entries = packages_of(inventory, subject).map(
		|entry| Json.to_str({
			spdxid: "SPDXRef-${entry.id}",
			name: entry.name,
			versionInfo: entry.version,
			supplier: entry.supplier,
			downloadLocation: entry.download,
			filesAnalyzed: not_analyzed,
			licenseConcluded: "NOASSERTION",
			licenseDeclared: entry.license,
			copyrightText: "NOASSERTION",
			checksums: if (entry.sha256.is_empty()) [] else [{ algorithm: "SHA256", checksumValue: entry.sha256 }],
			comment: entry.comment,
			externalRefs: if (entry.identity.is_empty()) [] else [{ referenceCategory: "PACKAGE-MANAGER", referenceType: "purl", referenceLocator: entry.identity }],
		}).replace_each("\"spdxid\":", "\"SPDXID\":"),
	)
	relationships = inventory.relationships.map(
		|edge| {
			stated = spdx2_relationship(edge)
			Json.to_str({ spdxElementId: "SPDXRef-${stated.from}", relatedSpdxElement: "SPDXRef-${stated.to}", relationshipType: stated.type, comment: edge.basis })
		},
	).prepend(Json.to_str({ spdxElementId: "SPDXRef-DOCUMENT", relatedSpdxElement: "SPDXRef-${subject_id}", relationshipType: "DESCRIBES" }))
	annotation = Json.to_str({ annotationType: "OTHER", annotator: context.author, annotationDate: context.created, comment: evidence(inventory, subject, context) })
	var $licenses = []
	var $declared = []
	for component in inventory.components {
		for id in SbomLicenses.custom_ids(component.license) {
			if !$declared.contains(id) {
				$declared = $declared.append(id)
				$licenses = $licenses.append(Json.to_str({ licenseId: id, extractedText: "NOASSERTION", name: id, seeAlsos: if (component.license_url == "NOASSERTION") [] else [component.license_url] }))
			}
		}
	}
	"{\"spdxVersion\":\"SPDX-2.3\",\"dataLicense\":\"CC0-1.0\",\"SPDXID\":\"SPDXRef-DOCUMENT\",\"name\":${Json.to_str(subject.filename)},\"documentNamespace\":${Json.to_str(context.namespace)},\"creationInfo\":${Json.to_str({ created: context.created, creators: [context.author, context.generator], licenseListVersion: "3.26" })},\"packages\":[${Str.join_with(entries, ",")}],\"relationships\":[${Str.join_with(relationships, ",")}],\"annotations\":[${annotation}],\"hasExtractedLicensingInfos\":[${Str.join_with($licenses, ",")}] }\n"
}

read_spdx2 : JsonTree -> Try(Sbom.Document, Str)
read_spdx2 = |tree| {
	field_text = |object, key| (object.field(key) ?? JsonTree.Null).text() ?? ""
	listed = |object, key| (object.field(key) ?? JsonTree.Array([])).items() ?? []
	local = |id| id.drop_prefix("SPDXRef-")
	extracted = listed(tree, "hasExtractedLicensingInfos")
	listed_packages = listed(tree, "packages").map(
		|entry| {
			license_text = if (entry.field("licenseDeclared").is_ok()) field_text(entry, "licenseDeclared") else "NOASSERTION"
			first = SbomLicenses.custom_ids(license_text).first() ?? ""
			{
				id: local(field_text(entry, "SPDXID")),
				name: field_text(entry, "name"),
				version: field_text(entry, "versionInfo"),
				supplier: if (entry.field("supplier").is_ok()) field_text(entry, "supplier") else "NOASSERTION",
				download: field_text(entry, "downloadLocation"),
				license: license_text,
				license_url: match extracted.find_first(|info| field_text(info, "licenseId") == first).map_ok(|info| (listed(info, "seeAlsos").first() ?? JsonTree.Null).text() ?? "") {
					Ok(url) if !url.is_empty() => url
					_ => if (first.is_empty()) "" else "NOASSERTION"
				},
				sha256: listed(entry, "checksums").find_first(|checksum| field_text(checksum, "algorithm") == "SHA256").map_ok(|checksum| field_text(checksum, "checksumValue")) ?? "",
				identity: listed(entry, "externalRefs").find_first(|reference| ["PACKAGE-MANAGER", "PACKAGE_MANAGER"].contains(field_text(reference, "referenceCategory")) and field_text(reference, "referenceType") == "purl").map_ok(|reference| field_text(reference, "referenceLocator")) ?? "",
				comment: field_text(entry, "comment"),
			}
		},
	)
	package_ids = listed(tree, "packages").map(|entry| field_text(entry, "SPDXID"))
	files = listed(tree, "files").map(|_| "file").concat(listed(tree, "snippets").map(|_| "snippet"))

	## Why an endpoint is not a package of this document, if it is not.
	elsewhere : Str -> Try({}, Str)
	elsewhere = |id|
		if (package_ids.contains(id)) Ok({})
		else if (id == "SPDXRef-DOCUMENT") Err("relationship with the document itself")
		else if (id == "NONE" or id == "NOASSERTION") Err("relationship to ${id}")
		else if (id.starts_with("DocumentRef-")) Err("relationship into another SPDX document")
		else Err("relationship to a file or snippet")
	var $roots = []
	var $gaps = files
	for described in listed(tree, "documentDescribes").map(|item| item.text() ?? "") {
		if package_ids.contains(described) {
			$roots = $roots.append(local(described))
		} else {
			$gaps = $gaps.append("described element that is not a package")
		}
	}
	var $edges = []
	for relationship in listed(tree, "relationships") {
		from = field_text(relationship, "spdxElementId")
		type = field_text(relationship, "relationshipType")
		to = field_text(relationship, "relatedSpdxElement")
		described = if (from == "SPDXRef-DOCUMENT" and type == "DESCRIBES") Ok(to) else if (to == "SPDXRef-DOCUMENT" and type == "DESCRIBED_BY") Ok(from) else Err(NotDescribes)
		match described {
			Ok(subject) =>
				if package_ids.contains(subject) {
					$roots = $roots.append(local(subject))
				} else {
					$gaps = $gaps.append("described element that is not a package")
				}
			Err(_) =>
				match (elsewhere(from), elsewhere(to)) {
					(Ok(_), Ok(_)) =>
						match from_spdx2(local(from), type, local(to), field_text(relationship, "comment")) {
							Ok(edge) => {
								$edges = $edges.append(edge)
							}
							Err(Missing) => {
								$gaps = $gaps.append("relationship of type ${type}, which has no composition meaning")
							}
						}
					(Err(reason), _) => {
						$gaps = $gaps.append(reason)
					}
					(_, Err(reason)) => {
						$gaps = $gaps.append(reason)
					}
				}
		}
	}
	statements = listed(tree, "annotations").keep_if(|annotation| field_text(annotation, "annotationType") == "OTHER").map(|annotation| field_text(annotation, "comment"))
	Ok({ version: field_text(tree, "spdxVersion"), namespace: field_text(tree, "documentNamespace"), name: field_text(tree, "name"), roots: unique($roots), packages_: listed_packages, relationships: $edges, evidence: statements, gaps: tally($gaps) })
}

resolve : Sbom.Component, Lock -> Try(Sbom.Component, Str)
resolve = |component, lock| {
	if component.origin == "reviewed" {
		return Ok(component)
	}
	if component.origin.starts_with("source:") {
		name = component.origin.drop_prefix("source:")
		source = lock.sources.find_first(|candidate| candidate.name == name).map_err(|_| "unresolved locked source")?
		locked_version = if (source.rev.is_empty()) source.digest else source.rev
		# A flat file's pin is its digest alone, so the release version a
		# reviewer states is supplemental, as it is for a fetched program; a
		# revision or tree pin states its own version.
		file = source.provider == "file"
		version = if (file and !component.version.is_empty()) component.version else locked_version
		stable_identity = "urn:blueprint:source:${source.name}:${source.rev}:${source.digest}"
		if (!file and !component.version.is_empty() and component.version != locked_version) or (!component.download.is_empty() and component.download != source.ref) or (!component.identity.is_empty() and component.identity != stable_identity and component.identity != "${source.ref}@${source.rev}#${source.digest}") {
			return Err("supplemental metadata conflicts with locked source")
		}
		var $digest = ""
		if source.provider == "file" {
			$digest = source.digest.drop_prefix("sha256:")
			if !source.digest.starts_with("sha256:") or !hex($digest) or (!component.sha256.is_empty() and component.sha256 != $digest) {
				return Err("supplemental file SHA-256 conflicts with authoritative flat file pin")
			}
		} else if !component.sha256.is_empty() {
			return Err("tree identity is not an archive SHA-256")
		}
		canonical = if source.ref.starts_with("github:") and !source.rev.is_empty() {
			parts = source.ref.drop_prefix("github:").split_on("/")
			"https://github.com/${Str.join_with(parts.take_first(2), "/")}/tree/${source.rev}"
		} else if (source.ref.starts_with("tarball+https://")) source.ref.drop_prefix("tarball+") else if (uri(source.ref)) source.ref else "NOASSERTION"
		return Ok({ ..component, version, sha256: $digest, download: canonical, identity: stable_identity })
	}
	if component.origin.starts_with("program:") {
		entry = lock.fetched.find_first(|candidate| component.origin == "program:${candidate.name}:${candidate.system}").map_err(|_| "unresolved locked program")?
		stable_identity = "urn:blueprint:fetched:${entry.name}:${entry.system}:${entry.sha256}"
		if (!component.sha256.is_empty() and component.sha256 != entry.sha256) or (!component.download.is_empty() and !entry.urls.contains(component.download)) or (!component.target.is_empty() and component.target != entry.system) or (!component.identity.is_empty() and component.identity != stable_identity) {
			return Err("supplemental metadata conflicts with locked program")
		}
		return Ok({ ..component, version: if (component.version.is_empty()) "sha256-${entry.sha256}" else component.version, sha256: entry.sha256, download: if (component.download.is_empty()) (entry.urls.first() ?? "NOASSERTION") else component.download, identity: stable_identity, target: entry.system })
	}
	Err("unknown component origin; use reviewed or an authoritative lock reference")
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
	# An identity names something and is never fetched, so it may be http.
	if value.starts_with("http://") {
		return uri("https://${value.drop_prefix("http://")}")
	}
	# A versioned package URL; qualifiers after `?` (such as `?arch=`) are allowed.
	if value.starts_with("pkg:") {
		return !value.contains("\\") and !value.contains(" ") and (value.split_on("?").first() ?? "").contains("@")
	}
	if value.starts_with("urn:") {
		return !value.contains(" ") and !value.contains("\\") and !value.contains("?")
	}
	# Source identity is the provider reference + immutable revision + tree digest.
	value.starts_with("github:") and !value.contains("?") and !value.contains(" ") and value.contains("#sha256-")
}

supplier : Str -> Bool
supplier = |value| value == "NOASSERTION" or agent(value)

license : Str -> Bool
license = |value| value == "NOASSERTION" or value == "NONE" or SbomLicenses.expression(value)

# Import inert, caller-supplied bytes only. Namespace and checksum are distinct
# identities; imports never download a URI or execute a document's contents.
expand_import : Sbom.Imported, Str, Try(Sbom.Component, [Unbound]) -> Try({ components : List(Sbom.Component), relationships : List(Sbom.Edge), coverage : Sbom.Coverage }, Str)
expand_import = |imported, target, binding| {
	if !valid_id(imported.id) or !uri(imported.url) or !namespace_identity(imported.namespace) or !hex(imported.sha256) or !Sbom.json_within_bounds(imported.document) or imported.contact.is_empty() or imported.basis.is_empty() or !Sbom.relations.contains(imported.relation) {
		return Err("invalid or oversized imported reference")
	}
	if target != "source" and imported.target != target {
		return Err("import target differs from subject")
	}
	if Crypto.SHA256.hash(imported.document.to_utf8()).to_hex() != imported.sha256 {
		return Err("imported SBOM content digest mismatch")
	}
	decoded = Sbom.read(imported.document).map_err(|problem| "imported SBOM outside the supported profile: ${problem}")?
	if decoded.namespace != imported.namespace or decoded.packages_.is_empty() or decoded.packages_.len() > 4096 or decoded.relationships.len() > 16384 {
		return Err("invalid imported document identity or bounds")
	}
	ids = decoded.packages_.map(|entry| entry.id)
	if unique(ids).len() != ids.len() or ids.any(|id| id != subject_id and !valid_id(id)) {
		return Err("duplicate/invalid imported component identifier")
	}
	if decoded.roots.is_empty() {
		return Err("imported SBOM lacks a described subject")
	}
	map_id = |id| "${imported.id}-${id}"
	var $edges = []
	for root_id in decoded.roots {
		root = decoded.packages_.find_first(|entry| entry.id == root_id).map_err(|_| "missing imported subject")?
		# A subject bound to a resolved artifact needs its digest; an unbound
		# one, such as a source tree's, may state none.
		digest_ok = hex(root.sha256) or (binding.is_err() and root.sha256.is_empty())
		if root.name != imported.subject.filename or root.version != imported.subject.version or root.sha256 != imported.subject.sha256 or !digest_ok {
			return Err("import subject filename/version/SHA256 mismatch")
		}
		root_comment : Try({ target : Str }, _)
		root_comment = Json.parse(if (root.comment.is_empty()) "{}" else root.comment)
		match root_comment {
			Ok(metadata) => if metadata.target != imported.target {
				return Err("imported document subject target mismatch")
			}
			Err(_) => {}
		}
		match binding {
			Ok(component) => {
				if component.sha256.is_empty() or component.sha256 != root.sha256 or component.version != root.version or (!component.target.is_empty() and component.target != imported.target) {
					return Err("imported subject conflicts with authoritative component artifact")
				}
				$edges = $edges.append({ from: map_id(root.id), to: component.id, relation: "copiedTo", scope: "", basis: "Artifact identity, version and target match resolved input; ${imported.basis}" })
			}
			Err(Unbound) => {
				$edges = $edges.append({ from: subject_id, to: map_id(root.id), relation: imported.relation, scope: "", basis: "UNBOUND upstream artifact statement; ${imported.basis}" })
			}
		}
	}
	for edge in decoded.relationships {
		if !ids.contains(edge.from) or !ids.contains(edge.to) {
			return Err("dangling/external imported relationship; provide referenced graph explicitly")
		}
		$edges = $edges.append({ ..edge, from: map_id(edge.from), to: map_id(edge.to), basis: if (edge.basis.is_empty()) "Verified imported ${decoded.version} relationship" else edge.basis })
	}
	# A package URL two imported packages share stays with the first.
	var $claimed = []
	var $shared = []
	for entry in decoded.packages_ {
		purl = normalized(entry).kept.identity
		if !purl.is_empty() and $claimed.contains(purl) {
			$shared = $shared.append(entry.id)
		} else {
			$claimed = $claimed.append(purl)
		}
	}
	components = decoded.packages_.map(
		|entry| {
			found = normalized(entry)
			kept = if ($shared.contains(entry.id)) { kept: { ..found.kept, identity: "" }, notes: found.notes.append("package URL ${found.kept.identity} is shared with another imported package") } else found
			fallback = "${imported.namespace}#${entry.id}"
			{ id: map_id(entry.id), name: kept.kept.name, version: kept.kept.version, producer: kept.kept.supplier, download: kept.kept.download, license: kept.kept.license, license_url: kept.kept.license_url, sha256: kept.kept.sha256, identity: if (kept.kept.identity.is_empty()) fallback else kept.kept.identity, origin: "reviewed", target: imported.target, modified: "Imported ${imported.namespace}#${entry.id} from ${imported.url}; document SHA256 ${imported.sha256}; upstream metadata ${if (entry.comment.is_empty()) "NOASSERTION" else entry.comment}${Str.join_with(kept.notes.map(|note| "; ${note}"), "")}" }
		},
	)
	# One LicenseRef- names one terms location in a document, so a later
	# package that gives another location for it keeps the first.
	var $terms = []
	var $unified = []
	for component in components {
		custom = SbomLicenses.custom_ids(component.license)
		earlier = $terms.find_first(|entry| custom.contains(entry.id) and entry.url != component.license_url)
		match earlier {
			Ok(first) => {
				$unified = $unified.append({ ..component, license_url: first.url, modified: "${component.modified}; terms location ${component.license_url} replaced by ${first.url}, which the document gave ${first.id} first" })
			}
			Err(_) => {
				$terms = $terms.concat(custom.keep_if(|id| !$terms.any(|entry| entry.id == id)).map(|id| { id, url: component.license_url }))
				$unified = $unified.append(component)
			}
		}
	}
	match $unified.find_first(|component| leaks(Json.to_str(component))) {
		Ok(component) => return Err("imported component ${component.id} names an absolute developer path or a credential; it cannot be published")
		Err(_) => {}
	}
	verified = if (binding.is_ok()) "Document digest and upstream subject artifact identity match; completeness and undisclosed closure remain unverified" else "Document integrity verified; upstream subject not bound to a resolved artifact, so composition claims remain unverified"
	omitted = if (decoded.gaps.is_empty()) "" else ". Not imported from ${decoded.version}: ${Str.join_with(decoded.gaps, "; ")}"
	Ok({ components: $unified, relationships: $edges, coverage: { scope: "import:${imported.id}", status: "incomplete", reason: "${verified}${omitted}", contact: imported.contact } })
}

# Keep JSON boolean nominal rather than an inferred single tag.
not_analyzed : Bool
not_analyzed = False

## CycloneDX 1.7

property : Str, Str -> JsonTree
property = |name, value| JsonTree.Object([member("name", text(name)), member("value", text(value))])

## An RFC 4122 URN for the document revision: the first 128 bits of the
## namespace's SHA-256, marked as a version 8 (custom) UUID.
serial_number : Str -> Str
serial_number = |namespace| {
	digits = Crypto.SHA256.hash(namespace.to_utf8()).to_hex().to_utf8().take_first(32)
	variant = when_digit(digits.get(16) ?? '0')
	marked = digits.take_first(12).append('8').concat(digits.sublist({ start: 13, len: 3 })).append(variant).concat(digits.drop_first(17))
	part = |start, len| Str.from_utf8_lossy(marked.sublist({ start, len }))
	"urn:uuid:${part(0, 8)}-${part(8, 4)}-${part(12, 4)}-${part(16, 4)}-${part(20, 12)}"
}

## The RFC 4122 variant digit (8, 9, a or b) for a hex digit.
when_digit : U8 -> U8
when_digit = |digit| {
	value = if (digit >= 'a') digit - 'a' + 10 else digit - '0'
	"89ab".to_utf8().get((value % 4).to_u64()) ?? '8'
}

## Components the subject reaches through contained or runtime edges.
shipped : List(Sbom.Edge) -> List(Str)
shipped = |relationships| {
	var $found = [subject_id]
	var $changed = True
	while $changed {
		$changed = False
		for edge in relationships {
			carries = edge.relation == "contains" or (edge.relation == "dependsOn" and (edge.scope.is_empty() or edge.scope == "runtime"))
			if carries and $found.contains(edge.from) and !$found.contains(edge.to) {
				$found = $found.append(edge.to)
				$changed = True
			}
		}
	}
	$found
}

cyclonedx_scope : List(Sbom.Edge), List(Str), Str -> Str
cyclonedx_scope = |relationships, required, id|
	if required.contains(id) {
		"required"
	} else if relationships.any(|edge| edge.to == id and edge.relation == "dependsOn" and ["build", "test", "development"].contains(edge.scope)) {
		"excluded"
	} else {
		"optional"
	}

## Who supplied something, in CycloneDX: an organization is a supplier, a
## person an author.
supplied : Str -> List({ key : Str, value : JsonTree })
supplied = |producer|
	if producer.starts_with("Organization: ") {
		[member("supplier", JsonTree.Object([member("name", text(producer.drop_prefix("Organization: ")))]))]
	} else if producer.starts_with("Person: ") {
		[member("authors", JsonTree.Array([JsonTree.Object([member("name", text(producer.drop_prefix("Person: ")))])]))]
	} else {
		[]
	}

sha256_hashes : Str -> List({ key : Str, value : JsonTree })
sha256_hashes = |digest| when(!digest.is_empty(), [member("hashes", JsonTree.Array([JsonTree.Object([member("alg", text("SHA-256")), member("content", text(digest))])]))])

references : List({ type : Str, url : Str }) -> List({ key : Str, value : JsonTree })
references = |listed| when(!listed.is_empty(), [member("externalReferences", JsonTree.Array(listed.map(|reference| JsonTree.Object([member("type", text(reference.type)), member("url", text(reference.url))]))))])

cyclonedx : Sbom.Inventory, Sbom.Subject, Sbom.Context -> JsonTree
cyclonedx = |inventory, subject, context| {
	required = shipped(inventory.relationships)
	expression = |license_text| license_text != "NOASSERTION" and license_text != "NONE"
	components = inventory.components.map(
		|component|
			JsonTree.Object(
				[member("type", text("library")), member("bom-ref", text(component.id)), member("name", text(component.name)), member("version", text(component.version))]
					.concat(supplied(component.producer))
					.append(member("scope", text(cyclonedx_scope(inventory.relationships, required, component.id))))
					.concat(sha256_hashes(component.sha256))
					.concat(when(expression(component.license), [member("licenses", JsonTree.Array([JsonTree.Object([member("expression", text(component.license))])]))]))
					.concat(when(component.identity.starts_with("pkg:"), [member("purl", text(component.identity))]))
					.concat(
						references(
							(if (component.download == "NOASSERTION") [] else [{ type: "distribution", url: component.download }])
								.concat(if (component.license.contains("LicenseRef-") and !component.license_url.is_empty() and component.license_url != "NOASSERTION") [{ type: "license", url: component.license_url }] else []),
						),
					)
					.append(member("properties", JsonTree.Array([property("blueprint:identity", component.identity), property("blueprint:origin", component.origin), property("blueprint:target", component.target), property("blueprint:modifications", component.modified)].concat(if (component.license == "NONE") [property("blueprint:license", "NONE")] else [])))),
			),
	)
	metadata_component = JsonTree.Object(
		[member("type", text("file")), member("bom-ref", text(subject_id)), member("name", text(subject.filename)), member("version", text(subject.version))]
			.concat(sha256_hashes(subject.sha256))
			.concat(references(if (subject.url == "NOASSERTION") [] else [{ type: "distribution", url: subject.url }]))
			.append(member("properties", JsonTree.Array([property("blueprint:target", subject.target), property("blueprint:digest-kind", "final-deliverable-sha256")]))),
	)
	creator = if context.author.starts_with("Person: ") {
		member("authors", JsonTree.Array([JsonTree.Object([member("name", text(context.author.drop_prefix("Person: ")))])]))
	} else {
		member("manufacturer", JsonTree.Object([member("name", text(context.author.drop_prefix("Organization: ")))]))
	}
	metadata = JsonTree.Object([
		member("timestamp", text(context.created)),
		member("lifecycles", JsonTree.Array([JsonTree.Object([member("phase", text("build"))])])),
		member("tools", JsonTree.Object([member("components", JsonTree.Array([JsonTree.Object([member("type", text("application")), member("name", text(context.generator.drop_prefix("Tool: ")))])]))])),
		creator,
		member("component", metadata_component),
		member("properties", JsonTree.Array([property("blueprint:namespace", context.namespace), property("blueprint:evidence", evidence(inventory, subject, context))])),
	])
	dependencies = inventory.components.map(|component| component.id).prepend(subject_id).map(
		|ref| {
			depends = unique(inventory.relationships.keep_if(|edge| edge.from == ref and (edge.relation == "contains" or edge.relation == "dependsOn")).map(|edge| edge.to))
			JsonTree.Object([member("ref", text(ref))].concat(when(!depends.is_empty(), [member("dependsOn", texts(depends))])))
		},
	)
	revision = U64.from_str(context.revision) ?? 1
	JsonTree.Object([
		member("bomFormat", text(CycloneDx.format)),
		member("specVersion", text(CycloneDx.version)),
		member("serialNumber", text(serial_number(context.namespace))),
		member("version", JsonTree.Num(Dec.from_str((if (revision == 0) 1 else revision).to_str()) ?? 1)),
		member("metadata", metadata),
		member("components", JsonTree.Array(components)),
		member("dependencies", JsonTree.Array(dependencies)),
		member("properties", JsonTree.Array(inventory.relationships.map(|edge| property("blueprint:relationship", Json.to_str(edge))))),
	])
}

read_bom : JsonTree -> Try(Sbom.Document, Str)
read_bom = |tree| {
	field_text = |object, key| (object.field(key) ?? JsonTree.Null).text() ?? ""
	listed = |object, key| (object.field(key) ?? JsonTree.Array([])).items() ?? []
	values = |object, name| listed(object, "properties").keep_if(|entry| field_text(entry, "name") == name).map(|entry| field_text(entry, "value"))
	only = |object, name|
		match values(object, name) {
			[value] => Ok(value)
			_ => Err("expected exactly one ${name} property; this is not a BOM Blueprint wrote")
		}
	metadata = tree.field("metadata") ?? JsonTree.Null
	subject = metadata.field("component").map_err(|_| "the BOM describes no component")?
	if field_text(subject, "bom-ref") != subject_id {
		return Err("the described component must be ${subject_id}")
	}
	reference = |object, type| listed(object, "externalReferences").find_first(|entry| field_text(entry, "type") == type).map_ok(|entry| field_text(entry, "url"))
	digest = |object| listed(object, "hashes").find_first(|entry| field_text(entry, "alg") == "SHA-256").map_ok(|entry| field_text(entry, "content")) ?? ""
	supplier_of = |object|
		match object.field("supplier") {
			Ok(entity) => "Organization: ${field_text(entity, "name")}"
			Err(_) =>
				match listed(object, "authors") {
					[author, ..] => "Person: ${field_text(author, "name")}"
					[] => "NOASSERTION"
				}
		}
	subject_package = {
		id: subject_id,
		name: field_text(subject, "name"),
		version: field_text(subject, "version"),
		supplier: "NOASSERTION",
		download: reference(subject, "distribution") ?? "NOASSERTION",
		license: "NOASSERTION",
		license_url: "",
		sha256: digest(subject),
		identity: "",
		comment: Json.to_str({ target: only(subject, "blueprint:target")?, digest_kind: only(subject, "blueprint:digest-kind")? }),
	}
	var $found = [subject_package]
	for component in listed(tree, "components") {
		license_text = match listed(component, "licenses") {
			[choice] => field_text(choice, "expression")
			[] => if (values(component, "blueprint:license") == ["NONE"]) "NONE" else "NOASSERTION"
			_ => return Err("a component states more than one license choice")
		}
		$found = $found.append({
			id: field_text(component, "bom-ref"),
			name: field_text(component, "name"),
			version: field_text(component, "version"),
			supplier: supplier_of(component),
			download: reference(component, "distribution") ?? "NOASSERTION",
			license: license_text,
			license_url: reference(component, "license") ?? (if (license_text.contains("LicenseRef-")) "NOASSERTION" else ""),
			sha256: digest(component),
			identity: field_text(component, "purl"),
			comment: Json.to_str({ identity: only(component, "blueprint:identity")?, origin: only(component, "blueprint:origin")?, target: only(component, "blueprint:target")?, modifications: only(component, "blueprint:modifications")? }),
		})
	}
	var $edges = []
	for value in values(tree, "blueprint:relationship") {
		decoded : Try(Sbom.Edge, _)
		decoded = Json.parse(value)
		$edges = $edges.append(decoded.map_err(|_| "a blueprint:relationship property is not a relationship")?)
	}
	ids = $found.map(|entry| entry.id)
	if $edges.any(|edge| !ids.contains(edge.from) or !ids.contains(edge.to) or !Sbom.relations.contains(edge.relation)) {
		return Err("a blueprint:relationship names an unknown component or relation")
	}
	if $edges.any(|edge| !edge.scope.is_empty() and (edge.relation != "dependsOn" or !Sbom.scopes.contains(edge.scope))) {
		return Err("a blueprint:relationship has a lifecycle scope outside dependsOn")
	}
	for dependency in listed(tree, "dependencies") {
		ref = field_text(dependency, "ref")
		stated = listed(dependency, "dependsOn").map(|item| item.text() ?? "")
		implied = unique($edges.keep_if(|edge| edge.from == ref and (edge.relation == "contains" or edge.relation == "dependsOn")).map(|edge| edge.to))
		if stated != implied {
			return Err("the dependencies of ${ref} differ from its relationships")
		}
	}
	if listed(tree, "dependencies").len() != ids.len() {
		return Err("every component needs a dependency entry")
	}
	# The standard fields must say what the relationships say, so a reader of
	# plain CycloneDX learns the same thing this reader does.
	required = shipped($edges)
	for component in listed(tree, "components") {
		ref = field_text(component, "bom-ref")
		if field_text(component, "scope") != cyclonedx_scope($edges, required, ref) {
			return Err("the scope of ${ref} differs from its relationships")
		}
	}
	Ok({ version: "${CycloneDx.format}-${CycloneDx.version}", namespace: only(metadata, "blueprint:namespace")?, name: subject_package.name, roots: [subject_id], packages_: $found, relationships: $edges, evidence: values(metadata, "blueprint:evidence"), gaps: [] })
}

## Each distinct reason once, with how many times it occurred, in byte order.
tally : List(Str) -> List(Str)
tally = |reasons| {
	sorted = reasons.sort_with(Project.bytewise)
	var $out = []
	var $current = ""
	var $count = 0.U64
	for reason in sorted {
		if reason == $current {
			$count = $count + 1
		} else {
			if $count > 0 {
				$out = $out.append("${$count.to_str()} × ${$current}")
			}
			$current = reason
			$count = 1
		}
	}
	if $count > 0 {
		$out = $out.append("${$count.to_str()} × ${$current}")
	}
	$out
}

expect tally(["b", "a", "b"]) == ["1 × a", "2 × b"] and tally([]) == []

## An imported package with every field the profile can carry, and a note
## for each value it had to replace: a missing version or name, a download
## location that is not an HTTPS URL the profile accepts, a license that is
## not an SPDX expression, a custom license with no terms location, or a
## package URL without a version.
normalized : Sbom.Package -> { kept : Sbom.Package, notes : List(Str) }
normalized = |entry| {
	var $notes = []
	var $package = entry
	if entry.name.trim().is_empty() {
		$package = { ..$package, name: "NOASSERTION" }
		$notes = $notes.append("no name stated")
	}
	if entry.version.trim().is_empty() {
		$package = { ..$package, version: "NOASSERTION" }
		$notes = $notes.append("no version stated")
	}
	if !uri(entry.download) {
		$package = { ..$package, download: "NOASSERTION" }
		$notes = $notes.append("download location ${Json.to_str(entry.download)} is not an HTTPS URL this profile accepts")
	}
	if !supplier(entry.supplier) {
		$package = { ..$package, supplier: "NOASSERTION" }
		$notes = $notes.append("supplier ${Json.to_str(entry.supplier)} is not an SPDX agent")
	}
	if !license(entry.license) {
		$package = { ..$package, license: "NOASSERTION", license_url: "" }
		$notes = $notes.append("license ${Json.to_str(entry.license)} is not an SPDX license expression")
	} else if entry.license.contains("LicenseRef-") and !(entry.license_url != "NOASSERTION" and uri(entry.license_url) and !entry.license_url.is_empty()) {
		$package = { ..$package, license_url: "NOASSERTION" }
		if entry.license_url != "NOASSERTION" {
			$notes = $notes.append("no usable terms location for ${entry.license}")
		}
	} else if !entry.license.contains("LicenseRef-") {
		$package = { ..$package, license_url: "" }
	}
	if !entry.identity.is_empty() and !identity(entry.identity) {
		$package = { ..$package, identity: "" }
		$notes = $notes.append("package URL ${Json.to_str(entry.identity)} is not a versioned purl")
	}
	if !entry.sha256.is_empty() {
		lowered = Str.from_utf8_lossy(entry.sha256.to_utf8().map(|byte| if (byte >= 'A' and byte <= 'F') byte + 32 else byte))
		if hex(lowered) {
			$package = { ..$package, sha256: lowered }
		} else {
			$package = { ..$package, sha256: "" }
			$notes = $notes.append("SHA-256 ${Json.to_str(entry.sha256)} is not 64 hex digits")
		}
	}
	{ kept: $package, notes: $notes }
}

## CycloneDX from elsewhere

## A local identifier for a `bom-ref`: its own characters where they are
## allowed, and a hash of it when any had to change, so distinct references
## stay distinct.
local_ref : Str -> Str
local_ref = |ref| {
	kept = Str.from_utf8_lossy(ref.to_utf8().map(|byte| if ((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.') byte else '-'))
	trimmed = Str.from_utf8_lossy(kept.to_utf8().take_first(64))
	if (kept == ref and !ref.is_empty() and kept.to_utf8().len() <= 64) ref else "${if (trimmed.is_empty()) "ref" else trimmed}-${Str.from_utf8_lossy(Crypto.SHA256.hash(ref.to_utf8()).to_hex().to_utf8().take_first(12))}"
}

Flat : { tree : JsonTree, parent : Str, id : Str }

## Every component of a tree of components, with its parent's local id.
flatten : List(JsonTree), Str, Str -> List(Flat)
flatten = |trees, parent, prefix| {
	var $out = []
	var $index = 0.U64
	for tree in trees {
		position = "${prefix}${$index.to_str()}"
		id = match tree.field("bom-ref") {
			Ok(Text(ref)) => local_ref(ref)
			_ => "component-${position}"
		}
		$out = $out.append({ tree, parent, id }).concat(flatten((tree.field("components") ?? JsonTree.Array([])).items() ?? [], id, "${position}."))
		$index = $index + 1
	}
	$out
}

read_foreign_bom : JsonTree, List(Str) -> Try(Sbom.Document, Str)
read_foreign_bom = |tree, ignored| {
	field_text = |object, key| (object.field(key) ?? JsonTree.Null).text() ?? ""
	listed = |object, key| (object.field(key) ?? JsonTree.Array([])).items() ?? []
	serial = field_text(tree, "serialNumber")
	if serial.is_empty() {
		return Err("an imported CycloneDX BOM needs a serialNumber to identify it")
	}
	metadata = tree.field("metadata") ?? JsonTree.Null
	described = match metadata.field("component") {
		Ok(component) => [component]
		Err(_) => []
	}
	roots = flatten(described, "", "root-")
	entries = roots.concat(flatten(listed(tree, "components"), "", ""))
	ids = entries.map(|entry| entry.id)
	if unique(ids).len() != ids.len() {
		return Err("two components map to one identifier")
	}
	refs = Lookup.index(entries.keep_if(|entry| (entry.tree.field("bom-ref") ?? JsonTree.Null).text().is_ok()).map(|entry| { key: field_text(entry.tree, "bom-ref"), value: entry.id }))
	var $gaps = ignored
	var $packages = []
	for entry in entries {
		component = entry.tree
		choices = listed(component, "licenses")
		expressions = choices.keep_if(|choice| choice.field("expression").is_ok()).map(|choice| field_text(choice, "expression"))
		licensed = choices.keep_if(|choice| choice.field("license").is_ok()).map(|choice| component_license(choice.field("license") ?? JsonTree.Null))
		license_text = match (expressions, licensed) {
			([], []) => "NOASSERTION"
			([expression], []) => expression
			([], _) if licensed.all(|id| !id.is_empty()) => Str.join_with(licensed, " AND ")
			_ => {
				$gaps = $gaps.append("license stated only by name")
				"NOASSERTION"
			}
		}
		supplier_name = field_text(component.field("supplier") ?? JsonTree.Null, "name")
		maker = field_text(component.field("manufacturer") ?? JsonTree.Null, "name")
		author = field_text(listed(component, "authors").first() ?? JsonTree.Null, "name")
		$packages = $packages.append({
			id: entry.id,
			name: field_text(component, "name"),
			version: field_text(component, "version"),
			supplier: if (!supplier_name.is_empty()) "Organization: ${supplier_name}" else if (!maker.is_empty()) "Organization: ${maker}" else if (!author.is_empty()) "Person: ${author}" else "NOASSERTION",
			download: listed(component, "externalReferences").find_first(|reference| field_text(reference, "type") == "distribution").map_ok(|reference| field_text(reference, "url")) ?? "NOASSERTION",
			license: license_text,
			license_url: listed(component, "externalReferences").find_first(|reference| field_text(reference, "type") == "license").map_ok(|reference| field_text(reference, "url")) ?? "",
			sha256: listed(component, "hashes").find_first(|hash| field_text(hash, "alg") == "SHA-256").map_ok(|hash| field_text(hash, "content")) ?? "",
			identity: field_text(component, "purl"),
			comment: Json.to_str({ type: field_text(component, "type"), scope: field_text(component, "scope") }),
		})
	}
	var $edges = []
	for entry in entries {
		if !entry.parent.is_empty() {
			$edges = $edges.append({ from: entry.parent, to: entry.id, relation: "contains", scope: "", basis: "Nested in the CycloneDX component tree" })
		}
	}
	for dependency in listed(tree, "dependencies") {
		from = Lookup.find(refs, field_text(dependency, "ref"))
		for target in listed(dependency, "dependsOn").map(|item| item.text() ?? "") {
			match (from, Lookup.find(refs, target)) {
				(Ok(source), Ok(destination)) => {
					$edges = $edges.append({ from: source, to: destination, relation: "dependsOn", scope: "", basis: "CycloneDX dependency; CycloneDX states no lifecycle scope for it" })
				}
				_ => {
					$gaps = $gaps.append("dependency of or on a service")
				}
			}
		}
	}
	# Listing a component in a BOM places it in the inventory the BOM
	# describes, without saying how. One nothing connects to the described
	# component is related to it as `other`, which claims no containment.
	root_ids = roots.keep_if(|root| root.parent.is_empty()).map(|root| root.id)
	var $reached = root_ids
	var $changed = True
	while $changed {
		$changed = False
		for edge in $edges {
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
	for root in root_ids {
		for entry in entries.keep_if(|candidate| candidate.parent.is_empty() and !root_ids.contains(candidate.id) and !$reached.contains(candidate.id)) {
			$edges = $edges.append({ from: root, to: entry.id, relation: "other", scope: "", basis: "Listed in the CycloneDX BOM's components; the BOM states no relationship to the described component" })
		}
	}
	Ok({ version: "${CycloneDx.format}-${field_text(tree, "specVersion")}", namespace: serial, name: roots.first().map_ok(|root| field_text(root.tree, "name")) ?? "", roots: roots.keep_if(|root| root.parent.is_empty()).map(|root| root.id), packages_: $packages, relationships: $edges, evidence: [], gaps: tally($gaps) })
}

## An SPDX identifier for a CycloneDX license object, or "" when it names its
## license only in text.
component_license : JsonTree -> Str
component_license = |license_object|
	match license_object.field("id") {
		Ok(Text(id)) if SbomLicenses.licenses.contains(id) => id
		_ => ""
	}

expect local_ref("c0") == "c0" and local_ref("Subject") == "Subject" and local_ref("pkg:cargo/a@1?x=y").starts_with("pkg-cargo-a-1-x-y-") and local_ref("pkg:cargo/a@1?x=y") != local_ref("pkg:cargo/a@1?x=z")

## A document's identity: an SPDX namespace URI or a CycloneDX serial number.
## It names the document and is never fetched, so `http` is allowed, but
## credentials, queries and whitespace are not.
namespace_identity : Str -> Bool
namespace_identity = |value| CycloneDx.serial_number(value) or (value != "NOASSERTION" and (uri(value) or (value.starts_with("http://") and uri("https://${value.drop_prefix("http://")}"))))

expect namespace_identity("http://trivy.dev/filesystem/src-1") and namespace_identity("urn:uuid:3e671687-395b-41f5-a30f-a58921a69b79") and !namespace_identity("http://user:pw@example.org/x") and !namespace_identity("NOASSERTION")
