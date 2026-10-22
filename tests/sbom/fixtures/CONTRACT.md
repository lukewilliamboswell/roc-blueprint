# SBOM fixture contract

This is the fixture set of Blueprint's SBOM profile, `blueprint-spdx-3.0-v1`,
as a release publishes it: `roc-blueprint-sbom-fixtures-<version>.zip`. The
test suite of the roc-blueprint repository, `scripts/src/SbomTest.roc`,
asserts every case below, and `scripts/test_sbom.roc contract` writes this
file from the same values. The suite fails when a case, a committed file or
this contract drifts from the others.

The standalone tool is the `roc-blueprint-sbom-<hash>.tar.zst` bundle of the
same release, run as `roc run <bundle-url> -- <command>`; `sbom` below stands
for that. It never changes an input and never replaces an output that
exists, so work in a scratch copy of the set. A refusal is printed on
standard error as `SBOM: Invalid("<message>")`, with exit code 1.

## Rendered cases

Each case is one inventory rendered three ways from one subject and
context: `<case>.spdx.json` (SPDX 3.0.1 JSON-LD), `<case>.spdx-2.3.json`
(SPDX 2.3) and `<case>.cdx.json` (CycloneDX 1.7). The three state one package
graph, and `sbom check <case>.spdx.json <case>.spdx-2.3.json <case>.cdx.json`
accepts them. The subject's SHA-256 in each document is that of the bytes
shown.

| Case | Target | Subject | Namespace | Proves |
| --- | --- | --- | --- | --- |
| `verified-import` | `x86_64-linux` | `consumer-artifact` 1.0.0, the bytes `consumer of fixture\n` | `https://example.org/sbom/fixture/imported/revision-1` | A native supplier's SBOM (the `native-linux` document) imported into a consumer and bound to the consumed input it describes, pinned by SHA-256: the supplier's components join the consumer's graph under `upstream-` identifiers, and the import's coverage states that the document digest and the subject's identity matched. |
| `native-linux` | `x86_64-linux` | `sample-artifact` 1.0.0, the bytes `fixture subject\n` | `https://example.org/sbom/fixture/revision-1` | The reference native inventory: a platform that contains a transitive native library with a digest of its own, a compiler that only builds the subject (`dependsOn` with scope `build`; CycloneDX scope `excluded`), patched restricted code that keeps its patch identity and licence terms, and an `incomplete` coverage record for the rest of the native closure. |
| `native-arm64` | `aarch64-linux` | `sample-artifact` 1.0.0, the bytes `fixture subject\n` | `https://example.org/sbom/fixture/arm64/revision-1` | The same composition for `aarch64-linux`: the subject and every component carry that target, and nothing from the `x86_64-linux` case is admitted. |
| `source-bundle` | `source` | `sample-source-bundle` 1.0.0, the bytes `fixture source bundle\n` | `https://example.org/sbom/fixture/source/revision-1` | An architecture-independent subject, target `source`, whose components state no target: what a source archive's own SBOM, such as a Roc package bundle's, looks like. It is the supplier document of the `native-source-import` case. |
| `native-source-import` | `x86_64-linux` | `consumer-artifact` 1.0.0, the bytes `consumer of fixture\n` | `https://example.org/sbom/fixture/source-import/revision-1` | The `source-bundle` document imported into an `x86_64-linux` consumer and bound to the file pin `source:dep`: every component keeps target `source`, the archive's digest and version bind exactly, and the build-scoped dependency ships nothing. Its inputs are under `source-import/`. |
| `verified-empty` | `x86_64-linux` | `sample-artifact` 1.0.0, the bytes `fixture subject\n` | `https://example.org/sbom/fixture/empty/revision-1` | A reviewed subject with no third-party components, stated as `verified-empty` coverage: an asserted fact, distinct from not knowing. |
| `unknown-closure` | `x86_64-linux` | `sample-artifact` 1.0.0, the bytes `fixture subject\n` | `https://example.org/sbom/fixture/unknown/revision-1` | A subject whose closure is not known: no components, and an `incomplete` coverage record with its reason and contact. A consumer must not read it as empty. |

## Native inputs: `input/`

The standalone tool's inputs for the `native-linux` case: the evaluated
`Spec` and `Lock` in their wire formats, `composition.json`, `subject.json`,
`context.json` and the artifact `sample-artifact`. `inventory.json` is what
`inspect` writes for `x86_64-linux`, byte for byte, and `bind` reproduces
the committed renderings:

