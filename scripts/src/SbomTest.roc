import core.Spec
import "../../tests/sbom/fixtures/reviewed-source.cdx.json" as fixture_reviewed_source_cdx : Str
import "../../tests/sbom/fixtures/reviewed-source.spdx.json" as fixture_reviewed_source_3 : Str
import "../../tests/sbom/fixtures/reviewed-source.spdx-2.3.json" as fixture_reviewed_source_2 : Str
import core.Lock
import core.Project
import core.JsonData
import core.Sbom
import core.Sidecar
import core.Manifest
import core.Spdx2
import core.Spdx3
import core.CycloneDx
import "../../tests/sbom/fixtures/input/Spec" as fixture_input_spec : Str
import "../../tests/sbom/fixtures/input/Lock" as fixture_input_lock : Str
import "../../tests/sbom/fixtures/input/composition.json" as fixture_input_composition : Str
import "../../tests/sbom/fixtures/input/inventory.json" as fixture_input_inventory : Str
import "../../tests/sbom/fixtures/input/subject.json" as fixture_input_subject : Str
import "../../tests/sbom/fixtures/input/context.json" as fixture_input_context : Str
import "../../tests/sbom/fixtures/input/sample-artifact" as fixture_input_artifact : Str
import "../../tests/sbom/schema/cyclonedx-1.7/bom-1.7.schema.json" as schema_cdx : Str
import "../../tests/sbom/schema/spdx-3.0.1.schema.json" as schema_3 : Str
import "../../tests/sbom/schema/spdx-2.3.schema.json" as schema_2 : Str
import "../../tests/sbom/fixtures/upstream/syft.cdx.json" as upstream_syft_cdx : Str
import "../../tests/sbom/fixtures/upstream/syft.spdx.json" as upstream_syft_spdx : Str
import "../../tests/sbom/fixtures/upstream/trivy.cdx.json" as upstream_trivy_cdx : Str
import "../../tests/sbom/fixtures/upstream/trivy.spdx.json" as upstream_trivy_spdx : Str
import "../../tests/sbom/fixtures/verified-import.cdx.json" as fixture_verified_import_cdx : Str
import "../../tests/sbom/fixtures/mixed-coverage.cdx.json" as fixture_mixed_coverage_cdx : Str
import "../../tests/sbom/fixtures/mixed-coverage.spdx.json" as fixture_mixed_coverage_3 : Str
import "../../tests/sbom/fixtures/mixed-coverage.spdx-2.3.json" as fixture_mixed_coverage_2 : Str
import "../../tests/sbom/fixtures/native-linux.cdx.json" as fixture_native_linux_cdx : Str
import "../../tests/sbom/fixtures/native-arm64.cdx.json" as fixture_native_arm64_cdx : Str
import "../../tests/sbom/fixtures/source-bundle.cdx.json" as fixture_source_bundle_cdx : Str
import "../../tests/sbom/fixtures/native-source-import.cdx.json" as fixture_native_source_import_cdx : Str
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
import "../../tests/sbom/fixtures/native-source-import.spdx.json" as fixture_native_source_import_3 : Str
import "../../tests/sbom/fixtures/native-source-import.spdx-2.3.json" as fixture_native_source_import_2 : Str
import "../../tests/sbom/fixtures/verified-empty.spdx.json" as fixture_verified_empty_3 : Str
import "../../tests/sbom/fixtures/verified-empty.spdx-2.3.json" as fixture_verified_empty_2 : Str
import "../../tests/sbom/fixtures/unknown-closure.spdx.json" as fixture_unknown_closure_3 : Str
import "../../tests/sbom/fixtures/unknown-closure.spdx-2.3.json" as fixture_unknown_closure_2 : Str
import "../../tests/sbom/fixtures/CONTRACT.md" as fixture_contract : Str
import "../../tests/sbom/fixtures/source-import/Spec" as source_import_spec : Str
import "../../tests/sbom/fixtures/source-import/Lock" as source_import_lock : Str
import "../../tests/sbom/fixtures/source-import/composition.json" as source_import_composition : Str
import "../../tests/sbom/fixtures/source-import/subject.json" as source_import_subject_json : Str
import "../../tests/sbom/fixtures/source-import/context.json" as source_import_context_json : Str
import "../../tests/sbom/fixtures/source-import/consumer-artifact" as source_import_artifact : Str
import "../../tests/sbom/fixtures/source-import/expected.json" as source_import_expected : Str
import "../../tests/sbom/fixtures/source-import/inventory-source.json" as source_import_inventory_source : Str
import "../../tests/sbom/fixtures/source-import/inventory-x86_64-linux.json" as source_import_inventory_x86_64 : Str
import "../../tests/sbom/fixtures/source-import/inventory-aarch64-linux.json" as source_import_inventory_aarch64 : Str
import "../../tests/sbom/fixtures/source-import/tamper-document-digest.json" as source_import_tamper_document_digest : Str
import "../../tests/sbom/fixtures/source-import/tamper-subject-digest.json" as source_import_tamper_subject_digest : Str
import "../../tests/sbom/fixtures/source-import/tamper-subject-version.json" as source_import_tamper_subject_version : Str
import "../../tests/sbom/fixtures/source-import/tamper-import-native.json" as source_import_tamper_import_native : Str
import "../../tests/sbom/fixtures/source-import/tamper-component-native.json" as source_import_tamper_component_native : Str
import "../../tests/sbom/fixtures/source-import/tamper-import-aarch64.json" as source_import_tamper_import_aarch64 : Str
import "../../tests/sbom/fixtures/legacy/blueprint-0.8.cdx.json" as fixture_legacy_cdx : Str
import SbomFixtures

## Consumer fixtures intentionally include a transitive native library, a build
## compiler, a patched proprietary component, and a locked source identity.
SbomTest := [].{
	context : Sbom.Context
	context = { namespace: "https://example.org/sbom/fixture/revision-1", revision: "1", created: "2026-10-21T00:00:00Z", author: "Organization: Fixture producers", generator: "Tool: blueprint-sbom-0.7.0" }
	subject : Sbom.Subject
	subject = { kind: "file", producer: "NOASSERTION", license: "NOASSERTION", license_url: "", copyright: "NOASSERTION", attribution: "NOASSERTION", filename: "sample-artifact", version: "1.0.0", target: "x86_64-linux", sha256: Crypto.SHA256.hash(subject_bytes.to_utf8()).to_hex(), url: "https://example.org/releases/1.0.0/sample-artifact" }
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
		coverage: [{ scope: "native-closure", component: "", aspect: "", status: "incomplete", reason: "Opaque task lacks remaining native closure metadata", contact: "https://example.org/support" }],
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
		empty = { ..composition, components: [], relationships: [], coverage: [{ scope: "all", component: "Subject", aspect: "dependencies", status: "verified-empty", reason: "Reviewed generated text contains no third-party components", contact: "https://example.org/support" }] }
		empty_inventory = Sbom.inspect(spec, lock, subject.target, empty) ?? crash "invalid empty fixture"
		unknown = { ..empty, coverage: [{ scope: "all", component: "Subject", aspect: "dependencies", status: "unknown", reason: "Opaque task exposes no component closure", contact: "https://example.org/support" }] }
		unknown_inventory = Sbom.inspect(spec, lock, subject.target, unknown) ?? crash "invalid unknown fixture"
		incoming = { ..component("consumed-input", "sample-artifact", subject.version), sha256: subject.sha256, download: subject.url, identity: "urn:example:fixture:consumed-input" }
		bound = { ..imported_document, subject: { ..imported_document.subject, component: incoming.id } }
		import_composition = { ..composition, components: [incoming], relationships: [edge("Subject", incoming.id, "dependsOn")], imported_documents: [bound] }
		import_inventory = Sbom.inspect(spec, lock, subject.target, import_composition) ?? crash "invalid imported fixture"
		[
			{ name: "verified-import", inventory: import_inventory, subject: { ..subject, filename: "consumer-artifact", sha256: Crypto.SHA256.hash("consumer of fixture\n".to_utf8()).to_hex() }, context: { ..context, namespace: "https://example.org/sbom/fixture/imported/revision-1" } },
			{ name: "native-linux", inventory: linux, subject, context },
			{ name: "mixed-coverage", inventory: inspect(mixed_coverage_composition) ?? crash "invalid mixed coverage", subject, context: { ..context, namespace: "https://example.org/sbom/fixture/mixed-coverage/revision-1" } },
			{ name: "native-arm64", inventory: arm_inventory, subject: { ..subject, target: "aarch64-linux" }, context: { ..context, namespace: "https://example.org/sbom/fixture/arm64/revision-1" } },
			{ name: "reviewed-source", inventory: reviewed_inventory, subject: reviewed_subject, context: { ..context, namespace: "https://example.org/sbom/fixture/reviewed-source/revision-1" } },
			{ name: "source-bundle", inventory: source_bundle_inventory, subject: { ..subject, filename: "sample-source-bundle", target: "source", sha256: Crypto.SHA256.hash("fixture source bundle\n".to_utf8()).to_hex() }, context: { ..context, namespace: "https://example.org/sbom/fixture/source/revision-1" } },
			{ name: "native-source-import", inventory: native_from_source ?? crash "invalid source import fixture", subject: source_import_subject, context: source_import_context },
			{ name: "verified-empty", inventory: empty_inventory, subject, context: { ..context, namespace: "https://example.org/sbom/fixture/empty/revision-1" } },
			{ name: "unknown-closure", inventory: unknown_inventory, subject, context: { ..context, namespace: "https://example.org/sbom/fixture/unknown/revision-1" } },
		]
	}

	output : Try(Str, Str)
	output = Sbom.render(inventory ?? crash "invalid fixture", subject, context)

	## The standalone tool's inputs for the native-linux case, as
	## `tests/sbom/fixtures/input/` holds them: the evaluated Spec and Lock,
	## the composition, the inventory `inspect` writes for `x86_64-linux`, and
	## the subject, context and artifact `bind` takes. Regenerate them with
	## `scripts/test_sbom.roc inputs tests/sbom/fixtures/input`.
	input_files : List({ name : Str, text : Str })
	input_files = [
		{ name: "Spec", text: spec.to_str() },
		{ name: "Lock", text: lock.to_str() },
		{ name: "composition.json", text: Json.to_str(composition) },
		{ name: "inventory.json", text: "${Json.to_str(inventory ?? crash "fixture invalid")}\n" },
		{ name: "subject.json", text: Json.to_str(subject) },
		{ name: "context.json", text: Json.to_str(context) },
		{ name: "sample-artifact", text: subject_bytes },
	]

	## What `tests/sbom/fixtures/source-import/expected.json` states for the
	## standalone tool: which inputs it reads, each target `inspect` accepts
	## with the inventory it writes, what `bind` takes and which committed
	## renderings it reproduces, and each composition it refuses with the
	## exact message and what that refusal proves.
	SourceImport : {
		inputs : { spec : Str, lock : Str, composition : Str },
		accepted : List({ target : Str, inventory : Str }),
		bound : { inventory : Str, subject : Str, context : Str, artifact : Str, renderings : Str },
		refused : List({ composition : Str, target : Str, refusal : Str, proves : Str }),
	}

	source_import : SourceImport
	source_import = {
		inputs: { spec: "Spec", lock: "Lock", composition: "composition.json" },
		accepted: [
			{ target: "source", inventory: "inventory-source.json" },
			{ target: "x86_64-linux", inventory: "inventory-x86_64-linux.json" },
			{ target: "aarch64-linux", inventory: "inventory-aarch64-linux.json" },
		],
		bound: { inventory: "inventory-x86_64-linux.json", subject: "subject.json", context: "context.json", artifact: "consumer-artifact", renderings: "native-source-import" },
		refused: source_import_refusals.map(|refused| { composition: refused.composition, target: refused.target, refusal: refused.refusal, proves: refused.proves }),
	}

	## The standalone tool's inputs for a source supplier imported into
	## consumers, as `tests/sbom/fixtures/source-import/` holds them: the
	## consumer's Spec and Lock, its composition with the supplier document
	## embedded, the inventory `inspect` writes for each accepted target, the
	## subject, context and artifact `bind` takes, one composition per
	## refusal, and `expected.json`. Regenerate them with
	## `scripts/test_sbom.roc source-import tests/sbom/fixtures/source-import`.
	source_import_files : List({ name : Str, text : Str })
	source_import_files =
		[
			{ name: source_import.inputs.spec, text: consumer_spec.to_str() },
			{ name: source_import.inputs.lock, text: consumer_lock.to_str() },
			{ name: source_import.inputs.composition, text: Json.to_str(source_consumer) },
			{ name: source_import.bound.subject, text: Json.to_str(source_import_subject) },
			{ name: source_import.bound.context, text: Json.to_str(source_import_context) },
			{ name: source_import.bound.artifact, text: consumer_bytes },
			{ name: "expected.json", text: "${Json.to_str(source_import)}\n" },
		]
			.concat(source_import.accepted.map(|accepted| { name: accepted.inventory, text: "${Json.to_str(Sbom.inspect(consumer_spec, consumer_lock, accepted.target, source_consumer) ?? crash "invalid ${accepted.target} source import fixture")}\n" }))
			.concat(source_import_refusals.map(|refused| { name: refused.composition, text: Json.to_str(refused.tampered) }))

	## `tests/sbom/fixtures/CONTRACT.md`: every case of the set, its inputs,
	## its expected outputs or refusal, and what it proves, written from the
	## values above. Regenerate it with
	## `scripts/test_sbom.roc contract tests/sbom/fixtures/CONTRACT.md`.
	contract : Str
	contract = contract_text
}

digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

component : Str, Str, Str -> Sbom.Component
component = |id, name, version| { kind: "library", copyright: "NOASSERTION", attribution: "NOASSERTION", package_url: "", source_refs: [], id, name, version, producer: "Organization: Fixture upstream", identity: "https://example.org/source/${name}/${version}", download: "https://example.org/source/${name}/${version}.tar.gz", sha256: "", license: "MIT", license_url: "", modified: "", target: "x86_64-linux", origin: "reviewed" }

edge = |from, to, relation| { from, to, relation, scope: "", basis: "Reviewed fixture composition declaration" }

inspect = |composition| Sbom.inspect(SbomTest.spec, SbomTest.lock, "x86_64-linux", composition)

expect SbomTest.inventory.is_ok()
expect SbomTest.output.is_ok()
expect inspect({ ..SbomTest.composition, components: [] }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.concat(SbomTest.composition.components) }).is_err()
expect inspect({ ..SbomTest.composition, relationships: [edge("Subject", "missing", "contains")] }).is_err()
expect inspect({ ..SbomTest.composition, relationships: [edge("native", "platform", "contains")] }).is_err()
expect inspect({ ..SbomTest.composition, coverage: [] }).is_err()
expect inspect({ ..SbomTest.composition, coverage: [{ scope: "all", component: "Subject", aspect: "dependencies", status: "unknown", reason: "", contact: "contact" }] }).is_err()
expect inspect({ ..SbomTest.composition, relationships: SbomTest.composition.relationships.concat(SbomTest.composition.relationships) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, target: "aarch64-linux" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, origin: "import:https://unverified.example/sbom" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, sha256: "bad" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, version: "" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, license: "LicenseRef-restricted", license_url: "" }) }).is_err()

# Unknown and verified-empty inventories are distinct, explicitly asserted facts.
empty_composition = { ..SbomTest.composition, components: [], relationships: [], coverage: [{ scope: "all", component: "Subject", aspect: "dependencies", status: "verified-empty", reason: "Reviewed generated text contains no third-party components", contact: "https://example.org/support" }] }
expect inspect(empty_composition).is_ok()
expect inspect({ ..empty_composition, coverage: [{ scope: "all", component: "Subject", aspect: "dependencies", status: "unknown", reason: "No closure data exposed by opaque task", contact: "https://example.org/support" }] }).is_ok()

# Coverage is addressed explicitly; an assembly declaration does not cascade.
claim = |scope, component_, aspect, status| { scope, component: component_, aspect, status, reason: "Reviewed fixture coverage", contact: "https://example.org/support" }

mixed_coverage_composition = { ..SbomTest.composition, coverage: [claim("shipped-source", "Subject", "assembly", "complete"), claim("external-packages", "platform", "dependencies", "verified-empty"), claim("compiler-closure", "compiler", "dependencies", "unknown"), claim("native-closure", "native", "dependencies", "incomplete")] }
expect inspect(mixed_coverage_composition).is_ok()
expect inspect({ ..mixed_coverage_composition, coverage: [claim("dangling", "missing", "dependencies", "unknown")] }).is_err()
expect inspect({ ..mixed_coverage_composition, coverage: [claim("bad-aspect", "Subject", "native", "complete")] }).is_err()
expect inspect({ ..mixed_coverage_composition, coverage: [claim("partial", "", "dependencies", "complete")] }).is_err()
expect inspect({ ..mixed_coverage_composition, coverage: [claim("one", "compiler", "dependencies", "unknown"), claim("two", "compiler", "dependencies", "complete")] }).is_err()
expect inspect({ ..mixed_coverage_composition, coverage: [claim("false-empty", "Subject", "dependencies", "verified-empty")] }).is_err()
expect inspect({ ..mixed_coverage_composition, coverage: [claim("false-empty", "Subject", "assembly", "verified-empty")] }).is_err()

mixed_cdx = Sbom.render_cyclonedx(inspect(mixed_coverage_composition) ?? crash "mixed coverage invalid", SbomTest.subject, SbomTest.context) ?? crash "mixed coverage render failed"
expect {
	# Inspect ordinary standard fields independently of Blueprint evidence.
	tree = JsonData.decode_with(mixed_cdx, JsonData.documents) ?? crash "bad JSON"
	compositions = (tree.field("compositions") ?? JsonData.Null).array() ?? []
	dependencies = (tree.field("dependencies") ?? JsonData.Null).array() ?? []
	has_claim = |aggregate, aspect, ref| compositions.any(|entry| entry.field("aggregate") == Ok(JsonData.String(aggregate)) and entry.field(aspect) == Ok(JsonData.Array([JsonData.String(ref)])))
	has_claim("complete", "assemblies", "Subject") and has_claim("complete", "dependencies", "platform") and has_claim("unknown", "dependencies", "compiler") and has_claim("incomplete", "dependencies", "native") and dependencies.len() == 2 and dependencies.any(|entry| entry.field("ref") == Ok(JsonData.String("platform")) and entry.field("dependsOn").is_err()) and dependencies.any(|entry| entry.field("ref") == Ok(JsonData.String("Subject")) and entry.field("dependsOn") == Ok(JsonData.Array([JsonData.String("compiler")])))
}
expect Sbom.read_cyclonedx(mixed_cdx).is_ok()
expect Sbom.read_cyclonedx(mixed_cdx.replace_each("\"aggregate\":\"unknown\"", "\"aggregate\":\"complete\"")).is_err()
expect Sbom.read_cyclonedx(mixed_cdx.replace_each("\"dependencies\":[\"compiler\"]", "\"dependencies\":[\"missing\"]")).is_err()
expect {
	inventory = inspect(mixed_coverage_composition) ?? crash "bad mixed fixture"
	three = Sbom.render(inventory, SbomTest.subject, SbomTest.context) ?? crash "bad SPDX3"
	two = Sbom.render_spdx2(inventory, SbomTest.subject, SbomTest.context) ?? crash "bad SPDX2"
	a = Sidecar.check(three) ?? crash "bad SPDX3 check"
	b = Sidecar.check(two) ?? crash "bad SPDX2 check"
	c = Sidecar.check(mixed_cdx) ?? crash "bad CDX check"
	Sidecar.same_graph(a, b) and Sidecar.same_graph(a, c)
}
expect {
	text = Sbom.render(inspect(mixed_coverage_composition) ?? crash "bad mixed fixture", SbomTest.subject, SbomTest.context) ?? crash "bad SPDX3"
	upstream = { ..imported_document, document: text, sha256: Crypto.SHA256.hash(text.to_utf8()).to_hex() }
	inventory = inspect({ ..SbomTest.composition, components: [], relationships: [], imported_documents: [upstream] }) ?? crash "import failed"
	inventory.coverage.any(|entry| entry.component == "upstream-compiler" and entry.aspect == "dependencies" and entry.status == "unknown") and inventory.coverage.any(|entry| entry.component == "upstream-platform" and entry.status == "verified-empty")
}

