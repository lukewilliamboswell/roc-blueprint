import core.Spec
import core.Lock
import core.Project
import core.JsonData
import core.Sbom
import core.Spdx2
import core.Spdx3
import core.CycloneDx
import "../../tests/sbom/fixtures/input/Spec" as fixture_input_spec : Str
import "../../tests/sbom/fixtures/input/Lock" as fixture_input_lock : Str
import "../../tests/sbom/schema/cyclonedx-1.7/bom-1.7.schema.json" as schema_cdx : Str
import "../../tests/sbom/schema/spdx-3.0.1.schema.json" as schema_3 : Str
import "../../tests/sbom/schema/spdx-2.3.schema.json" as schema_2 : Str
import "../../tests/sbom/fixtures/upstream/syft.cdx.json" as upstream_syft_cdx : Str
import "../../tests/sbom/fixtures/upstream/syft.spdx.json" as upstream_syft_spdx : Str
import "../../tests/sbom/fixtures/upstream/trivy.cdx.json" as upstream_trivy_cdx : Str
import "../../tests/sbom/fixtures/upstream/trivy.spdx.json" as upstream_trivy_spdx : Str
import "../../tests/sbom/fixtures/verified-import.cdx.json" as fixture_verified_import_cdx : Str
import "../../tests/sbom/fixtures/native-linux.cdx.json" as fixture_native_linux_cdx : Str
import "../../tests/sbom/fixtures/native-arm64.cdx.json" as fixture_native_arm64_cdx : Str
import "../../tests/sbom/fixtures/source-bundle.cdx.json" as fixture_source_bundle_cdx : Str
import "../../tests/sbom/fixtures/verified-empty.cdx.json" as fixture_verified_empty_cdx : Str
import "../../tests/sbom/fixtures/unknown-closure.cdx.json" as fixture_unknown_closure_cdx : Str
import "../../tests/sbom/fixtures/verified-import.spdx.json" as fixture_verified_import_3 : Str
import "../../tests/sbom/fixtures/verified-import.spdx-2.3.json" as fixture_verified_import_2 : Str
import "../../tests/sbom/fixtures/native-linux.spdx.json" as fixture_native_linux_3 : Str
import "../../tests/sbom/fixtures/native-linux.spdx-2.3.json" as fixture_native_linux_2 : Str
import "../../tests/sbom/fixtures/native-arm64.spdx.json" as fixture_native_arm64_3 : Str
import "../../tests/sbom/fixtures/native-arm64.spdx-2.3.json" as fixture_native_arm64_2 : Str
import "../../tests/sbom/fixtures/source-bundle.spdx.json" as fixture_source_bundle_3 : Str
import "../../tests/sbom/fixtures/source-bundle.spdx-2.3.json" as fixture_source_bundle_2 : Str
import "../../tests/sbom/fixtures/verified-empty.spdx.json" as fixture_verified_empty_3 : Str
import "../../tests/sbom/fixtures/verified-empty.spdx-2.3.json" as fixture_verified_empty_2 : Str
import "../../tests/sbom/fixtures/unknown-closure.spdx.json" as fixture_unknown_closure_3 : Str
import "../../tests/sbom/fixtures/unknown-closure.spdx-2.3.json" as fixture_unknown_closure_2 : Str