```sh
sbom inspect input/Spec input/Lock input/composition.json x86_64-linux out.json
cmp out.json input/inventory.json
sbom bind input/inventory.json input/subject.json input/context.json input/sample-artifact
cmp input/sample-artifact.spdx.json native-linux.spdx.json
cmp input/sample-artifact.cdx.json native-linux.cdx.json
sbom bind input/inventory.json input/subject.json input/context.json input/sample-artifact out.spdx-2.3.json --spdx-2.3
cmp out.spdx-2.3.json native-linux.spdx-2.3.json
sbom check --artifacts input --inventory input/inventory.json native-linux.spdx.json native-linux.spdx-2.3.json native-linux.cdx.json
```

## Source supplier import: `source-import/`

A consumer whose `Spec` holds one `source_files` entry, `dep`, pinned by the
SHA-256 of a supplier's archive; whose `Lock` records that pin as a `file`
provider source; and whose `composition.json` declares a `source:dep`
component at target `source`, with the supplier's own SBOM (the
`source-bundle` document, for the archive `dep-abc.tar.zst` 1.2.0) imported
at target `source` and bound to that component. The dependency is
build-scoped: the consumer's compiler builds the archive for the consumer's
target, so the archive keeps its `source` identity in every consumer and is
never relabelled as native code. `expected.json` states this section for
automation: the inputs, each accepted target with its inventory, what `bind`
takes and reproduces, and each refusal.

### Accepted

`inspect` writes each inventory byte for byte, and in every one each
component keeps target `source`:

| Consumer target | Inventory |
| --- | --- |
| `source` | `source-import/inventory-source.json` |
| `x86_64-linux` | `source-import/inventory-x86_64-linux.json` |
| `aarch64-linux` | `source-import/inventory-aarch64-linux.json` |

```sh
sbom inspect source-import/Spec source-import/Lock source-import/composition.json x86_64-linux out.json
cmp out.json source-import/inventory-x86_64-linux.json
```

`bind` of that inventory to `consumer-artifact` with `subject.json` and
`context.json` reproduces the `native-source-import` renderings:

```sh
sbom bind source-import/inventory-x86_64-linux.json source-import/subject.json source-import/context.json source-import/consumer-artifact
cmp source-import/consumer-artifact.spdx.json native-source-import.spdx.json
cmp source-import/consumer-artifact.cdx.json native-source-import.cdx.json
```

Build-only versus contained: in those renderings `dep` is excluded from what
ships. The subject reaches it through `dependsOn` with scope `build` alone,
no `contains` relationship leads from the subject to it, and its CycloneDX
scope is `excluded` while no component is `required`.

### Refused

Each composition differs from `composition.json` in one value. `inspect` of
it for the target shown exits 1 with the message, and writes nothing:

| Composition | Target | Refusal | Proves |
| --- | --- | --- | --- |
| `source-import/tamper-document-digest.json` | `x86_64-linux` | `SBOM: Invalid("imported SBOM content digest mismatch")` | The supplier document must hash to the digest the import states; a document with other bytes is not read. |
| `source-import/tamper-subject-digest.json` | `x86_64-linux` | `SBOM: Invalid("import subject filename/version/SHA256 mismatch")` | The supplier's described artifact must be the bytes the consumer pinned: another SHA-256 does not bind. |
| `source-import/tamper-subject-version.json` | `x86_64-linux` | `SBOM: Invalid("import subject filename/version/SHA256 mismatch")` | Another version of the same bytes does not bind either. |
| `source-import/tamper-import-native.json` | `x86_64-linux` | `SBOM: Invalid("imported document subject target mismatch")` | A `source` document cannot be imported as native code: the import's stated target must be the one the document states for its subject. |
| `source-import/tamper-component-native.json` | `x86_64-linux` | `SBOM: Invalid("imported subject conflicts with authoritative component artifact")` | The consumer's component for a `source` supplier cannot claim a native target: it conflicts with the bound artifact's identity. |
| `source-import/tamper-import-aarch64.json` | `x86_64-linux` | `SBOM: Invalid("import target differs from subject")` | A native target that is not the consumer's is refused, as for any native supplier; only `source` crosses architectures. |

## Upstream documents: `upstream/`

What Syft and Trivy wrote for one Cargo project, in CycloneDX and SPDX, as
`upstream/README.md` describes. Each imports with exactly the gaps the suite
states for it; what the profile cannot carry is counted, never dropped.

## Schemas

The set holds no schema. The JSON schemas the validators are held to are
vendored in the repository's `tests/sbom/schema/`, each pinned by SHA-256:

| Schema | SHA-256 |
| --- | --- |
| `spdx-3.0.1.schema.json` | `582c64e809d5b3ef9bd0c4de13a32391b47b0284a3e8d199569fb96f649234b1` |
| `spdx-2.3.schema.json` | `4126dc29f15e92feec92e9622f4939131ad58b125d6f578aa93e980a6e6f3212` |
| `cyclonedx-1.7/bom-1.7.schema.json` | `73308edec3ab2d38bfffd993e96a042b594314143b6971a6e9ed98bbb6bd76ce` |