expect {
	# A supplier's standard compositions survive import without Blueprint properties.
	foreign = mixed_cdx.replace_each("blueprint:namespace", "supplier:namespace")
	decoded = Sbom.read(foreign) ?? crash "foreign compositions unreadable"
	upstream = { ..imported_document, namespace: decoded.namespace, document: foreign, sha256: Crypto.SHA256.hash(foreign.to_utf8()).to_hex() }
	inventory = inspect({ ..SbomTest.composition, components: [], relationships: [], imported_documents: [upstream] }) ?? crash "foreign coverage import failed"
	inventory.coverage.any(|entry| entry.component == "upstream-compiler" and entry.aspect == "dependencies" and entry.status == "unknown") and inventory.coverage.any(|entry| entry.component == "upstream-platform" and entry.aspect == "dependencies" and entry.status == "complete")
}

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
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, license: "MIT OR ( Apache-2.0 WITH LLVM-exception )", license_url: "" }) }).is_ok()
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
committed_fixtures = [{ name: "reviewed-source.cdx.json", text: fixture_reviewed_source_cdx }, { name: "reviewed-source.spdx.json", text: fixture_reviewed_source_3 }, { name: "reviewed-source.spdx-2.3.json", text: fixture_reviewed_source_2 }, { name: "mixed-coverage.cdx.json", text: fixture_mixed_coverage_cdx }, { name: "mixed-coverage.spdx.json", text: fixture_mixed_coverage_3 }, { name: "mixed-coverage.spdx-2.3.json", text: fixture_mixed_coverage_2 }, { name: "native-source-import.cdx.json", text: fixture_native_source_import_cdx }, { name: "native-source-import.spdx.json", text: fixture_native_source_import_3 }, { name: "native-source-import.spdx-2.3.json", text: fixture_native_source_import_2 }, { name: "verified-import.cdx.json", text: fixture_verified_import_cdx }, { name: "native-linux.cdx.json", text: fixture_native_linux_cdx }, { name: "native-arm64.cdx.json", text: fixture_native_arm64_cdx }, { name: "source-bundle.cdx.json", text: fixture_source_bundle_cdx }, { name: "verified-empty.cdx.json", text: fixture_verified_empty_cdx }, { name: "unknown-closure.cdx.json", text: fixture_unknown_closure_cdx }, { name: "verified-import.spdx.json", text: fixture_verified_import_3 }, { name: "verified-import.spdx-2.3.json", text: fixture_verified_import_2 }, { name: "native-linux.spdx.json", text: fixture_native_linux_3 }, { name: "native-linux.spdx-2.3.json", text: fixture_native_linux_2 }, { name: "native-arm64.spdx.json", text: fixture_native_arm64_3 }, { name: "native-arm64.spdx-2.3.json", text: fixture_native_arm64_2 }, { name: "source-bundle.spdx.json", text: fixture_source_bundle_3 }, { name: "source-bundle.spdx-2.3.json", text: fixture_source_bundle_2 }, { name: "verified-empty.spdx.json", text: fixture_verified_empty_3 }, { name: "verified-empty.spdx-2.3.json", text: fixture_verified_empty_2 }, { name: "unknown-closure.spdx.json", text: fixture_unknown_closure_3 }, { name: "unknown-closure.spdx-2.3.json", text: fixture_unknown_closure_2 }]
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
schema_3_digest = "582c64e809d5b3ef9bd0c4de13a32391b47b0284a3e8d199569fb96f649234b1"

schema_2_digest = "4126dc29f15e92feec92e9622f4939131ad58b125d6f578aa93e980a6e6f3212"

schema_cdx_digest = "73308edec3ab2d38bfffd993e96a042b594314143b6971a6e9ed98bbb6bd76ce"

expect Crypto.SHA256.hash(schema_3.to_utf8()).to_hex() == schema_3_digest
expect Crypto.SHA256.hash(schema_2.to_utf8()).to_hex() == schema_2_digest

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
	components = cdx_components(bom)
	scope = |ref| components.find_first(|entry| entry.field("bom-ref") == Ok(JsonData.String(ref))).map_ok(|entry| (entry.field("scope") ?? JsonData.Null).string() ?? "") ?? ""
	scope("native") == "required" and scope("platform") == "required" and scope("restricted") == "required" and scope("compiler") == "excluded"
}
# Walk standard component fields without consulting Blueprint properties.
cdx_children : JsonData -> List(JsonData)
cdx_children = |node| {
	children = (node.field("components") ?? JsonData.Array([])).array() ?? []
	children.fold([], |all, child| all.append(child).concat(cdx_children(child)))
}

cdx_components : JsonData -> List(JsonData)
cdx_components = |bom| cdx_children(bom).concat(cdx_children((bom.field("metadata") ?? JsonData.Null).field("component") ?? JsonData.Null))

without_blueprint : JsonData -> JsonData
without_blueprint = |tree|
	match tree {
		Object(fields) => JsonData.Object(
			fields.map(
				|field| {
					value = if field.name == "properties" {
						JsonData.Array((field.value.array() ?? []).keep_if(|entry| !((entry.field("name") ?? JsonData.Null).string() ?? "").starts_with("blueprint:")))
					} else without_blueprint(field.value)
					{ name: field.name, value }
				},
			),
		)
		Array(items) => JsonData.Array(items.map(without_blueprint))
		_ => tree
	}

expect {
	bom = without_blueprint(JsonData.decode_with(fixture_native_linux_cdx, JsonData.documents) ?? crash "fixture")
	children = |object| ((object.field("components") ?? JsonData.Array([])).array() ?? []).map(|entry| (entry.field("bom-ref") ?? JsonData.Null).string() ?? "")
	subject = (bom.field("metadata") ?? JsonData.Null).field("component") ?? JsonData.Null
	assembly = cdx_components(bom).find_first(|entry| entry.field("bom-ref") == Ok(JsonData.String("platform"))) ?? crash "platform"
	dependencies = (bom.field("dependencies") ?? JsonData.Array([])).array() ?? []
	outgoing = |ref| dependencies.find_first(|entry| entry.field("ref") == Ok(JsonData.String(ref))).map_ok(|entry| (entry.field("dependsOn") ?? JsonData.Array([])).array() ?? []) ?? []
	children(subject) == ["platform", "restricted"] and children(assembly) == ["native"] and children(bom) == ["compiler"] and outgoing("Subject") == [JsonData.String("compiler")] and outgoing("platform").is_empty()
}
expect {
	bom = without_blueprint(JsonData.decode_with(fixture_native_linux_cdx, JsonData.documents) ?? crash "fixture")
	text = JsonData.encode_with(bom, JsonData.documents) ?? crash "encode"
	imported = Sbom.read(text) ?? crash "plain standard import"
	imported.relationships.any(|relation| relation.from == "Subject" and relation.to == "platform" and relation.relation == "contains") and imported.relationships.any(|relation| relation.from == "platform" and relation.to == "native" and relation.relation == "contains") and imported.relationships.keep_if(|relation| relation.relation == "dependsOn").map(|relation| { from: relation.from, to: relation.to }) == [{ from: "Subject", to: "compiler" }]
}
expect {
	inventory = SbomTest.inventory ?? crash "fixture"
	# A shared child and containment cycles stay valid inventory graph statements,
	# but CycloneDX cannot represent them as unique nested components.
	shared = { ..inventory, relationships: inventory.relationships.append(edge("restricted", "native", "contains")) }
	cycle = { ..inventory, relationships: inventory.relationships.map(|relation| if (relation.from == "Subject" and relation.to == "platform") { ..relation, relation: "other" } else relation).append(edge("native", "platform", "contains")) }
	subject_child = { ..inventory, relationships: inventory.relationships.append(edge("native", "Subject", "contains")) }
	Sbom.render_cyclonedx(shared, SbomTest.subject, SbomTest.context).is_err() and Sbom.render_cyclonedx(cycle, SbomTest.subject, SbomTest.context) == Err("CycloneDX containment contains a cycle") and Sbom.render_cyclonedx(subject_child, SbomTest.subject, SbomTest.context).is_err()
}
expect {
	# Hoisting the same components breaks the standard containment mapping even
	# while every Blueprint relationship property remains unchanged.
	bom = JsonData.decode_with(fixture_native_linux_cdx, JsonData.documents) ?? crash "fixture"
	flat = match bom {
		Object(fields) => JsonData.Object(
			fields.map(
				|field| if field.name == "metadata" {
					{
						..field,
						value: match field.value {
							Object(metadata_fields) => JsonData.Object(
								metadata_fields.map(
									|item| if item.name == "component" {
										{
											..item,
											value: match item.value {
												Object(component_fields) => JsonData.Object(component_fields.keep_if(|part| part.name != "components"))
												_ => item.value
											},
										}
									} else item,
								),
							)
							_ => field.value
						},
					}
				} else if field.name == "components" {
					{
						..field,
						value: JsonData.Array(
							cdx_components(bom).map(
								|node| match node {
									Object(parts) => JsonData.Object(parts.keep_if(|part| part.name != "components"))
									_ => node
								},
							),
						),
					}
				} else field,
			),
		)
		_ => bom
	}
	Sbom.read_cyclonedx(JsonData.encode_with(flat, JsonData.documents) ?? "").is_err()
}
expect Sbom.read_cyclonedx(fixture_native_linux_cdx.replace_each("\"bom-ref\":\"native\"", "\"bom-ref\":\"platform\"")).is_err()
expect Sbom.read_cyclonedx(fixture_native_linux_cdx.replace_each("\"dependsOn\":[\"compiler\"]", "\"dependsOn\":[\"compiler\",\"platform\"]")).is_err()
expect Sbom.read_cyclonedx(fixture_native_linux_cdx.replace_each("standard-containment-v1", "unsupported-profile")).is_err()
expect Sbom.read_cyclonedx(fixture_legacy_cdx).is_ok()
expect Sbom.read_cyclonedx(fixture_legacy_cdx.replace_each("blueprint:namespace", "blueprint:cyclonedx-profile")).is_err()

expect {
	bom = JsonData.decode_with(fixture_native_linux_cdx, JsonData.documents) ?? crash "fixture"
	serial = (bom.field("serialNumber") ?? JsonData.Null).string() ?? ""
	other = JsonData.decode_with(fixture_verified_empty_cdx, JsonData.documents) ?? crash "fixture"
	serial.starts_with("urn:uuid:") and serial.to_utf8().get(23) == Ok('8') and other.field("serialNumber") != bom.field("serialNumber") and bom.field("version") == Ok(JsonData.Number("1"))
}
expect Sbom.read_cyclonedx(fixture_native_linux_cdx.replace_each("\"dependsOn\":[\"compiler\"]", "\"dependsOn\":[]")).is_err()
expect Sbom.read_cyclonedx(fixture_native_linux_cdx.replace_each("blueprint:namespace", "other:namespace")).is_err()
expect Sbom.read_cyclonedx(fixture_native_linux_cdx.replace_each("\"scope\":\"excluded\"", "\"scope\":\"required\"")).is_err()
expect Sbom.read(fixture_native_linux_cdx) == Sbom.read_cyclonedx(fixture_native_linux_cdx)

# The CycloneDX validator follows the vendored, digest-pinned 1.7 schema.
expect Crypto.SHA256.hash(schema_cdx.to_utf8()).to_hex() == schema_cdx_digest

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
expect (Sbom.read(upstream_syft_spdx) ?? crash "syft spdx").gaps == []
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
	inventory.components.any(|entry| entry.kind == "file") and coverage.status == "incomplete" and inventory.components.any(|entry| entry.identity.starts_with("pkg:cargo/libsqlite3-sys@0.33.0"))
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

# A source archive is architecture-independent: its consumer's compiler builds
# it for the consumer's target. So a supplier's SBOM for one, such as a Roc
# package bundle's, imports into a native executable's inventory with its
# `source` target kept, never relabelled as native code, while the archive
# digest, version and namespace bind exactly as a native supplier's do.
source_bundle_inventory = Sbom.inspect(SbomTest.spec, SbomTest.lock, "source", { ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, target: "" }) }) ?? crash "invalid source fixture"