## Consumer fixtures intentionally include a transitive native library, a build
## compiler, a patched proprietary component, and a locked source identity.
SbomTest := [].{
	context : Sbom.Context
	context = { namespace: "https://example.org/sbom/fixture/revision-1", revision: "1", created: "2026-10-21T00:00:00Z", author: "Organization: Fixture producers", generator: "Tool: blueprint-sbom-0.7.0" }
	subject : Sbom.Subject
	subject = { filename: "sample-artifact", version: "1.0.0", target: "x86_64-linux", sha256: Crypto.SHA256.hash("fixture subject\n".to_utf8()).to_hex(), url: "https://example.org/releases/1.0.0/sample-artifact" }
	spec = { ..Spec.empty("fixture"), systems: ["x86_64-linux", "aarch64-linux"] }
	lock = Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [], fetched: [], hints: [] }
	composition : Sbom.Composition
	composition = {
		profile: Sbom.profile,
		imported_documents: [],
		unavailable_sboms: [],
		components: [
			component("platform", "platform", "1.0.0"),
			{ ..component("native", "native-library", "2.0.0"), identity: "pkg:cargo/native-library@2.0.0", sha256: digest },
			component("compiler", "compiler", "3.0.0"),
			{ ..component("restricted", "proprietary-code", "4.0.0-patch1"), license: "LicenseRef-Restricted", license_url: "https://example.org/terms/4.0.0", modified: "Vendor revision 4.0.0-patch1; upstream 4.0.0; local fix CVE-fixture; content source identity preserved" },
		],
		relationships: [
			edge("Subject", "platform", "contains"),
			edge("platform", "native", "contains"),
			{ ..edge("Subject", "compiler", "dependsOn"), scope: "build" },
			edge("Subject", "restricted", "contains"),
		],
		coverage: [{ scope: "native-closure", status: "incomplete", reason: "Opaque task lacks remaining native closure metadata", contact: "https://example.org/support" }],
		inputs: [],
	}

	inventory : Try(Sbom.Inventory, Str)
	inventory = Sbom.inspect(spec, lock, subject.target, composition)

	## Each fixture document, rendered as SPDX 3.0.1 (`NAME.spdx.json`), as
	## SPDX 2.3 (`NAME.spdx-2.3.json`) and as CycloneDX 1.7 (`NAME.cdx.json`)
	## from the same inventory.
	outputs : List({ name : Str, text : Str })
	outputs = cases.fold(
		[],
		|all, case| all.concat([
			{ name: "${case.name}.spdx.json", text: Sbom.render(case.inventory, case.subject, case.context) ?? crash "invalid ${case.name} document" },
			{ name: "${case.name}.spdx-2.3.json", text: Sbom.render_spdx2(case.inventory, case.subject, case.context) ?? crash "invalid ${case.name} SPDX 2.3 document" },
			{ name: "${case.name}.cdx.json", text: Sbom.render_cyclonedx(case.inventory, case.subject, case.context) ?? crash "invalid ${case.name} CycloneDX document" },
		]),
	)

	Case : { name : Str, inventory : Sbom.Inventory, subject : Sbom.Subject, context : Sbom.Context }

	cases : List(Case)
	cases = {
		linux = inventory ?? crash "invalid fixture"
		arm_composition = { ..composition, components: composition.components.map(|entry| { ..entry, target: "aarch64-linux" }) }
		arm_inventory = Sbom.inspect(spec, lock, "aarch64-linux", arm_composition) ?? crash "invalid arm fixture"
		source_composition = { ..composition, components: composition.components.map(|entry| { ..entry, target: "" }) }
		source_inventory = Sbom.inspect(spec, lock, "source", source_composition) ?? crash "invalid source fixture"
		empty = { ..composition, components: [], relationships: [], coverage: [{ scope: "all", status: "verified-empty", reason: "Reviewed generated text contains no third-party components", contact: "https://example.org/support" }] }
		empty_inventory = Sbom.inspect(spec, lock, subject.target, empty) ?? crash "invalid empty fixture"
		unknown = { ..empty, coverage: [{ scope: "all", status: "incomplete", reason: "Opaque task exposes no component closure", contact: "https://example.org/support" }] }
		unknown_inventory = Sbom.inspect(spec, lock, subject.target, unknown) ?? crash "invalid unknown fixture"
		incoming = { ..component("consumed-input", "sample-artifact", subject.version), sha256: subject.sha256, download: subject.url, identity: "urn:example:fixture:consumed-input" }
		bound = { ..imported_document, subject: { ..imported_document.subject, component: incoming.id } }
		import_composition = { ..composition, components: [incoming], relationships: [edge("Subject", incoming.id, "dependsOn")], imported_documents: [bound] }
		import_inventory = Sbom.inspect(spec, lock, subject.target, import_composition) ?? crash "invalid imported fixture"
		[
			{ name: "verified-import", inventory: import_inventory, subject: { ..subject, filename: "consumer-artifact", sha256: Crypto.SHA256.hash("consumer of fixture\n".to_utf8()).to_hex() }, context: { ..context, namespace: "https://example.org/sbom/fixture/imported/revision-1" } },
			{ name: "native-linux", inventory: linux, subject, context },
			{ name: "native-arm64", inventory: arm_inventory, subject: { ..subject, target: "aarch64-linux" }, context: { ..context, namespace: "https://example.org/sbom/fixture/arm64/revision-1" } },
			{ name: "source-bundle", inventory: source_inventory, subject: { ..subject, filename: "sample-source-bundle", target: "source", sha256: Crypto.SHA256.hash("fixture source bundle\n".to_utf8()).to_hex() }, context: { ..context, namespace: "https://example.org/sbom/fixture/source/revision-1" } },
			{ name: "verified-empty", inventory: empty_inventory, subject, context: { ..context, namespace: "https://example.org/sbom/fixture/empty/revision-1" } },
			{ name: "unknown-closure", inventory: unknown_inventory, subject, context: { ..context, namespace: "https://example.org/sbom/fixture/unknown/revision-1" } },
		]
	}

	output : Try(Str, Str)
	output = Sbom.render(inventory ?? crash "invalid fixture", subject, context)
}

digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

component : Str, Str, Str -> Sbom.Component
component = |id, name, version| { id, name, version, producer: "Organization: Fixture upstream", identity: "https://example.org/source/${name}/${version}", download: "https://example.org/source/${name}/${version}.tar.gz", sha256: "", license: "MIT", license_url: "", modified: "", target: "x86_64-linux", origin: "reviewed" }

edge = |from, to, relation| { from, to, relation, scope: "", basis: "Reviewed fixture composition declaration" }

inspect = |composition| Sbom.inspect(SbomTest.spec, SbomTest.lock, "x86_64-linux", composition)

expect SbomTest.inventory.is_ok()
expect SbomTest.output.is_ok()
expect inspect({ ..SbomTest.composition, components: [] }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.concat(SbomTest.composition.components) }).is_err()
expect inspect({ ..SbomTest.composition, relationships: [edge("Subject", "missing", "contains")] }).is_err()
expect inspect({ ..SbomTest.composition, relationships: [edge("native", "platform", "contains")] }).is_err()
expect inspect({ ..SbomTest.composition, coverage: [] }).is_err()
expect inspect({ ..SbomTest.composition, coverage: [{ scope: "all", status: "incomplete", reason: "", contact: "contact" }] }).is_err()
expect inspect({ ..SbomTest.composition, relationships: SbomTest.composition.relationships.concat(SbomTest.composition.relationships) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, target: "aarch64-linux" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, origin: "import:https://unverified.example/sbom" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, sha256: "bad" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, version: "" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, license: "LicenseRef-restricted", license_url: "" }) }).is_err()

