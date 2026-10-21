import core.Spec
import core.Lock
import core.Sbom

## Consumer fixtures intentionally include a transitive native library, a build
## compiler, a patched proprietary component, and a locked source identity.
SbomTest := [].{
	context : Sbom.Context
	context = { namespace: "https://example.org/sbom/fixture/revision-1", revision: "1", created: "2026-10-21T00:00:00Z", author: "Organization: Fixture producers", generator: "Tool: blueprint-sbom-0.7.0" }
	subject : Sbom.Subject
	subject = { filename: "sample-artifact", version: "1.0.0", target: "x86_64-linux", sha256: Crypto.SHA256.hash("fixture subject\n".to_utf8()).to_hex(), url: "https://example.org/releases/1.0.0/sample-artifact" }
	spec = Spec.empty("fixture")
	lock = Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [], fetched: [], hints: [] }
	composition : Sbom.Composition
	composition = {
		profile: Sbom.profile,
		imported_documents: [],
		components: [
			component("SPDXRef-platform", "platform", "1.0.0"),
			{ ..component("SPDXRef-native", "native-library", "2.0.0"), identity: "pkg:cargo/native-library@2.0.0", sha256: digest },
			component("SPDXRef-compiler", "compiler", "3.0.0"),
			{ ..component("SPDXRef-restricted", "proprietary-code", "4.0.0-patch1"), license: "LicenseRef-Restricted", license_url: "https://example.org/terms/4.0.0", modified: "Vendor revision 4.0.0-patch1; upstream 4.0.0; local fix CVE-fixture; content source identity preserved" },
		],
		relationships: [
			edge("SPDXRef-Subject", "SPDXRef-platform", "CONTAINS"),
			edge("SPDXRef-platform", "SPDXRef-native", "CONTAINS"),
			edge("SPDXRef-compiler", "SPDXRef-Subject", "BUILD_DEPENDENCY_OF"),
			edge("SPDXRef-Subject", "SPDXRef-restricted", "CONTAINS"),
		],
		coverage: [{ scope: "native-closure", status: "incomplete", reason: "Opaque task lacks remaining native closure metadata", contact: "https://example.org/support" }],
		inputs: [],
	}

	inventory : Try(Sbom.Inventory, Str)
	inventory = Sbom.inspect(spec, lock, subject.target, composition)

	output : Try(Str, Str)
	output = Sbom.render(inventory ?? crash "invalid fixture", subject, context)
}

digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

component : Str, Str, Str -> Sbom.Component
component = |id, name, version| { id, name, version, producer: "Organization: Fixture upstream", identity: "https://example.org/source/${name}/${version}", download: "https://example.org/source/${name}/${version}.tar.gz", sha256: "", license: "MIT", license_url: "", modified: "", target: "x86_64-linux", origin: "reviewed" }

edge = |from, to, relation| { from, to, relation, basis: "Reviewed fixture composition declaration" }

inspect = |composition| Sbom.inspect(SbomTest.spec, SbomTest.lock, "x86_64-linux", composition)

expect SbomTest.inventory.is_ok()
expect SbomTest.output.is_ok()
expect inspect({ ..SbomTest.composition, components: [] }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.concat(SbomTest.composition.components) }).is_err()
expect inspect({ ..SbomTest.composition, relationships: [edge("SPDXRef-Subject", "SPDXRef-missing", "CONTAINS")] }).is_err()
expect inspect({ ..SbomTest.composition, relationships: [edge("SPDXRef-native", "SPDXRef-platform", "CONTAINS")] }).is_err()
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
expect Sbom.inspect(tool_spec, SbomTest.lock, "x86_64-linux", { ..SbomTest.composition, inputs: [{ input: "tool:packages#cc", component: "SPDXRef-compiler", reason: "Used only to compile; does not ship" }] }).is_ok()
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
	id: "SPDXRef-upstream",
	url: "https://example.org/sbom/releases/1.0.0/revision-1.spdx.json",
	sha256: Crypto.SHA256.hash((SbomTest.output ?? "").to_utf8()).to_hex(),
	namespace: SbomTest.context.namespace,
	target: SbomTest.subject.target,
	document: SbomTest.output ?? "",
	relation: "CONTAINS",
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
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, id: "SPDXRef-" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, producer: "Not-an-SPDX-supplier" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, license: "Not-A-License" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, license: "MIT AND ( Apache-2.0 OR )" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, license: "MIT OR ( Apache-2.0 WITH LLVM-exception )" }) }).is_ok()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, download: "https://user:secret@example.org/source" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, download: "https://example.org/source?token=secret" }) }).is_err()
expect inspect({ ..SbomTest.composition, components: SbomTest.composition.components.map(|entry| { ..entry, download: "file:///etc/passwd" }) }).is_err()