source_supplier_sbom = Sbom.render(source_bundle_inventory, { ..SbomTest.subject, filename: "dep-abc.tar.zst", version: "1.2.0", target: "source", sha256: bundle_digest, url: bundle_url }, { ..SbomTest.context, namespace: "https://example.org/sbom/dep-source/revision-1" }) ?? crash "source supplier SBOM"

source_supplier_import = { ..supplier_import, namespace: "https://example.org/sbom/dep-source/revision-1", target: "source", document: source_supplier_sbom, sha256: Crypto.SHA256.hash(source_supplier_sbom.to_utf8()).to_hex() }

source_consumer = { ..consumer, components: [{ ..dependency, target: "source" }], relationships: [{ ..edge("Subject", "dep", "dependsOn"), scope: "build" }], imported_documents: [source_supplier_import] }

native_from_source : Try(Sbom.Inventory, Str)
native_from_source = Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", source_consumer)

expect
	match native_from_source {
		Ok(inventory) =>
			inventory.target == "x86_64-linux"
				and inventory.components.all(|entry| entry.target == "source")
					and inventory.components.any(|entry| entry.id == "dep" and entry.sha256 == bundle_digest and entry.version == "1.2.0")
						and inventory.relationships.any(|relation| relation.from == "dep-sbom-Subject" and relation.to == "dep" and relation.relation == "copiedTo")
							and inventory.coverage.any(|scope| scope.scope == "import:dep-sbom" and scope.reason.starts_with("Document digest and upstream subject artifact identity match"))
		Err(_) => False
	}
expect Sbom.inspect(consumer_spec, consumer_lock, "source", source_consumer).is_ok()
expect Sbom.inspect(consumer_spec, consumer_lock, "aarch64-linux", source_consumer).is_ok()
expect Sbom.admits_target("x86_64-linux", "source") and Sbom.admits_target("x86_64-linux", "") and Sbom.admits_target("source", "x86_64-linux") and !Sbom.admits_target("x86_64-linux", "aarch64-linux")

# The supplier's artifact binds exactly: other bytes, another version or
# another target than the supplier states do not.
expect Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", { ..source_consumer, imported_documents: [{ ..source_supplier_import, subject: { ..source_supplier_import.subject, sha256: digest } }] }) == Err("import subject filename/version/SHA256 mismatch")
expect Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", { ..source_consumer, imported_documents: [{ ..source_supplier_import, subject: { ..source_supplier_import.subject, version: "1.2.1" } }] }) == Err("import subject filename/version/SHA256 mismatch")
expect Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", { ..source_consumer, imported_documents: [{ ..source_supplier_import, target: "x86_64-linux" }] }) == Err("imported document subject target mismatch")
expect Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", { ..source_consumer, components: [{ ..dependency, target: "x86_64-linux" }] }) == Err("imported subject conflicts with authoritative component artifact")

# A native supplier still has to match the inventory's target, and an import
# has to state one.
expect Sbom.inspect(consumer_spec, consumer_lock, "aarch64-linux", consumer) == Err("import target differs from subject")
expect Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", { ..source_consumer, imported_documents: [{ ..source_supplier_import, target: "aarch64-linux" }] }) == Err("import target differs from subject")
expect Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", { ..source_consumer, imported_documents: [{ ..source_supplier_import, target: "" }] }) == Err("import target differs from subject")
expect Sbom.inspect(consumer_spec, consumer_lock, "x86_64-linux", { ..source_consumer, components: [{ ..dependency, target: "aarch64-linux" }], imported_documents: [{ ..source_supplier_import, target: "aarch64-linux" }] }) == Err("import target differs from subject")

# Every rendering keeps the source identity through check and readback, and
# a build-scoped source dependency ships nothing: it is excluded, and no
# `contains` reaches it from the subject.
expect [fixture_native_source_import_3, fixture_native_source_import_2, fixture_native_source_import_cdx].all(
	|text|
		match Sidecar.check(text) {
			Ok(checked) =>
				checked.evidence.target == "x86_64-linux"
					and checked.subject.comment.contains("\"target\":\"x86_64-linux\"")
						and checked.document.packages_.keep_if(|entry| entry.id != "Subject").all(|entry| entry.comment.contains("\"target\":\"source\""))
							and !containers(checked.document, "dep").contains("Subject")
								and checked.document.relationships.any(|relation| relation.from == "Subject" and relation.to == "dep" and relation.relation == "dependsOn" and relation.scope == "build")
			Err(_) => False
		},
)
expect {
	bom = JsonData.decode_with(fixture_native_source_import_cdx, JsonData.documents) ?? crash "fixture"
	components = cdx_components(bom)
	scope = |ref| components.find_first(|entry| entry.field("bom-ref") == Ok(JsonData.String(ref))).map_ok(|entry| (entry.field("scope") ?? JsonData.Null).string() ?? "") ?? ""
	scope("dep") == "excluded" and components.all(|entry| (entry.field("scope") ?? JsonData.Null).string() != Ok("required"))
}

# A source bundle is inventoried from the archive the bundler produced, member
# by member: a bundler packs what a module imports as well as what it is
# given, so a module that imports a text file and a LICENSE ships four
# members. Each is stated by its digest, and a composition that omits one is
# refused by name.
member = |name, content| { name, size: content.to_utf8().len(), sha256: Crypto.SHA256.hash(content.to_utf8()).to_hex() }

bundle_members = [member("main.roc", "module [hello]\n"), member("Example.roc", "import \"message.txt\" as message : Str\n"), member("LICENSE", "UPL-1.0\n"), member("message.txt", "hello\n")]

message_input = "archive-member:message.txt:${Crypto.SHA256.hash("hello\n".to_utf8()).to_hex()}"

bundle_composition : Sbom.Composition
bundle_composition = {
	archive = Sbom.archive_members("sources", bundle_members) ?? crash "invalid member listing"
	sources = { ..component("sources", "example-bundle", "1.0.0"), target: "source" }
	{ ..SbomTest.composition, components: [sources].concat(archive.components), relationships: [edge("Subject", "sources", "contains")].concat(archive.relationships), coverage: [{ scope: "members", component: "", aspect: "", status: "complete", reason: "Every archive member is stated by SHA-256", contact: "https://example.org/support" }] }
}

## `bundle_composition` without the member `message.txt`.
dropped_composition = { ..bundle_composition, components: bundle_composition.components.keep_if(|entry| entry.id != "member-message.txt"), relationships: bundle_composition.relationships.keep_if(|relation| relation.to != "member-message.txt") }

inspect_bundle = |composition| Sbom.inspect_archive(SbomTest.spec, SbomTest.lock, "source", composition, bundle_members)

expect
	match Sbom.archive_members("sources", bundle_members) {
		Ok(archive) =>
			archive.components.map(|entry| entry.id) == ["member-main.roc", "member-Example.roc", "member-LICENSE", "member-message.txt"]
				and archive.components.all(|entry| entry.origin == "reviewed" and entry.target == "source" and entry.license == "NOASSERTION" and entry.download == "NOASSERTION" and entry.producer == "NOASSERTION" and entry.version == "sha256-${entry.sha256}" and entry.identity == "urn:blueprint:archive-member:${entry.name}:${entry.sha256}" and bundle_members.any(|listed| listed.name == entry.name and listed.sha256 == entry.sha256))
					and archive.relationships.all(|relation| relation.from == "sources" and relation.relation == "contains" and relation.scope.is_empty() and relation.basis.contains("bytes"))
						and archive.relationships.map(|relation| relation.to) == archive.components.map(|entry| entry.id)
		Err(_) => False
	}
expect
	match inspect_bundle(bundle_composition) {
		Ok(inventory) => inventory.components.keep_if(|entry| entry.identity.starts_with("urn:blueprint:archive-member:")).len() == 4 and inventory.inspected.is_empty()
		Err(_) => False
	}
expect
	match inspect_bundle(dropped_composition) {
		Err(problem) => problem.contains("message.txt (sha256 ") and problem.contains(message_input)
		Ok(_) => False
	}
expect Sbom.members_accounted(bundle_members, bundle_composition).is_ok()
expect Sbom.members_accounted(bundle_members, dropped_composition).is_err()
# Without the listing, the omission goes unnoticed: the archive is the proof.
expect Sbom.inspect(SbomTest.spec, SbomTest.lock, "source", dropped_composition).is_ok()
# A reviewer's own component that states the same bytes accounts for a member.
expect {
	reviewed = { ..bundle_composition, components: bundle_composition.components.map(|entry| if (entry.id == "member-LICENSE") { ..entry, id: "licence", name: "Universal Permissive License", license: "UPL-1.0", producer: "Organization: Oracle" } else entry), relationships: bundle_composition.relationships.map(|relation| if (relation.to == "member-LICENSE") { ..relation, to: "licence" } else relation) }
	inspect_bundle(reviewed).is_ok()
}
# So does an input disposition, which is then exported like any input's.
expect
	match inspect_bundle({ ..dropped_composition, inputs: [{ input: message_input, component: "", reason: "Greeting text imported by Example.roc; not code" }] }) {
		Ok(inventory) => inventory.inspected == [message_input] and inventory.inputs.len() == 1
		Err(_) => False
	}
# A disposition for a member a component already states is an unknown input.
expect inspect_bundle({ ..bundle_composition, inputs: [{ input: message_input, component: "member-message.txt", reason: "Stated twice" }] }).is_err()
# Only a source archive has members.
expect Sbom.inspect_archive(SbomTest.spec, SbomTest.lock, "x86_64-linux", bundle_composition, bundle_members).is_err()
# A listing with a repeated or unsafe name or a bad digest is refused.
expect Sbom.archive_members("sources", bundle_members.append(member("main.roc", "other"))).is_err()
expect Sbom.archive_members("sources", [member("../escape", "x")]).is_err()
expect Sbom.archive_members("sources", [member("/etc/passwd", "x")]).is_err()
expect Sbom.archive_members("sources", [member("a/./b", "x")]).is_err()
expect Sbom.archive_members("sources", [member("a b", "x")]).is_err()
expect Sbom.archive_members("sources", [member("", "x")]).is_err()
expect Sbom.archive_members("sources", [{ ..member("a", "x"), sha256: "BAD" }]).is_err()
expect Sbom.members_accounted([member("../escape", "x")], bundle_composition).is_err()
expect Sbom.archive_members("sources", [member("fonts/a+b.ttf", "x"), member("fonts/a-b.ttf", "y")]).is_ok()
expect Sbom.member_input(member("message.txt", "hello\n")) == message_input

# Binding inputs must track the current public Spec and Lock wire contracts.
expect Spec.parse(fixture_input_spec) == Ok(SbomTest.spec)
expect Lock.parse(fixture_input_lock) == Ok(SbomTest.lock)

# An evidence manifest renders deterministically, reads back, and is held to
# what a checker measured: the subject, each listed sidecar and the inventory.
manifest_digest = |text| Crypto.SHA256.hash(text.to_utf8()).to_hex()