# Unknown and verified-empty inventories are distinct, explicitly asserted facts.
empty_composition = { ..SbomTest.composition, components: [], relationships: [], coverage: [{ scope: "all", status: "verified-empty", reason: "Reviewed generated text contains no third-party components", contact: "https://example.org/support" }] }
expect inspect(empty_composition).is_ok()
expect inspect({ ..empty_composition, coverage: [{ scope: "all", status: "incomplete", reason: "No closure data exposed by opaque task", contact: "https://example.org/support" }] }).is_ok()

# Complete known-input dispositions; a tool's availability proves no containment.
tool_spec = { ..SbomTest.spec, environments: [{ name: "builder", parents: [], tools: [{ source: "packages", name: "cc" }], overlays: [] }] }
expect Sbom.inspect(tool_spec, SbomTest.lock, "x86_64-linux", SbomTest.composition).is_err()
expect Sbom.inspect(tool_spec, SbomTest.lock, "x86_64-linux", { ..SbomTest.composition, inputs: [{ input: "tool:packages#cc", component: "compiler", reason: "Used only to compile; does not ship" }] }).is_ok()
expect Sbom.inspect(tool_spec, SbomTest.lock, "x86_64-linux", { ..SbomTest.composition, inputs: [{ input: "tool:packages#cc", component: "", reason: "Unrelated developer tool excluded from this subject" }] }).is_ok()

expect {
	inventory = SbomTest.inventory ?? crash "fixture invalid"
	Sbom.render(inventory, { ..SbomTest.subject, target: "aarch64-linux" }, SbomTest.context).is_err()
}
expect {
	inventory = SbomTest.inventory ?? crash "fixture invalid"
	Sbom.render(inventory, { ..SbomTest.subject, sha256: "not-a-sha256" }, SbomTest.context).is_err()
}
expect {
	inventory = SbomTest.inventory ?? crash "fixture invalid"
	Sbom.render(inventory, { ..SbomTest.subject, filename: "../private" }, SbomTest.context).is_err()
}
expect {
	inventory = SbomTest.inventory ?? crash "fixture invalid"
	Sbom.render(inventory, SbomTest.subject, { ..SbomTest.context, created: "yesterdayZ" }).is_err()
}
expect {
	inventory = SbomTest.inventory ?? crash "fixture invalid"
	Sbom.render(inventory, SbomTest.subject, { ..SbomTest.context, created: "2026-99-01T00:00:00Z" }).is_err()
}
expect {
	inventory = SbomTest.inventory ?? crash "fixture invalid"
	Sbom.render(inventory, SbomTest.subject, { ..SbomTest.context, author: "Organization: /Users/private/secret" }).is_err()
}
expect {
	inventory = SbomTest.inventory ?? crash "fixture invalid"
	Sbom.render(inventory, SbomTest.subject, { ..SbomTest.context, generator: "Tool: bad?token=secret" }).is_err()
}
expect {
	inventory = SbomTest.inventory ?? crash "fixture invalid"
	one = Sbom.render(inventory, SbomTest.subject, SbomTest.context)
	two = Sbom.render(inventory, SbomTest.subject, SbomTest.context)
	one == two
}
expect {
	# Composition order is canonicalized, independent of authoring order.
	reordered = { ..SbomTest.composition, components: SbomTest.composition.components.fold([], |all, entry| all.prepend(entry)), relationships: SbomTest.composition.relationships.fold([], |all, entry| all.prepend(entry)) }
	inspect(reordered) == SbomTest.inventory
}
expect {
	inventory = SbomTest.inventory ?? crash "fixture invalid"
	one = Sbom.render(inventory, SbomTest.subject, SbomTest.context) ?? ""
	two = Sbom.render(inventory, SbomTest.subject, { ..SbomTest.context, revision: "2", namespace: "https://example.org/sbom/fixture/revision-2" }) ?? ""
	one != two and one.contains(SbomTest.subject.sha256) and two.contains(SbomTest.subject.sha256)
}

imported_document : Sbom.Imported
imported_document = {
	subject: { component: "", filename: SbomTest.subject.filename, version: SbomTest.subject.version, sha256: SbomTest.subject.sha256 },
	id: "upstream",
	url: "https://example.org/sbom/releases/1.0.0/revision-1.spdx.json",
	sha256: Crypto.SHA256.hash((SbomTest.output ?? "").to_utf8()).to_hex(),
	namespace: SbomTest.context.namespace,
	target: SbomTest.subject.target,
	document: SbomTest.output ?? "",
	relation: "contains",
	basis: "Reviewed imported graph bound to immutable document digest",
	contact: "https://example.org/support",
}

imported_composition = { ..SbomTest.composition, components: [], relationships: [], imported_documents: [imported_document] }
expect inspect(imported_composition).is_ok()
expect inspect({ ..imported_composition, imported_documents: [{ ..imported_document, sha256: digest }] }).is_err()
expect inspect({ ..imported_composition, imported_documents: [{ ..imported_document, namespace: "https://evil.example/sbom" }] }).is_err()
expect inspect({ ..imported_composition, imported_documents: [{ ..imported_document, target: "aarch64-linux" }] }).is_err()
expect inspect({ ..imported_composition, imported_documents: [{ ..imported_document, url: "https://user:secret@example.org/sbom" }] }).is_err()
expect inspect({ ..imported_composition, imported_documents: [{ ..imported_document, document: "{bad JSON}", sha256: Crypto.SHA256.hash("{bad JSON}".to_utf8()).to_hex() }] }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, id: "spdx/agent" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, producer: "Not-an-SPDX-supplier" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, license: "Not-A-License" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, license: "MIT AND ( Apache-2.0 OR )" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, license: "MIT OR ( Apache-2.0 WITH LLVM-exception )" }) }).is_ok()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, download: "https://user:secret@example.org/source" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, download: "https://example.org/source?token=secret" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, download: "file:///etc/passwd" }) }).is_err()