locked_spec = { ..SbomTest.spec, sources: [{ name: "upstream", provider: NixPackages("github:example/source/stable") }], programs: [{ name: "roc", system: "x86_64-linux", urls: ["https://example.org/roc/3.0.0.tar.gz"], unpack: TarGz, path: "roc/roc" }] }

locked_lock = Lock.{ format: Lock.current_format, intent: Lock.intent_of(locked_spec), sources: [{ name: "upstream", provider: "nix", ref: "github:example/source/stable", rev: "1111111111111111111111111111111111111111", digest: "sha256-Zml4dHVyZQ==" }], fetched: [{ name: "roc", system: "x86_64-linux", urls: ["https://example.org/roc/3.0.0.tar.gz"], sha256: digest, size: 100, obtained: Both }], hints: [] }

source_component = { ..component("SPDXRef-source", "upstream", "1111111111111111111111111111111111111111"), download: "github:example/source/stable", identity: "github:example/source/stable@1111111111111111111111111111111111111111#sha256-Zml4dHVyZQ==", origin: "source:upstream" }

program_component = { ..component("SPDXRef-program", "roc", "3.0.0"), download: "https://example.org/roc/3.0.0.tar.gz", identity: "https://example.org/roc/3.0.0.tar.gz#3.0.0", sha256: digest, origin: "program:roc:x86_64-linux" }

locked_composition = { ..SbomTest.composition, components: [source_component, program_component], relationships: [edge("SPDXRef-Subject", source_component.id, "DEPENDS_ON"), edge(program_component.id, "SPDXRef-Subject", "BUILD_DEPENDENCY_OF")], inputs: [{ input: "source:upstream", component: source_component.id, reason: "Resolved source tree identity; no archive digest inferred" }, { input: "program:roc:x86_64-linux", component: program_component.id, reason: "Authoritative locked download archive" }] }

inspect_locked = |composition| Sbom.inspect(locked_spec, locked_lock, "x86_64-linux", composition)
expect inspect_locked(locked_composition).is_ok()
expect inspect_locked({ ..locked_composition, inputs: [] }).is_err()
expect inspect_locked({ ..locked_composition, components: [{ ..source_component, version: "different-revision" }, program_component] }).is_err()
expect inspect_locked({ ..locked_composition, components: [{ ..source_component, sha256: digest }, program_component] }).is_err()
expect inspect_locked({ ..locked_composition, components: [source_component, { ..program_component, sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }] }).is_err()
expect inspect_locked({ ..locked_composition, components: [source_component, { ..program_component, target: "aarch64-linux" }] }).is_err()
expect {
	inventory = inspect_locked(locked_composition) ?? crash "invalid locked fixture"
	source = inventory.components.find_first(|entry| entry.id == "SPDXRef-source") ?? crash "missing source"
	source.sha256.is_empty() and source.download == "https://github.com/example/source/tree/1111111111111111111111111111111111111111"
}
expect Sbom.json_within_bounds("[[[[[]]]]]")
expect !Sbom.json_within_bounds(Str.join_with(List.repeat("[", 65), "").concat(Str.join_with(List.repeat("]", 65), "")))
expect !Sbom.json_within_bounds("{unclosed")