manifest_sample : Manifest.Manifest
manifest_sample = {
	profile: Sbom.profile,
	subject: { filename: "sample-artifact", version: "1.0.0", target: "x86_64-linux", sha256: SbomTest.subject.sha256, size: 16 },
	inventory_sha256: manifest_digest("inventory"),
	context: { namespace: SbomTest.context.namespace, revision: SbomTest.context.revision, created: SbomTest.context.created, generator: SbomTest.context.generator },
	sidecars: [
		{ filename: "sample-artifact.spdx.json", format: "spdx-3.0.1", sha256: manifest_digest("three"), size: 3 },
		{ filename: "sample-artifact.cdx.json", format: "cyclonedx-1.7", sha256: manifest_digest("bom"), size: 4 },
	],
}

manifest_listed = { ..manifest_sample, sidecars: manifest_sample.sidecars.sort_with(|a, b| Project.bytewise(a.filename, b.filename)) }

manifest_text = Manifest.render(manifest_sample) ?? crash "manifest"

manifest_observed : Manifest.Observed
manifest_observed = { subject: { sha256: SbomTest.subject.sha256, size: 16 }, inventory: Measured(manifest_digest("inventory")), sidecars: manifest_sample.sidecars.map(|entry| { filename: entry.filename, sha256: entry.sha256, size: entry.size }) }

expect manifest_text == "{\"profile\":\"${Sbom.profile}\",\"subject\":{\"filename\":\"sample-artifact\",\"version\":\"1.0.0\",\"target\":\"x86_64-linux\",\"sha256\":\"${SbomTest.subject.sha256}\",\"size\":16},\"inventory_sha256\":\"${manifest_digest("inventory")}\",\"context\":{\"namespace\":\"${SbomTest.context.namespace}\",\"revision\":\"1\",\"created\":\"${SbomTest.context.created}\",\"generator\":\"${SbomTest.context.generator}\"},\"sidecars\":[{\"filename\":\"sample-artifact.cdx.json\",\"format\":\"cyclonedx-1.7\",\"sha256\":\"${manifest_digest("bom")}\",\"size\":4},{\"filename\":\"sample-artifact.spdx.json\",\"format\":\"spdx-3.0.1\",\"sha256\":\"${manifest_digest("three")}\",\"size\":3}]}\n"
expect Manifest.render(manifest_listed) == Ok(manifest_text)
expect Manifest.read(manifest_text) == Ok(manifest_listed)
expect Manifest.check(manifest_text.replace_each(Sbom.profile, "blueprint-spdx-3.0-v1"), manifest_observed) == Ok({ ..manifest_listed, profile: "blueprint-spdx-3.0-v1" })
expect Manifest.check(manifest_text, manifest_observed) == Ok(manifest_listed)
expect Manifest.check(manifest_text, { ..manifest_observed, inventory: Unmeasured }) == Ok(manifest_listed)
expect Manifest.check(manifest_text, { ..manifest_observed, sidecars: manifest_observed.sidecars.prepend({ filename: "sample-artifact.spdx-2.3.json", sha256: manifest_digest("two"), size: 9 }) }) == Ok(manifest_listed)
expect Manifest.formats == ["spdx-3.0.1", "spdx-2.3", "cyclonedx-1.7"] and Manifest.suffix == ".sbom-manifest.json"
expect Manifest.format_of("SPDX-3.0.1") == Ok("spdx-3.0.1") and Manifest.format_of("SPDX-2.3") == Ok("spdx-2.3") and Manifest.format_of("CycloneDX-1.7") == Ok("cyclonedx-1.7") and Manifest.format_of("SPDX-2.2").is_err()

# Each refusal names what differs: the profile, the subject's digest or size,
# a sidecar's digest or size, a listed sidecar that is absent, and the
# inventory's digest.
expect Manifest.read(manifest_text.replace_each(Sbom.profile, "blueprint-spdx-2.3-v1")) == Err("the manifest names profile blueprint-spdx-2.3-v1, not ${Sbom.profile}")
expect Manifest.check(manifest_text, { ..manifest_observed, subject: { ..manifest_observed.subject, sha256: manifest_digest("other bytes") } }) == Err("the subject's bytes differ from what the manifest states")
expect Manifest.check(manifest_text, { ..manifest_observed, subject: { ..manifest_observed.subject, size: 17 } }) == Err("the subject's size differs from what the manifest states")
expect Manifest.check(manifest_text, { ..manifest_observed, sidecars: manifest_observed.sidecars.map(|entry| if (entry.filename == "sample-artifact.cdx.json") { ..entry, sha256: manifest_digest("tampered") } else entry) }) == Err("sample-artifact.cdx.json differs from what the manifest states")
expect Manifest.check(manifest_text, { ..manifest_observed, sidecars: manifest_observed.sidecars.map(|entry| if (entry.filename == "sample-artifact.spdx.json") { ..entry, size: 30 } else entry) }) == Err("the size of sample-artifact.spdx.json differs from what the manifest states")
expect Manifest.check(manifest_text, { ..manifest_observed, sidecars: manifest_observed.sidecars.drop_if(|entry| entry.filename == "sample-artifact.cdx.json") }) == Err("the manifest lists sample-artifact.cdx.json, which is absent")
expect Manifest.check(manifest_text, { ..manifest_observed, inventory: Measured(manifest_digest("another inventory")) }) == Err("the inventory differs from the one the manifest states")

# A manifest names files by name alone and holds no developer path or
# credential; a rendered one lists each known-format sidecar once, with
# lowercase digests, apart from its subject.
expect Manifest.render({ ..manifest_sample, subject: { ..manifest_sample.subject, filename: "dist/sample-artifact" } }) == Err("the manifest must name its subject by file name alone")
expect ["out/sample-artifact.spdx.json", "..\\sample-artifact.spdx.json", "..", "", "sample-artifact"].all(|filename| Manifest.render({ ..manifest_sample, sidecars: [{ ..manifest_sample.sidecars.first() ?? crash "sample", filename }] }) == Err("the manifest must name each sidecar by file name alone, apart from its subject"))
expect Manifest.read(manifest_text.replace_each("\"sample-artifact.cdx.json\"", "\"../sample-artifact.cdx.json\"")) == Err("the manifest must name each sidecar by file name alone, apart from its subject")
expect Manifest.render({ ..manifest_sample, context: { ..manifest_sample.context, namespace: "https://example.org/Users/someone/revision-1" } }) == Err("the manifest holds a developer path or credential")
expect Manifest.read(manifest_text.replace_each(SbomTest.context.generator, "Tool: built in /home/someone")) == Err("the manifest holds a developer path or credential")
expect Manifest.render({ ..manifest_sample, sidecars: [] }) == Err("the manifest lists no sidecar")
expect Manifest.render({ ..manifest_sample, sidecars: manifest_sample.sidecars.concat(manifest_sample.sidecars) }) == Err("the manifest lists a sidecar twice")
expect Manifest.render({ ..manifest_sample, sidecars: manifest_sample.sidecars.map(|entry| { ..entry, format: "spdx-2.2" }) }).is_err()
expect Manifest.render({ ..manifest_sample, sidecars: manifest_sample.sidecars.map(|entry| { ..entry, sha256: Str.join_with(List.repeat("A", 64), "") }) }) == Err("sample-artifact.spdx.json needs a lowercase SHA-256")
expect Manifest.render({ ..manifest_sample, inventory_sha256: "" }) == Err("the inventory digest must be a lowercase SHA-256")
expect Manifest.render({ ..manifest_sample, subject: { ..manifest_sample.subject, target: "" } }) == Err("the subject needs a version, a target and a lowercase SHA-256")
expect Manifest.render({ ..manifest_sample, context: { ..manifest_sample.context, revision: "2" } }) == Err("namespace does not end with its revision")
expect Manifest.read("{\"profile\":\"${Sbom.profile}\"}").is_err() and Manifest.read("not json").is_err()

# A checked sidecar describes the manifest's subject, in the listed format.
expect {
	checked = Sidecar.check(fixture_native_linux_3) ?? crash "fixture"
	bom = Sidecar.check(fixture_native_linux_cdx) ?? crash "fixture"
	Manifest.describes(manifest_sample, "", checked) == Ok({})
		and Manifest.describes(manifest_sample, "sample-artifact.spdx.json", checked) == Ok({})
			and Manifest.describes(manifest_sample, "sample-artifact.cdx.json", bom) == Ok({})
				and Manifest.describes(manifest_sample, "sample-artifact.cdx.json", checked) == Err("sample-artifact.cdx.json is a SPDX-3.0.1 document, not the cyclonedx-1.7 sidecar the manifest lists")
					and Manifest.describes({ ..manifest_sample, subject: { ..manifest_sample.subject, version: "2.0.0" } }, "", checked) == Err("the sidecar describes sample-artifact 1.0.0, not the manifest's sample-artifact 2.0.0")
						and Manifest.describes({ ..manifest_sample, subject: { ..manifest_sample.subject, sha256: manifest_digest("other") } }, "", bom).is_err()
}

subject_bytes = "fixture subject\n"

# The standalone tool's inputs for the source supplier import. The consumer's
# artifact, subject and context are the native-source-import case's.
consumer_bytes = "consumer of fixture\n"

source_import_subject : Sbom.Subject
source_import_subject = { ..SbomTest.subject, filename: "consumer-artifact", sha256: Crypto.SHA256.hash(consumer_bytes.to_utf8()).to_hex() }

source_import_context : Sbom.Context
source_import_context = { ..SbomTest.context, namespace: "https://example.org/sbom/fixture/source-import/revision-1" }

## One composition per refusal of the source supplier import: its file name,
## the consumer target it is inspected for, the exact message, and what the
## refusal proves.
source_import_refusals : List({ composition : Str, target : Str, refusal : Str, proves : Str, tampered : Sbom.Composition })
source_import_refusals = [
	{ composition: "tamper-document-digest.json", target: "x86_64-linux", refusal: "imported SBOM content digest mismatch", proves: "The supplier document must hash to the digest the import states; a document with other bytes is not read.", tampered: { ..source_consumer, imported_documents: [{ ..source_supplier_import, sha256: digest }] } },
	{ composition: "tamper-subject-digest.json", target: "x86_64-linux", refusal: "import subject filename/version/SHA256 mismatch", proves: "The supplier's described artifact must be the bytes the consumer pinned: another SHA-256 does not bind.", tampered: { ..source_consumer, imported_documents: [{ ..source_supplier_import, subject: { ..source_supplier_import.subject, sha256: digest } }] } },
	{ composition: "tamper-subject-version.json", target: "x86_64-linux", refusal: "import subject filename/version/SHA256 mismatch", proves: "Another version of the same bytes does not bind either.", tampered: { ..source_consumer, imported_documents: [{ ..source_supplier_import, subject: { ..source_supplier_import.subject, version: "1.2.1" } }] } },
	{ composition: "tamper-import-native.json", target: "x86_64-linux", refusal: "imported document subject target mismatch", proves: "A `source` document cannot be imported as native code: the import's stated target must be the one the document states for its subject.", tampered: { ..source_consumer, imported_documents: [{ ..source_supplier_import, target: "x86_64-linux" }] } },
	{ composition: "tamper-component-native.json", target: "x86_64-linux", refusal: "imported subject conflicts with authoritative component artifact", proves: "The consumer's component for a `source` supplier cannot claim a native target: it conflicts with the bound artifact's identity.", tampered: { ..source_consumer, components: [{ ..dependency, target: "x86_64-linux" }] } },
	{ composition: "tamper-import-aarch64.json", target: "x86_64-linux", refusal: "import target differs from subject", proves: "A native target that is not the consumer's is refused, as for any native supplier; only `source` crosses architectures.", tampered: { ..source_consumer, imported_documents: [{ ..source_supplier_import, target: "aarch64-linux" }] } },
]