locked_spec = { ..SbomTest.spec, sources: [{ name: "upstream", provider: { name: "nix", version: 1, ref: "github:example/source/stable" } }], programs: [{ name: "roc", system: "x86_64-linux", urls: ["https://example.org/roc/3.0.0.tar.gz"], unpack: TarGz, path: "roc/roc" }] }

locked_lock = Lock.{ format: Lock.current_format, intent: Lock.intent_of(locked_spec), sources: [{ name: "upstream", provider: "nix", ref: "github:example/source/stable", rev: "1111111111111111111111111111111111111111", digest: "sha256-Zml4dHVyZQ==" }], fetched: [{ name: "roc", system: "x86_64-linux", urls: ["https://example.org/roc/3.0.0.tar.gz"], sha256: digest, size: 100, obtained: Both, served: ["example.org"], witness: "https://api.example.org/repos/roc/releases/tags/3.0.0" }], hints: [] }

source_component = { ..component("source", "upstream", "1111111111111111111111111111111111111111"), download: "github:example/source/stable", identity: "github:example/source/stable@1111111111111111111111111111111111111111#sha256-Zml4dHVyZQ==", origin: "source:upstream" }

program_component = { ..component("program", "roc", "3.0.0"), download: "https://example.org/roc/3.0.0.tar.gz", identity: "", sha256: digest, origin: "program:roc:x86_64-linux" }

locked_composition = { ..SbomTest.composition, components: [source_component, program_component], relationships: [edge("Subject", source_component.id, "dependsOn"), { ..edge("Subject", program_component.id, "dependsOn"), scope: "build" }], inputs: [{ input: "source:upstream", component: source_component.id, reason: "Resolved source tree identity; no archive digest inferred" }, { input: "program:roc:x86_64-linux", component: program_component.id, reason: "Authoritative locked download archive" }], unavailable_sboms: [no_sbom("source"), no_sbom("program")] }

no_sbom = |id| { component: id, reason: "The supplier publishes no SBOM for this release", contact: "https://example.org/support" }

inspect_locked = |composition| Sbom.inspect(locked_spec, locked_lock, "x86_64-linux", composition)

# A locked dependency needs its supplier's SBOM, or a stated reason it has none.
expect inspect_locked({ ..locked_composition, unavailable_sboms: [] }).is_err()
expect inspect_locked({ ..locked_composition, unavailable_sboms: [no_sbom("source")] }).is_err()
expect inspect_locked({ ..locked_composition, unavailable_sboms: [no_sbom("source"), { ..no_sbom("program"), reason: "" }] }).is_err()
expect inspect_locked({ ..locked_composition, unavailable_sboms: [no_sbom("source"), no_sbom("program"), no_sbom("Subject")] }).is_err()
expect {
	inventory = inspect_locked(locked_composition) ?? crash "invalid locked fixture"
	inventory.coverage.any(|scope| scope.scope == "sbom:program" and scope.status == "incomplete" and scope.reason == "No supplier SBOM: The supplier publishes no SBOM for this release")
}
expect
	match inspect_locked({ ..locked_composition, unavailable_sboms: [no_sbom("program")] }) {
		Err(problem) => problem.contains("dependency source (source:upstream) has no supplier SBOM") and problem.contains("pin the file by its published SHA-256")
		Ok(_) => False
	}
expect inspect_locked(locked_composition).is_ok()
expect inspect_locked({ ..locked_composition, inputs: [] }).is_err()
expect inspect_locked({ ..locked_composition, components: [{ ..source_component, version: "different-revision" }, program_component] }).is_err()
expect inspect_locked({ ..locked_composition, components: [{ ..source_component, sha256: digest }, program_component] }).is_err()
expect inspect_locked({ ..locked_composition, components: [source_component, { ..program_component, sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }] }).is_err()
expect inspect_locked({ ..locked_composition, components: [source_component, { ..program_component, target: "aarch64-linux" }] }).is_err()
expect {
	inventory = inspect_locked(locked_composition) ?? crash "invalid locked fixture"
	source = inventory.components.find_first(|entry| entry.id == "source") ?? crash "missing source"
	source.sha256.is_empty() and source.download == "https://github.com/example/source/tree/1111111111111111111111111111111111111111"
}
expect Sbom.json_within_bounds("[[[[[]]]]]")
expect !Sbom.json_within_bounds(Str.join_with(List.repeat("[", 65), "").concat(Str.join_with(List.repeat("]", 65), "")))
expect !Sbom.json_within_bounds("{unclosed")

expect SbomTest.output == Ok(fixture_native_linux_3)

