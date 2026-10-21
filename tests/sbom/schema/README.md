# Vendored SBOM specification schemas

These files are copied byte for byte from their publishers and are not
modified. `.gitattributes` keeps Git from changing their line endings, and
`scripts/src/SbomTest.roc` pins each schema Blueprint's validators are held to
by SHA-256. Blueprint's own code in `blueprint-core/Spdx3.roc`,
`blueprint-core/Spdx2.roc` and `blueprint-core/CycloneDx.roc` implements these
specifications; it is not a copy of them.

| File | Material, version | Retrieved from | License |
| --- | --- | --- | --- |
| `spdx-3.0.1.schema.json` | SPDX 3.0.1 JSON schema, from the SPDX 3.0.1 model | https://spdx.org/schema/3.0.1/spdx-json-schema.json (model source: https://github.com/spdx/spdx-3-model, tag `3.0.1`) | Community Specification License 1.0, [`licenses/spdx-3-model-3.0.1-License.md`](licenses/spdx-3-model-3.0.1-License.md) |
| `spdx-2.3.schema.json` | SPDX 2.3.1 JSON schema | https://github.com/spdx/spdx-spec, tag `v2.3.1`, `schemas/spdx-schema.json` | Creative Commons Attribution 3.0 Unported, [`licenses/spdx-spec-v2.3.1-LICENSE`](licenses/spdx-spec-v2.3.1-LICENSE) |
| `cyclonedx-1.7/bom-1.7.schema.json` | CycloneDX 1.7 JSON schema | https://github.com/CycloneDX/specification, tag `1.7.2` (commit `349314a9d7671d7d2ca5b711a725f49a73979da6`), `schema/` | Apache License 2.0, [`licenses/cyclonedx-specification-1.7.2-LICENSE`](licenses/cyclonedx-specification-1.7.2-LICENSE) |
| `cyclonedx-1.7/spdx.schema.json` | SPDX license identifier schema referenced by the CycloneDX 1.7 schema | same as above | Apache License 2.0, as above |
| `cyclonedx-1.7/jsf-0.82.schema.json` | JSON Signature Format 0.82 schema referenced by the CycloneDX 1.7 schema | same as above | Apache License 2.0, as above |
| `cyclonedx-1.7/cryptography-defs.schema.json` | Cryptography definitions schema referenced by the CycloneDX 1.7 schema | same as above | Apache License 2.0, as above |

SHA-256 of each file as published:

| File | SHA-256 |
| --- | --- |
| `spdx-3.0.1.schema.json` | `582c64e809d5b3ef9bd0c4de13a32391b47b0284a3e8d199569fb96f649234b1` |
| `spdx-2.3.schema.json` | `4126dc29f15e92feec92e9622f4939131ad58b125d6f578aa93e980a6e6f3212` |
| `cyclonedx-1.7/bom-1.7.schema.json` | `73308edec3ab2d38bfffd993e96a042b594314143b6971a6e9ed98bbb6bd76ce` |
| `cyclonedx-1.7/spdx.schema.json` | `4b345e2329f209f34e960ae2a8e7cb46a166907e6a45e94978565925dc47b359` |
| `cyclonedx-1.7/jsf-0.82.schema.json` | `8bae002c25e723db7ee1f26afde680ae1a2b1a8f6b4b4b0fd65dc3becb090aae` |
| `cyclonedx-1.7/cryptography-defs.schema.json` | `027b059a729a06d591bac79a584ef04f83fc32d91a826fdba6ad3c98a10e5b44` |

## Attribution

- SPDX 3.0.1 JSON schema: "SPDX Specification 3.0.1, JSON schema",
  © the SPDX project contributors, a project of the Linux Foundation,
  retrieved from https://spdx.org/schema/3.0.1/spdx-json-schema.json under the
  Community Specification License 1.0.
- SPDX 2.3.1 JSON schema: "SPDX Specification 2.3.1, JSON schema",
  © the SPDX project contributors, retrieved from
  https://github.com/spdx/spdx-spec (tag `v2.3.1`) under CC BY 3.0.
- CycloneDX 1.7 schemas: "CycloneDX Specification is Copyright (c) OWASP
  Foundation", retrieved from https://github.com/CycloneDX/specification (tag `1.7.2`)
  under the Apache License 2.0.

The license texts in `licenses/` are copied from the same repositories at the
same tags. These files are test inputs in the source repository; Blueprint's
release bundles and binaries do not include them.