expect source_import_refusals.all(|refused| Sbom.inspect(consumer_spec, consumer_lock, refused.target, refused.tampered) == Err(refused.refusal))
expect SbomTest.source_import.accepted.all(
	|accepted|
		match Sbom.inspect(consumer_spec, consumer_lock, accepted.target, source_consumer) {
			Ok(inventory) => inventory.target == accepted.target and inventory.components.all(|entry| entry.target == "source")
			Err(_) => False
		},
)
# The inventory `bind` takes is the accepted native one, and it renders to the
# committed native-source-import documents with the subject and context written.
expect {
	bound = SbomTest.source_import.bound
	SbomTest.source_import.accepted.any(|accepted| accepted.inventory == bound.inventory and accepted.target == "x86_64-linux")
		and SbomTest.cases.any(|case| case.name == bound.renderings and Ok(case.inventory) == native_from_source and case.subject == source_import_subject and case.context == source_import_context)
}
# Everything expected.json names is a file of the set, and the committed
# expected.json reads back to the suite's own statement.
expect {
	names = SbomTest.source_import_files.map(|file| file.name)
	stated = SbomTest.source_import
	named = [stated.inputs.spec, stated.inputs.lock, stated.inputs.composition, stated.bound.inventory, stated.bound.subject, stated.bound.context, stated.bound.artifact].concat(stated.accepted.map(|accepted| accepted.inventory)).concat(stated.refused.map(|refused| refused.composition))
	parsed : Try(SbomTest.SourceImport, _)
	parsed = Json.parse(source_import_expected)
	named.all(|name| names.contains(name)) and parsed == Ok(stated)
}

# The committed inputs are what the suite writes now; regenerate them with
# `scripts/test_sbom.roc inputs tests/sbom/fixtures/input` and
# `scripts/test_sbom.roc source-import tests/sbom/fixtures/source-import`.
by_name = |files| files.sort_with(|a, b| Project.bytewise(a.name, b.name))

committed_input = [{ name: "Spec", text: fixture_input_spec }, { name: "Lock", text: fixture_input_lock }, { name: "composition.json", text: fixture_input_composition }, { name: "inventory.json", text: fixture_input_inventory }, { name: "subject.json", text: fixture_input_subject }, { name: "context.json", text: fixture_input_context }, { name: "sample-artifact", text: fixture_input_artifact }]

committed_source_import = [{ name: "Spec", text: source_import_spec }, { name: "Lock", text: source_import_lock }, { name: "composition.json", text: source_import_composition }, { name: "subject.json", text: source_import_subject_json }, { name: "context.json", text: source_import_context_json }, { name: "consumer-artifact", text: source_import_artifact }, { name: "expected.json", text: source_import_expected }, { name: "inventory-source.json", text: source_import_inventory_source }, { name: "inventory-x86_64-linux.json", text: source_import_inventory_x86_64 }, { name: "inventory-aarch64-linux.json", text: source_import_inventory_aarch64 }, { name: "tamper-document-digest.json", text: source_import_tamper_document_digest }, { name: "tamper-subject-digest.json", text: source_import_tamper_subject_digest }, { name: "tamper-subject-version.json", text: source_import_tamper_subject_version }, { name: "tamper-import-native.json", text: source_import_tamper_import_native }, { name: "tamper-component-native.json", text: source_import_tamper_component_native }, { name: "tamper-import-aarch64.json", text: source_import_tamper_import_aarch64 }]

expect by_name(SbomTest.input_files) == by_name(committed_input)
expect by_name(SbomTest.source_import_files) == by_name(committed_source_import)
expect Spec.parse(source_import_spec) == Ok(consumer_spec)
expect Lock.parse(source_import_lock) == Ok(consumer_lock)

## What each rendered case proves, with the bytes of its subject, for the
## contract. The cases and these notes are one list in one order.
case_notes : List({ name : Str, bytes : Str, proves : Str })
case_notes = [
	{ name: "verified-import", bytes: consumer_bytes, proves: "A native supplier's SBOM (the `native-linux` document) imported into a consumer and bound to the consumed input it describes, pinned by SHA-256: the supplier's components join the consumer's graph under `upstream-` identifiers, and the import's coverage states that the document digest and the subject's identity matched." },

	{ name: "native-linux", bytes: subject_bytes, proves: "The reference native inventory: a platform that contains a transitive native library with a digest of its own, a compiler that only builds the subject (`dependsOn` with scope `build`; CycloneDX scope `excluded`), patched restricted code that keeps its patch identity and licence terms, and an `incomplete` coverage record for the rest of the native closure." },
	{ name: "mixed-coverage", bytes: subject_bytes, proves: "Complete source assembly, verified-empty external package dependencies, incomplete native closure, and unknown compiler dependency closure use standard compositions without asserting unknown leaves empty." },
	{ name: "native-arm64", bytes: subject_bytes, proves: "The same composition for `aarch64-linux`: the subject and every component carry that target, and nothing from the `x86_64-linux` case is admitted." },
	{ name: "reviewed-source", bytes: subject_bytes, proves: "A reviewed source archive with a library, file and build compiler; explicit subject supplier and UPL-1.0 declaration, independent PURL and immutable VCS reference, exact digests and reviewed copyright/attribution. Mixed member licenses do not invent a subject conclusion." },
	{ name: "source-bundle", bytes: "fixture source bundle\n", proves: "An architecture-independent subject, target `source`, whose components state no target: what a source archive's own SBOM, such as a Roc package bundle's, looks like. It is the supplier document of the `native-source-import` case." },
	{ name: "native-source-import", bytes: consumer_bytes, proves: "The `source-bundle` document imported into an `x86_64-linux` consumer and bound to the file pin `source:dep`: every component keeps target `source`, the archive's digest and version bind exactly, and the build-scoped dependency ships nothing. Its inputs are under `source-import/`." },
	{ name: "verified-empty", bytes: subject_bytes, proves: "A reviewed subject with no third-party components, stated as `verified-empty` coverage: an asserted fact, distinct from not knowing." },
	{ name: "unknown-closure", bytes: subject_bytes, proves: "A subject whose closure is not known: no components, and an `unknown` coverage record with its reason and contact. A consumer must not read it as empty." },
]

expect SbomTest.cases.map(|case| case.name) == case_notes.map(|note| note.name)
expect SbomTest.cases.all(|case| case_notes.any(|note| note.name == case.name and Crypto.SHA256.hash(note.bytes.to_utf8()).to_hex() == case.subject.sha256))