# Pin-derived metadata is populated, never duplicated in composition.
unpinned_composition = { ..locked_composition, components: [{ ..source_component, version: "", identity: "", download: "", sha256: "" }, { ..program_component, version: "", identity: "", download: "", sha256: "", target: "" }] }
expect inspect_locked(unpinned_composition).is_ok()
expect {
	changed_lock = { ..locked_lock, sources: locked_lock.sources.map(|entry| { ..entry, rev: "2222222222222222222222222222222222222222" }) }
	inventory = Sbom.inspect(locked_spec, changed_lock, "x86_64-linux", unpinned_composition) ?? crash "pin should resolve"
	inventory.components.any(|entry| entry.id == source_component.id and entry.version == "2222222222222222222222222222222222222222")
}
expect {
	changed_lock = { ..locked_lock, fetched: locked_lock.fetched.map(|entry| { ..entry, sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }) }
	inventory = Sbom.inspect(locked_spec, changed_lock, "x86_64-linux", unpinned_composition) ?? crash "program pin should resolve"
	inventory.components.any(|entry| entry.id == program_component.id and entry.sha256 == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
}
expect {
	file_spec = { ..locked_spec, sources: [], source_files: [{ name: "upstream", url: "https://example.org/source/1.0.0.tar.gz", sha256: digest }] }
	file_lock = { ..locked_lock, intent: Lock.intent_of(file_spec), sources: [{ name: "upstream", provider: "file", ref: "https://example.org/source/1.0.0.tar.gz", rev: "", digest: "sha256:${digest}" }] }
	inventory = Sbom.inspect(file_spec, file_lock, "x86_64-linux", unpinned_composition) ?? crash "flat file should resolve"
	inventory.components.any(|entry| entry.id == source_component.id and entry.sha256 == digest and entry.version == "sha256:${digest}")
}

expect Sbom.inspect({ ..SbomTest.spec, requires_: ["unknown-future-feature"] }, SbomTest.lock, "x86_64-linux", SbomTest.composition).is_err()
expect {
	spaced = imported_document.document.replace_each("\"spdxId\":", "\"spdxId\" : ").replace_each("\"@graph\":", "\"@graph\" :\n ")
	inspect({ ..imported_composition, imported_documents: [{ ..imported_document, document: spaced, sha256: Crypto.SHA256.hash(spaced.to_utf8()).to_hex() }] }).is_ok()
}

# Upstream subject binding is separate from document integrity. A real locked
# artifact's digest/version/target must match before imported claims are bound.
program_document = (SbomTest.output ?? "").replace_each("\"sample-artifact\"", "\"3.0.0.tar.gz\"").replace_each("\"software_packageVersion\":\"1.0.0\"", "\"software_packageVersion\":\"3.0.0\"").replace_each(SbomTest.subject.sha256, digest)

bound_import = { ..imported_document, document: program_document, sha256: Crypto.SHA256.hash(program_document.to_utf8()).to_hex(), subject: { component: program_component.id, filename: "3.0.0.tar.gz", version: "3.0.0", sha256: digest } }
expect inspect_locked({ ..locked_composition, imported_documents: [bound_import], unavailable_sboms: [no_sbom("source")] }).is_ok()
expect inspect_locked({ ..locked_composition, imported_documents: [bound_import] }).is_err()
expect
	match inspect_locked({ ..locked_composition, imported_documents: [{ ..bound_import, subject: { ..bound_import.subject, sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" } }], unavailable_sboms: [no_sbom("source")] }) {
		Err(problem) => problem == "import subject filename/version/SHA256 mismatch"
		Ok(_) => False
	}
expect {
	changed_lock = { ..locked_lock, fetched: locked_lock.fetched.map(|entry| { ..entry, sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }) }
	match Sbom.inspect(locked_spec, changed_lock, "x86_64-linux", { ..unpinned_composition, imported_documents: [bound_import], unavailable_sboms: [no_sbom("source")] }) {
		Err(problem) => problem == "imported subject conflicts with authoritative component artifact"
		Ok(_) => False
	}
}
expect
	match inspect_locked({ ..locked_composition, imported_documents: [{ ..bound_import, target: "aarch64-linux" }], unavailable_sboms: [no_sbom("source")] }) {
		Err(problem) => problem == "import target differs from subject"
		Ok(_) => False
	}

# The same inventory reads back to the same package graph from either version,
# and from SPDX 2.2, whose JSON differs only in its version string here.
expect SbomTest.cases.all(
	|case| {
		three = Sbom.read(Sbom.render(case.inventory, case.subject, case.context) ?? "") ?? crash "3.0.1 rendering unreadable"
		two = Sbom.render_spdx2(case.inventory, case.subject, case.context) ?? ""
		two_three = Sbom.read(two) ?? crash "2.3 rendering unreadable"
		two_two = Sbom.read(two.replace_each("\"SPDX-2.3\"", "\"SPDX-2.2\"")) ?? crash "2.2 rendering unreadable"
		three.version == "SPDX-3.0.1" and two_three.version == "SPDX-2.3" and { ..three, version: "" } == { ..two_three, version: "" } and { ..two_two, version: "" } == { ..two_three, version: "" }
	},
)
expect {
	document = Sbom.read(SbomTest.output ?? "") ?? crash "unreadable"
	document.roots == ["Subject"] and document.relationships.any(|relation| relation.from == "Subject" and relation.to == "compiler" and relation.relation == "dependsOn" and relation.scope == "build")
}
expect {
	two = Sbom.render_spdx2(SbomTest.inventory ?? crash "fixture invalid", SbomTest.subject, SbomTest.context) ?? ""
	two.contains("{\"comment\":\"Reviewed fixture composition declaration\",\"relatedSpdxElement\":\"SPDXRef-Subject\",\"relationshipType\":\"BUILD_DEPENDENCY_OF\",\"spdxElementId\":\"SPDXRef-compiler\"}")
}

# An upstream that publishes SPDX 2.3 imports exactly as its 3.0.1 rendering does.
expect {
	two = Sbom.render_spdx2(SbomTest.inventory ?? crash "fixture invalid", SbomTest.subject, SbomTest.context) ?? ""
	from_two = inspect({ ..imported_composition, imported_documents: [{ ..imported_document, document: two, sha256: Crypto.SHA256.hash(two.to_utf8()).to_hex() }] })
	from_three = inspect(imported_composition)
	strip = |inventory| inventory.components.map(|entry| { ..entry, modified: "" })
	from_two.is_ok() and from_two.map_ok(strip) == from_three.map_ok(strip) and from_two.map_ok(|inventory| inventory.relationships) == from_three.map_ok(|inventory| inventory.relationships)
}
expect Sbom.read("{\"@context\":\"https://spdx.org/rdf/3.0.0/spdx-context.jsonld\",\"@graph\":[]}").is_err()
expect Sbom.read("{\"spdxVersion\":\"SPDX-2.1\"}").is_err()
expect Sbom.read("[]").is_err()
expect inspect({ ..SbomTest.composition, relationships: SbomTest.composition.relationships.map(|entry| { ..entry, scope: "test" }) }).is_err()
expect inspect({ ..SbomTest.composition, relationships: SbomTest.composition.relationships.map(|entry| { ..entry, relation: "CONTAINS" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| if (entry.id == "native") { ..entry, license: "LicenseRef-Restricted", license_url: "https://example.org/other-terms" } else entry) }).is_err()

# The committed fixtures are what the renderers write now; regenerate them
# with `scripts/test_sbom.roc fixtures tests/sbom/fixtures`.
committed_fixtures = [{ name: "verified-import.cdx.json", text: fixture_verified_import_cdx }, { name: "native-linux.cdx.json", text: fixture_native_linux_cdx }, { name: "native-arm64.cdx.json", text: fixture_native_arm64_cdx }, { name: "source-bundle.cdx.json", text: fixture_source_bundle_cdx }, { name: "verified-empty.cdx.json", text: fixture_verified_empty_cdx }, { name: "unknown-closure.cdx.json", text: fixture_unknown_closure_cdx }, { name: "verified-import.spdx.json", text: fixture_verified_import_3 }, { name: "verified-import.spdx-2.3.json", text: fixture_verified_import_2 }, { name: "native-linux.spdx.json", text: fixture_native_linux_3 }, { name: "native-linux.spdx-2.3.json", text: fixture_native_linux_2 }, { name: "native-arm64.spdx.json", text: fixture_native_arm64_3 }, { name: "native-arm64.spdx-2.3.json", text: fixture_native_arm64_2 }, { name: "source-bundle.spdx.json", text: fixture_source_bundle_3 }, { name: "source-bundle.spdx-2.3.json", text: fixture_source_bundle_2 }, { name: "verified-empty.spdx.json", text: fixture_verified_empty_3 }, { name: "verified-empty.spdx-2.3.json", text: fixture_verified_empty_2 }, { name: "unknown-closure.spdx.json", text: fixture_unknown_closure_3 }, { name: "unknown-closure.spdx-2.3.json", text: fixture_unknown_closure_2 }]
expect SbomTest.outputs.sort_with(|a, b| Project.bytewise(a.name, b.name)) == committed_fixtures.sort_with(|a, b| Project.bytewise(a.name, b.name))

# What a consumer asks of the native fixture, in either version: the native
# library ships inside the subject, the compiler only builds it, restricted
# terms keep their patch identity, and source and binary digests stay apart.
containers : Sbom.Document, Str -> List(Str)
containers = |document, contained| {
	var $found = [contained]
	var $changed = True
	while $changed {
		$changed = False
		for relation in document.relationships {
			if relation.relation == "contains" and $found.contains(relation.to) and !$found.contains(relation.from) {
				$found = $found.append(relation.from)
				$changed = True
			}
		}
	}
	$found
}

expect [fixture_native_linux_3, fixture_native_linux_2].all(
	|text| {
		document = Sbom.read(text) ?? crash "fixture unreadable"
		find = |id| document.packages_.find_first(|entry| entry.id == id) ?? crash "missing ${id}"
		native = find("native")
		restricted = find("restricted")
		native.download == "https://example.org/source/native-library/2.0.0.tar.gz"
			and containers(document, "native").contains("Subject")
				and !containers(document, "compiler").contains("Subject")
					and document.relationships.any(|relation| relation.from == "Subject" and relation.to == "compiler" and relation.relation == "dependsOn" and relation.scope == "build")
						and restricted.license == "LicenseRef-Restricted"
							and restricted.license_url == "https://example.org/terms/4.0.0"
								and restricted.comment.contains("4.0.0-patch1")
									and native.sha256 != find("Subject").sha256
	},
)

# The validators follow the vendored, digest-pinned schemas: every class,
# member and enumeration they accept is the schema's own.
expect Crypto.SHA256.hash(schema_3.to_utf8()).to_hex() == "582c64e809d5b3ef9bd0c4de13a32391b47b0284a3e8d199569fb96f649234b1"
expect Crypto.SHA256.hash(schema_2.to_utf8()).to_hex() == "4126dc29f15e92feec92e9622f4939131ad58b125d6f578aa93e980a6e6f3212"

sorted = |values| values.sort_with(Project.bytewise)

enumeration : JsonData -> List(Str)
enumeration = |tree| ((tree.field("enum") ?? JsonData.Array([])).array() ?? []).map(|value| value.string() ?? "")

definitions_3 : JsonData
definitions_3 = (JsonData.decode_with(schema_3, { ..JsonData.documents, duplicates: CollapseIdentical }) ?? crash "schema is not JSON").field("$defs") ?? crash "schema has no $defs"

## The properties a 3.0.1 class has, through its `_props` chain of `allOf`.
schema_properties : Str -> List(Str)
schema_properties = |definition| {
	var $pending = [definition]
	var $found = []
	while !$pending.is_empty() {
		name = $pending.first() ?? ""
		$pending = $pending.drop_first(1)
		parts = ((definitions_3.field(name) ?? JsonData.Null).field("allOf") ?? JsonData.Array([])).array() ?? []
		for part in parts {
			match part.field("$ref") {
				Ok(String(reference)) => {
					$pending = $pending.append(reference.drop_prefix("#/$defs/"))
				}
				_ => {
					$found = $found.concat((part.field("properties") ?? JsonData.Null).keys())
				}
			}
		}
	}
	$found
}

expect Spdx3.vocabularies.all(|vocabulary| sorted(enumeration(definitions_3.field(vocabulary.definition) ?? JsonData.Null)) == sorted(vocabulary.values))
expect Spdx3.classes.all(|class| definitions_3.field(class.name).is_ok() and class.properties.all(|property| schema_properties("${class.name}_props").contains(property)))

## The schema object at `path` through `properties` and `items`.
at_2 : List(Str) -> JsonData
at_2 = |path| path.fold(
	JsonData.decode_with(schema_2, JsonData.documents) ?? crash "schema is not JSON",
	|node, step| {
		child = (node.field("properties") ?? JsonData.Null).field(step) ?? JsonData.Null
		child.field("items") ?? child
	},
)

expect Spdx2.vocabularies.all(|vocabulary| sorted(enumeration(at_2(vocabulary.path))) == sorted(vocabulary.values))
expect Spdx2.objects.all(|object| sorted((at_2(object.path).field("properties") ?? JsonData.Null).keys()) == sorted(object.members))

# CycloneDX carries the same graph: Blueprint reads its own BOM back to the
# package graph either SPDX rendering states, and a consumer that reads only
# standard CycloneDX sees the shipped, build-only and unresolved components.
expect SbomTest.cases.all(
	|case| {
		three = Sbom.read(Sbom.render(case.inventory, case.subject, case.context) ?? "") ?? crash "3.0.1 rendering unreadable"
		bom = Sbom.read_cyclonedx(Sbom.render_cyclonedx(case.inventory, case.subject, case.context) ?? "") ?? crash "CycloneDX rendering unreadable"
		bom.version == "CycloneDX-1.7" and { ..bom, version: "" } == { ..three, version: "" }
	},
)
expect {
	bom = JsonData.decode_with(fixture_native_linux_cdx, JsonData.documents) ?? crash "fixture"
	components = (bom.field("components") ?? JsonData.Null).array() ?? []
	scope = |ref| components.find_first(|entry| entry.field("bom-ref") == Ok(JsonData.String(ref))).map_ok(|entry| (entry.field("scope") ?? JsonData.Null).string() ?? "") ?? ""
	scope("native") == "required" and scope("platform") == "required" and scope("restricted") == "required" and scope("compiler") == "excluded"
}
expect {
	bom = JsonData.decode_with(fixture_native_linux_cdx, JsonData.documents) ?? crash "fixture"
	serial = (bom.field("serialNumber") ?? JsonData.Null).string() ?? ""
	other = JsonData.decode_with(fixture_verified_empty_cdx, JsonData.documents) ?? crash "fixture"
	serial.starts_with("urn:uuid:") and serial.to_utf8().get(23) == Ok('8') and other.field("serialNumber") != bom.field("serialNumber") and bom.field("version") == Ok(JsonData.Number("1"))
}
expect Sbom.read_cyclonedx(fixture_native_linux_cdx.replace_each(",\"compiler\"]", "]")).is_err()
expect Sbom.read_cyclonedx(fixture_native_linux_cdx.replace_each("blueprint:namespace", "other:namespace")).is_err()
expect Sbom.read_cyclonedx(fixture_native_linux_cdx.replace_each("\"scope\":\"excluded\"", "\"scope\":\"required\"")).is_err()
expect Sbom.read(fixture_native_linux_cdx) == Sbom.read_cyclonedx(fixture_native_linux_cdx)

# The CycloneDX validator follows the vendored, digest-pinned 1.7 schema.
expect Crypto.SHA256.hash(schema_cdx.to_utf8()).to_hex() == "73308edec3ab2d38bfffd993e96a042b594314143b6971a6e9ed98bbb6bd76ce"

definitions_cdx : JsonData
definitions_cdx = (JsonData.decode_with(schema_cdx, JsonData.documents) ?? crash "schema is not JSON").field("definitions") ?? crash "schema has no definitions"

at_cdx : List(Str) -> JsonData
at_cdx = |path|
	match path {
		[definition, .. as rest] => rest.fold(
			definitions_cdx.field(definition) ?? JsonData.Null,
			|node, step| {
				child = (node.field("properties") ?? JsonData.Null).field(step) ?? JsonData.Null
				child.field("items") ?? child
			},
		)
		[] => JsonData.Null
	}

expect CycloneDx.vocabularies.all(|vocabulary| sorted(enumeration(at_cdx(vocabulary.path))) == sorted(vocabulary.values))
expect CycloneDx.objects.all(|object| object.members.all(|name| (at_cdx([object.definition]).field("properties") ?? JsonData.Null).keys().contains(name)))
expect CycloneDx.objects.all(|object| sorted((at_cdx([object.definition]).field("properties") ?? JsonData.Null).keys()) == sorted(object.members))

# What real generators publish imports: Syft and Trivy, in CycloneDX and SPDX.
# What the profile cannot carry is counted in the document's gaps and stated
# in the import's coverage, never dropped silently.
upstream_import : Str -> Try(Sbom.Inventory, Str)
upstream_import = |text| {
	document = Sbom.read(text)?
	root = document.packages_.find_first(|entry| Ok(entry.id) == document.roots.first()).map_err(|_| "no described package")?
	imported = { subject: { component: "", filename: root.name, version: root.version, sha256: root.sha256 }, id: "upstream", url: "https://example.org/upstream/sbom.json", sha256: Crypto.SHA256.hash(text.to_utf8()).to_hex(), namespace: document.namespace, target: "x86_64-linux", document: text, relation: "dependsOn", basis: "Supplier SBOM for a consumed source", contact: "https://example.org/support" }
	inspect({ ..SbomTest.composition, components: [], relationships: [], imported_documents: [imported] })
}

expect (Sbom.read(upstream_syft_cdx) ?? crash "syft cdx").gaps == ["1 × component.author"]
expect (Sbom.read(upstream_trivy_cdx) ?? crash "trivy cdx").gaps == ["1 × bom.vulnerabilities"]
expect (Sbom.read(upstream_syft_spdx) ?? crash "syft spdx").gaps == ["1 × file", "108 × relationship to a file or snippet"]
expect (Sbom.read(upstream_trivy_spdx) ?? crash "trivy spdx").gaps == []
expect [upstream_syft_cdx, upstream_syft_spdx, upstream_trivy_cdx, upstream_trivy_spdx].all(
	|text|
		match upstream_import(text) {
			Ok(inventory) => inventory.components.len() >= 109 and inventory.coverage.any(|scope| scope.scope == "import:upstream" and scope.status == "incomplete")
			Err(_) => False
		},
)
expect {
	inventory = upstream_import(upstream_syft_spdx) ?? crash "syft spdx import"
	coverage = inventory.coverage.find_first(|scope| scope.scope == "import:upstream") ?? crash "no import coverage"
	coverage.reason.contains("108 × relationship to a file or snippet") and inventory.components.any(|entry| entry.identity.starts_with("pkg:cargo/libsqlite3-sys@0.33.0"))
}
expect {
	# Both formats from one tool describe the same crates.
	crates = |text| (Sbom.read(text) ?? crash "unreadable").packages_.map(|entry| entry.identity).keep_if(|id| id.starts_with("pkg:cargo/")).map(|id| id.split_on("?").first() ?? id).sort_with(Project.bytewise)
	crates(upstream_syft_cdx) == crates(upstream_syft_spdx) and crates(upstream_trivy_cdx) == crates(upstream_trivy_spdx)
}
expect upstream_import(upstream_syft_cdx.replace_each("/src/Cargo.lock", "/home/someone/src/Cargo.lock")).is_err()

# A dependency consumed as a file whose supplier publishes an SBOM, such as a
# Roc package bundle: pin the file by its published SHA-256, declare the
# component from that pin, and bind the supplier's SBOM to it. Nothing here is
# specific to Roc.
bundle_bytes = "dependency bundle bytes\n"

bundle_digest = Crypto.SHA256.hash(bundle_bytes.to_utf8()).to_hex()

bundle_url = "https://example.org/releases/1.2.0/dep-abc.tar.zst"

supplier_sbom = Sbom.render(SbomTest.inventory ?? crash "fixture", { ..SbomTest.subject, filename: "dep-abc.tar.zst", version: "1.2.0", sha256: bundle_digest, url: bundle_url }, { ..SbomTest.context, namespace: "https://example.org/sbom/dep/revision-1" }) ?? crash "supplier SBOM"

consumer_spec = { ..SbomTest.spec, requires_: ["source-files"], source_files: [{ name: "dep", url: bundle_url, sha256: bundle_digest }] }

consumer_lock = Lock.{ format: Lock.current_format, intent: Lock.intent_of(consumer_spec), sources: [{ name: "dep", provider: "file", ref: bundle_url, rev: "", digest: "sha256:${bundle_digest}" }], fetched: [], hints: [] }

dependency = { ..component("dep", "dep-abc.tar.zst", "1.2.0"), identity: "", download: "", sha256: "", origin: "source:dep" }

supplier_import = { ..imported_document, id: "dep-sbom", url: "https://example.org/releases/1.2.0/dep-abc.tar.zst.spdx.json", namespace: "https://example.org/sbom/dep/revision-1", document: supplier_sbom, sha256: Crypto.SHA256.hash(supplier_sbom.to_utf8()).to_hex(), subject: { component: "dep", filename: "dep-abc.tar.zst", version: "1.2.0", sha256: bundle_digest } }

consumer = { ..SbomTest.composition, components: [dependency], relationships: [edge("Subject", "dep", "dependsOn")], imported_documents: [supplier_import], inputs: [{ input: "source:dep", component: "dep", reason: "Dependency bundle pinned by its published SHA-256" }] }
expect {
	match Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", consumer) {
		Ok(inventory) => inventory.relationships.any(|relation| relation.to == "dep" and relation.relation == "copiedTo") and inventory.coverage.any(|scope| scope.scope == "import:dep-sbom" and scope.reason.starts_with("Document digest and upstream subject artifact identity match"))
		Err(_) => False
	}
}
# The pin stays the authority: a supplier SBOM for other bytes does not bind.
expect Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", { ..consumer, imported_documents: [{ ..supplier_import, subject: { ..supplier_import.subject, sha256: digest } }] }).is_err()
expect Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", { ..consumer, components: [{ ..dependency, sha256: digest }] }).is_err()

# Binding inputs must track the current public Spec and Lock wire contracts.
expect Spec.parse(fixture_input_spec) == Ok(SbomTest.spec)
expect Lock.parse(fixture_input_lock) == Ok(SbomTest.lock)