## The case contract as Markdown: prose wrapped at 80 columns, one table row
## per case, and the commands a consumer runs over the set.
contract_text : Str
contract_text = {
	code = |text| "`${text}`"
	shown = |bytes| code(bytes.replace_each("\n", "\\n"))
	row = |cells| "| ${Str.join_with(cells, " | ")} |"
	case_rows = SbomTest.cases.map(
		|case| {
			note = case_notes.find_first(|entry| entry.name == case.name) ?? crash "no note for ${case.name}"
			row([code(case.name), code(case.subject.target), "${code(case.subject.filename)} ${case.subject.version}, the bytes ${shown(note.bytes)}", code(case.context.namespace), note.proves])
		},
	)
	accepted_rows = SbomTest.source_import.accepted.map(|accepted| row([code(accepted.target), code("source-import/${accepted.inventory}")]))
	refused_rows = SbomTest.source_import.refused.map(|refused| row([code("source-import/${refused.composition}"), code(refused.target), code(Str.concat("SBOM: Invalid(\"", Str.concat(refused.refusal, "\")"))), refused.proves]))
	inputs = SbomTest.source_import.inputs
	bound = SbomTest.source_import.bound
	Str.join_with(
		[
			"# SBOM fixture contract",
			"",
			"This is the fixture set of Blueprint's SBOM profile, `${Sbom.profile}`,",
			"as a release publishes it: `roc-blueprint-sbom-fixtures-<version>.zip`. The",
			"test suite of the roc-blueprint repository, `scripts/src/SbomTest.roc`,",
			"asserts every case below, and `scripts/test_sbom.roc contract` writes this",
			"file from the same values. The suite fails when a case, a committed file or",
			"this contract drifts from the others.",
			"",
			"The standalone tool is the `roc-blueprint-sbom-<hash>.tar.zst` bundle of the",
			"same release, run as `roc run <bundle-url> -- <command>`; `sbom` below stands",
			"for that. It never changes an input and never replaces an output that",
			"exists, so work in a scratch copy of the set. A refusal is printed on",
			"standard error as `SBOM: Invalid(\"<message>\")`, with exit code 1.",
			"",
			"## Rendered cases",
			"",
			"Each case is one inventory rendered three ways from one subject and",
			"context: `<case>.spdx.json` (SPDX 3.0.1 JSON-LD), `<case>.spdx-2.3.json`",
			"(SPDX 2.3) and `<case>.cdx.json` (CycloneDX 1.7). The three state one package",
			"graph, and `sbom check <case>.spdx.json <case>.spdx-2.3.json <case>.cdx.json`",
			"accepts them. The subject's SHA-256 in each document is that of the bytes",
			"shown.",
			"",
			row(["Case", "Target", "Subject", "Namespace", "Proves"]),
			row(["---", "---", "---", "---", "---"]),
		]
			.concat(case_rows)
			.concat([
				"",
				"## Native inputs: `input/`",
				"",
				"The standalone tool's inputs for the `native-linux` case: the evaluated",
				"`Spec` and `Lock` in their wire formats, `composition.json`, `subject.json`,",
				"`context.json` and the artifact `sample-artifact`. `inventory.json` is what",
				"`inspect` writes for `x86_64-linux`, byte for byte, and `bind` reproduces",
				"the committed renderings:",
				"",
				"```sh",
				"sbom inspect input/Spec input/Lock input/composition.json x86_64-linux out.json",
				"cmp out.json input/inventory.json",
				"sbom bind input/inventory.json input/subject.json input/context.json input/sample-artifact",
				"cmp input/sample-artifact.spdx.json native-linux.spdx.json",
				"cmp input/sample-artifact.cdx.json native-linux.cdx.json",
				"sbom bind input/inventory.json input/subject.json input/context.json input/sample-artifact out.spdx-2.3.json --spdx-2.3",
				"cmp out.spdx-2.3.json native-linux.spdx-2.3.json",
				"sbom check --artifacts input --inventory input/inventory.json native-linux.spdx.json native-linux.spdx-2.3.json native-linux.cdx.json",
				"```",
				"",
				"## Source supplier import: `source-import/`",
				"",
				"A consumer whose `Spec` holds one `source_files` entry, `dep`, pinned by the",
				"SHA-256 of a supplier's archive; whose `Lock` records that pin as a `file`",
				"provider source; and whose `composition.json` declares a `source:dep`",
				"component at target `source`, with the supplier's own SBOM (the",
				"`source-bundle` document, for the archive `dep-abc.tar.zst` 1.2.0) imported",
				"at target `source` and bound to that component. The dependency is",
				"build-scoped: the consumer's compiler builds the archive for the consumer's",
				"target, so the archive keeps its `source` identity in every consumer and is",
				"never relabelled as native code. `expected.json` states this section for",
				"automation: the inputs, each accepted target with its inventory, what `bind`",
				"takes and reproduces, and each refusal.",
				"",
				"### Accepted",
				"",
				"`inspect` writes each inventory byte for byte, and in every one each",
				"component keeps target `source`:",
				"",
				row(["Consumer target", "Inventory"]),
				row(["---", "---"]),
			])
			.concat(accepted_rows)
			.concat([
				"",
				"```sh",
				"sbom inspect source-import/${inputs.spec} source-import/${inputs.lock} source-import/${inputs.composition} x86_64-linux out.json",
				"cmp out.json source-import/${bound.inventory}",
				"```",
				"",
				"`bind` of that inventory to `${bound.artifact}` with `${bound.subject}` and",
				"`${bound.context}` reproduces the `${bound.renderings}` renderings:",
				"",
				"```sh",
				"sbom bind source-import/${bound.inventory} source-import/${bound.subject} source-import/${bound.context} source-import/${bound.artifact}",
				"cmp source-import/${bound.artifact}.spdx.json ${bound.renderings}.spdx.json",
				"cmp source-import/${bound.artifact}.cdx.json ${bound.renderings}.cdx.json",
				"```",
				"",
				"Build-only versus contained: in those renderings `dep` is excluded from what",
				"ships. The subject reaches it through `dependsOn` with scope `build` alone,",
				"no `contains` relationship leads from the subject to it, and its CycloneDX",
				"scope is `excluded` while no component is `required`.",
				"",
				"### Refused",
				"",
				"Each composition differs from `composition.json` in one value. `inspect` of",
				"it for the target shown exits 1 with the message, and writes nothing:",
				"",
				row(["Composition", "Target", "Refusal", "Proves"]),
				row(["---", "---", "---", "---"]),
			])
			.concat(refused_rows)
			.concat([
				"",
				"## Upstream documents: `upstream/`",
				"",
				"What Syft and Trivy wrote for one Cargo project, in CycloneDX and SPDX, as",
				"`upstream/README.md` describes. Each imports with exactly the gaps the suite",
				"states for it; what the profile cannot carry is counted, never dropped.",
				"",
				"## Schemas",
				"",
				"The set holds no schema. The JSON schemas the validators are held to are",
				"vendored in the repository's `tests/sbom/schema/`, each pinned by SHA-256:",
				"",
				row(["Schema", "SHA-256"]),
				row(["---", "---"]),
				row([code("spdx-3.0.1.schema.json"), code(schema_3_digest)]),
				row([code("spdx-2.3.schema.json"), code(schema_2_digest)]),
				row([code("cyclonedx-1.7/bom-1.7.schema.json"), code(schema_cdx_digest)]),
				"",
			]),
		"\n",
	)
}

# The committed contract is what the suite writes now; regenerate it with
# `scripts/test_sbom.roc contract tests/sbom/fixtures/CONTRACT.md`.
expect SbomTest.contract == fixture_contract

# The release asset holds exactly the files this suite asserts.
expect sorted(SbomFixtures.files) == sorted([SbomFixtures.contract, "legacy/blueprint-0.8.cdx.json"].concat(SbomTest.outputs.map(|file| file.name)).concat(SbomTest.input_files.map(|file| "input/${file.name}")).concat(SbomTest.source_import_files.map(|file| "source-import/${file.name}")).concat(["upstream/README.md", "upstream/syft.cdx.json", "upstream/syft.spdx.json", "upstream/trivy.cdx.json", "upstream/trivy.spdx.json"]))

# A reviewed source bundle keeps release/package/commit/member identities separate.
reviewed_subject = { ..SbomTest.subject, filename: "roc-ansi-0.13.3.tar.zst", version: "0.13.3", target: "source", producer: "Organization: Fixture upstream", license: "UPL-1.0", copyright: "Copyright 2026 Fixture upstream", attribution: "Reviewed source archive notice" }

reviewed_library = { ..component("ansi", "roc-ansi", "0.13.3"), target: "source", identity: "urn:example:source-tree:commit-abc", package_url: "pkg:generic/roc-ansi@0.13.3", source_refs: [{ type: "vcs", url: "https://example.org/roc-ansi/tree/abcdef0123456789" }], sha256: digest, license: "UPL-1.0", copyright: "Copyright 2026 Fixture upstream", attribution: "Library notice" }

reviewed_file = { ..component("ansi-file", "src/Ansi.roc", "0.13.3"), kind: "file", target: "source", identity: "urn:example:source-member:Ansi.roc", download: "NOASSERTION", sha256: digest, license: "UPL-1.0", copyright: "Copyright 2026 Fixture upstream", attribution: "Source notice" }

reviewed_compiler = { ..component("roc", "roc", "0.1.0"), kind: "application", target: "x86_64-linux", license: "MIT", copyright: "NOASSERTION", attribution: "NOASSERTION" }

reviewed_inventory = Sbom.inspect(SbomTest.spec, SbomTest.lock, "source", { ..SbomTest.composition, coverage: [claim("source-assembly", "Subject", "assembly", "complete"), claim("external-packages", "ansi", "dependencies", "verified-empty"), claim("compiler-closure", "roc", "dependencies", "unknown")], components: [reviewed_library, reviewed_file, reviewed_compiler], relationships: [edge("Subject", "ansi", "contains"), edge("ansi", "ansi-file", "contains"), { ..edge("Subject", "roc", "dependsOn"), scope: "build" }] }) ?? crash "reviewed fixture"

expect ["spdx3", "spdx2", "cdx"].all(
	|format| {
		text = if format == "cdx" Sbom.render_cyclonedx(reviewed_inventory, reviewed_subject, SbomTest.context) else if format == "spdx2" Sbom.render_spdx2(reviewed_inventory, reviewed_subject, SbomTest.context) else Sbom.render(reviewed_inventory, reviewed_subject, SbomTest.context)
		checked = Sidecar.check(text ?? crash "render reviewed") ?? crash "read reviewed"
		library = checked.document.packages_.find_first(|entry| entry.id == "ansi") ?? crash "library"
		file = checked.document.packages_.find_first(|entry| entry.id == "ansi-file") ?? crash "file"
		compiler = checked.document.packages_.find_first(|entry| entry.id == "roc") ?? crash "compiler"
		checked.subject.supplier == reviewed_subject.producer and checked.subject.license == "UPL-1.0" and library.identity == reviewed_library.package_url and library.source_refs == reviewed_library.source_refs and library.copyright == reviewed_library.copyright and library.attribution == reviewed_library.attribution and file.kind == "file" and compiler.kind == "application"
	},
)
expect Sbom.render_spdx2(reviewed_inventory, reviewed_subject, SbomTest.context).map_ok(|text| text.contains("\"licenseConcluded\":\"NOASSERTION\"")) == Ok(True)
expect Sbom.render_spdx2(reviewed_inventory, { ..reviewed_subject, producer: "NOASSERTION", license: "NOASSERTION" }, SbomTest.context).map_ok(|text| (Sbom.read(text) ?? crash "read").packages_.first().map_ok(|entry| entry.supplier == "NOASSERTION" and entry.license == "NOASSERTION") == Ok(True)) == Ok(True)
expect ["https://user:secret@example.org/src", "https://example.org/src?token=secret", "http://example.org/src"].all(|url| Sbom.inspect(SbomTest.spec, SbomTest.lock, "source", { ..SbomTest.composition, components: [{ ..reviewed_library, source_refs: [{ type: "vcs", url }] }], relationships: [edge("Subject", "ansi", "contains")] }).is_err())
expect Sbom.inspect(SbomTest.spec, SbomTest.lock, "source", { ..SbomTest.composition, components: [{ ..reviewed_library, identity: "pkg:generic/other@1" }], relationships: [edge("Subject", "ansi", "contains")] }).is_err()
expect Sbom.normalize_input("{\"profile\":\"blueprint-spdx-3.0-v1\",\"components\":[{\"origin\":\"reviewed\",\"producer\":\"NOASSERTION\",\"identity\":\"opaque\"}]}").map_ok(|value| value.contains("\"kind\":\"unknown\"") and value.contains(Sbom.profile)) == Ok(True)

expect {
	rendered = Sbom.render_cyclonedx(reviewed_inventory, reviewed_subject, SbomTest.context) ?? crash "render"
	tree = JsonData.decode_with(rendered, JsonData.documents) ?? crash "json"
	components = cdx_components(tree)
	library = components.find_first(|entry| (entry.field("bom-ref") ?? JsonData.Null).string() == Ok("ansi")) ?? crash "library"
	(library.field("type") ?? JsonData.Null).string() == Ok("library") and (library.field("purl") ?? JsonData.Null).string() == Ok(reviewed_library.package_url) and ((library.field("externalReferences") ?? JsonData.Null).array() ?? []).any(|ref| (ref.field("type") ?? JsonData.Null).string() == Ok("vcs") and (ref.field("url") ?? JsonData.Null).string() == Ok("https://example.org/roc-ansi/tree/abcdef0123456789"))
}
expect {
	rendered = Sbom.render_spdx2(reviewed_inventory, reviewed_subject, SbomTest.context) ?? crash "render"
	tree = JsonData.decode_with(rendered, JsonData.documents) ?? crash "json"
	entries = ((tree.field("packages") ?? JsonData.Null).array() ?? [])
	file = entries.find_first(|entry| (entry.field("SPDXID") ?? JsonData.Null).string() == Ok("SPDXRef-ansi-file")) ?? crash "file"
	(file.field("primaryPackagePurpose") ?? JsonData.Null).string() == Ok("FILE") and (file.field("copyrightText") ?? JsonData.Null).string() == Ok(reviewed_file.copyright) and ((file.field("attributionTexts") ?? JsonData.Null).array() ?? []).len() == 1
}
expect {
	rendered = Sbom.render_cyclonedx(reviewed_inventory, reviewed_subject, SbomTest.context) ?? crash "render"
	Sbom.read_cyclonedx(rendered.replace_each("\"type\":\"file\"", "\"type\":\"application\"")).is_err()
}
expect {
	subject = { ..reviewed_subject, license: "LicenseRef-Terms", license_url: "https://example.org/terms" }
	rendered = Sbom.render_cyclonedx(reviewed_inventory, subject, SbomTest.context) ?? crash "render"
	Sbom.read_cyclonedx(rendered.replace_each("\"type\":\"license\",\"url\":\"https://example.org/terms\"", "\"type\":\"license\",\"url\":\"https://example.org/other\"")).is_err()
}

expect ["spdx3", "spdx2", "cdx"].all(
	|format| {
		text = (if format == "cdx" Sbom.render_cyclonedx(reviewed_inventory, reviewed_subject, SbomTest.context) else if format == "spdx2" Sbom.render_spdx2(reviewed_inventory, reviewed_subject, SbomTest.context) else Sbom.render(reviewed_inventory, reviewed_subject, SbomTest.context)) ?? crash "render"
		imported = { ..imported_document, document: text, sha256: Crypto.SHA256.hash(text.to_utf8()).to_hex(), subject: { component: "", filename: reviewed_subject.filename, version: reviewed_subject.version, sha256: reviewed_subject.sha256 }, target: "source", namespace: SbomTest.context.namespace }
		inspected = Sbom.inspect(SbomTest.spec, SbomTest.lock, "source", { ..SbomTest.composition, components: [], relationships: [], imported_documents: [imported] }) ?? crash "import reviewed"
		inspected.components.any(|entry| entry.kind == "library" and entry.package_url == reviewed_library.package_url and entry.source_refs == reviewed_library.source_refs and entry.copyright == reviewed_library.copyright) and inspected.components.any(|entry| entry.kind == "file" and entry.name == reviewed_file.name)
	},
)

# A standard consumer sees the whole reviewed source contract without extensions.
expect {
	rendered = Sbom.render_cyclonedx(reviewed_inventory, reviewed_subject, SbomTest.context) ?? crash "render source"
	bom = without_blueprint(JsonData.decode_with(rendered, JsonData.documents) ?? crash "JSON")
	subject = (bom.field("metadata") ?? JsonData.Null).field("component") ?? JsonData.Null
	components = cdx_components(bom)
	find = |id| components.find_first(|entry| entry.field("bom-ref") == Ok(JsonData.String(id))) ?? crash "missing source component"
	children = |entry| ((entry.field("components") ?? JsonData.Array([])).array() ?? []).map(|child| child.field("bom-ref") ?? JsonData.Null)
	library = find("ansi")
	file = find("ansi-file")
	compiler = find("roc")
	dependencies = (bom.field("dependencies") ?? JsonData.Array([])).array() ?? []
	compositions = (bom.field("compositions") ?? JsonData.Array([])).array() ?? []
	composition = |aspect, id, status| compositions.any(|entry| entry.field("aggregate") == Ok(JsonData.String(status)) and entry.field(aspect) == Ok(JsonData.Array([JsonData.String(id)])))
	children(subject) == [JsonData.String("ansi")]
		and children(library) == [JsonData.String("ansi-file")]
			and library.field("type") == Ok(JsonData.String("library"))
				and file.field("type") == Ok(JsonData.String("file"))
					and compiler.field("type") == Ok(JsonData.String("application"))
						and compiler.field("scope") == Ok(JsonData.String("excluded"))
							and file.field("copyright") == Ok(JsonData.String(reviewed_file.copyright))
								and dependencies.len() == 2
									and dependencies.any(|entry| entry.field("ref") == Ok(JsonData.String("Subject")) and entry.field("dependsOn") == Ok(JsonData.Array([JsonData.String("roc")])))
										and dependencies.any(|entry| entry.field("ref") == Ok(JsonData.String("ansi")) and entry.field("dependsOn").is_err())
											and composition("assemblies", "Subject", "complete")
												and composition("dependencies", "ansi", "complete")
													and composition("dependencies", "roc", "unknown")
}

expect {
	rendered = Sbom.render_cyclonedx(reviewed_inventory, reviewed_subject, SbomTest.context) ?? crash "render source"
	["blueprint:kind", "blueprint:attribution", "blueprint:license", "blueprint:license-url"].all(|name| Sbom.read_cyclonedx(rendered.replace_each(name, "removed:declaration")).is_err())
}
expect Sbom.render(reviewed_inventory, { ..reviewed_subject, license_url: "https://example.org/terms" }, SbomTest.context).is_err()
expect Sbom.render_cyclonedx(SbomTest.inventory ?? crash "inventory", { ..SbomTest.subject, license: "LicenseRef-Restricted", license_url: "https://example.org/different-terms" }, SbomTest.context).is_err()
expect {
	text = upstream_syft_spdx.replace_each("\"fileName\":", "\"attributionTexts\":[\"Reviewed native file notice\"],\"fileName\":").replace_each("\"copyrightText\":\"NOASSERTION\"", "\"copyrightText\":\"Copyright 2026 File producer\"").replace_each("\"licenseConcluded\":\"NOASSERTION\"", "\"licenseConcluded\":\"MIT\"")
	graph = Sbom.read(text) ?? crash "native files"
	file = graph.packages_.find_first(|entry| entry.kind == "file" and entry.name == "Cargo.lock") ?? crash "native file"
	file.sha256 == "a4e9ab23a342911a43c815ef752a196788fc09bd8130ffb2f82f5794874d9aca" and file.copyright == "Copyright 2026 File producer" and file.attribution == "Reviewed native file notice" and file.license == "NOASSERTION" and graph.gaps.any(|gap| gap.contains("file concluded/observed license"))
}

# Optional upstream prose is not required to be JSON profile evidence.
expect {
	original = Sbom.render_spdx2(SbomTest.inventory ?? crash "inventory", SbomTest.subject, SbomTest.context) ?? crash "render"
	text = original.replace_each("\"annotations\":[", "\"annotations\":[{\"annotationDate\":\"2026-10-21T00:00:00Z\",\"annotationType\":\"OTHER\",\"annotator\":\"Organization: Supplier\",\"comment\":\"Reviewed upstream prose\"},")
	imported = { ..imported_document, document: text, sha256: Crypto.SHA256.hash(text.to_utf8()).to_hex() }
	text != original and inspect({ ..imported_composition, imported_documents: [imported] }).is_ok()
}
expect {
	imported = { ..imported_document, document: fixture_legacy_cdx, sha256: Crypto.SHA256.hash(fixture_legacy_cdx.to_utf8()).to_hex() }
	inventory = inspect({ ..imported_composition, imported_documents: [imported] }) ?? crash "legacy supplier"
	inventory.coverage.any(|entry| entry.scope == "import:upstream:native-closure" and entry.component.is_empty() and entry.aspect.is_empty() and entry.reason == "Opaque task lacks remaining native closure metadata" and entry.contact == "https://example.org/support")
}

# Direct readers enforce the same metadata consistency as import and check.
expect ["spdx2", "spdx3"].all(
	|format| {
		text = (if format == "spdx2" Sbom.render_spdx2(reviewed_inventory, reviewed_subject, SbomTest.context) else Sbom.render(reviewed_inventory, reviewed_subject, SbomTest.context)) ?? crash "render"
		copyright_key = if format == "spdx2" "copyrightText" else "software_copyrightText"
		identity_key = if format == "spdx2" "referenceLocator" else "software_packageUrl"
		source_key = if format == "spdx2" "sourceInfo" else "software_sourceInfo"
		copyright_field = "${Json.to_str(copyright_key)}:${Json.to_str(reviewed_library.copyright)}"
		identity_field = "${Json.to_str(identity_key)}:${Json.to_str(reviewed_library.package_url)}"
		source_field = "${Json.to_str(source_key)}:${Json.to_str(Json.to_str(reviewed_library.source_refs))}"
		Sbom.read(text).is_ok() and [
			text.replace_each(copyright_field, "${Json.to_str(copyright_key)}:\"Contradictory notice\""),
			text.replace_each(identity_field, "${Json.to_str(identity_key)}:\"pkg:generic/different@1\""),
			text.replace_each(source_field, "${Json.to_str(source_key)}:\"[]\""),
		].all(|broken| broken != text and Sbom.read(broken).is_err())
	},
)
expect {
	text = Sbom.render_cyclonedx(reviewed_inventory, reviewed_subject, SbomTest.context) ?? crash "render"
	broken = text.replace_each("https://example.org/roc-ansi/tree/abcdef0123456789", "https://user:secret@example.org/roc-ansi")
	Sbom.read_cyclonedx(broken).is_err() and Sbom.read(broken).is_err()
}

# Supplier-document availability cannot override reviewed closure assessments.
expect ["unknown", "verified-empty", "complete"].all(
	|status| {
		composition = { ..locked_composition, components: locked_composition.components.map(|entry| if entry.id == "program" { ..entry, kind: "application" } else entry), coverage: [claim("compiler-reviewed", "program", "dependencies", status)] }
		inventory = inspect_locked(composition) ?? crash "reviewed locked compiler coverage"
		three = Sidecar.check(Sbom.render(inventory, SbomTest.subject, SbomTest.context) ?? crash "SPDX3") ?? crash "read SPDX3"
		two = Sidecar.check(Sbom.render_spdx2(inventory, SbomTest.subject, SbomTest.context) ?? crash "SPDX2") ?? crash "read SPDX2"
		text = Sbom.render_cyclonedx(inventory, SbomTest.subject, SbomTest.context) ?? crash "CycloneDX"
		cdx = Sidecar.check(text) ?? crash "read CycloneDX"
		standard = without_blueprint(JsonData.decode_with(text, JsonData.documents) ?? crash "JSON")
		dependencies = (standard.field("dependencies") ?? JsonData.Array([])).array() ?? []
		compositions = (standard.field("compositions") ?? JsonData.Array([])).array() ?? []
		gaps = inventory.coverage.keep_if(|entry| entry.scope.starts_with("sbom:"))
		gaps.len() == 2 and gaps.all(|entry| entry.component.is_empty() and entry.aspect.is_empty() and entry.status == "incomplete")
			and inventory.coverage.any(|entry| entry.component == "program" and entry.aspect == "dependencies" and entry.status == status)
				and dependencies.any(|entry| entry.field("ref") == Ok(JsonData.String("program"))) == (status != "unknown")
					and compositions.len() == 1
						and compositions.any(|entry| entry.field("dependencies") == Ok(JsonData.Array([JsonData.String("program")])) and entry.field("aggregate") == Ok(JsonData.String(if status == "unknown" "unknown" else "complete")))
							and Sidecar.same_graph(three, two) and Sidecar.same_graph(three, cdx)
								and [three, two, cdx].all(|checked| Sidecar.against_inventory(checked, inventory).is_ok())
	},
)
