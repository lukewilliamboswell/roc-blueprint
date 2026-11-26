# Reviewed upstream evidence

`basic-cli-Cargo.lock`, `basic-cli-Cargo.toml` and
`basic-cli-rust-toolchain.toml` are the files at basic-cli tag 0.28.1,
commit `4bc39663b90e5117e3fd5e4fbb740e7138df5965`.
`../basic-cli-cargo.json` preserves all 109 package instances and 203
resolution edges. Unclassified feature/target/build edges use the SPDX 3.0.1
relationship `other`; they do not assert runtime dependency or containment.
Known `cc`, `pkg-config` and `vcpkg` edges of libsqlite3-sys are `dependsOn`
with lifecycle scope `build` (SPDX 2.3 `BUILD_DEPENDENCY_OF`).

`linker-runtime-sources.json` and `msvc-runtime-UPSTREAM.json` are from
roc-platform-template-zig commit
`99649586217e36d251b6ebf7ee0a5d1593b19c20`, the exact producer selected by
`link-inputs.lock.json`. They establish musl 1.2.5, Zig 0.17.0, and Roc MSVC
startup source revision `7d256b954603e1170ee0d6df229c795aba6dc70d`.

SQLite 3.49.1 is declared by `sqlite3/sqlite3.h` in libsqlite3-sys 0.33.0:
`https://static.crates.io/crates/libsqlite3-sys/libsqlite3-sys-0.33.0.crate`,
SHA-256 `947e6816f7825b2b45027c2c32e7085da9934defa535de4a6a46b10a4d5257fa`,
matching the committed upstream Cargo.lock. Its Cargo.toml establishes the
build-only crate edges. The pinned basic-cli Cargo.toml enables `bundled`.

The product compiler nightly `nightly-2026-11-25-d5a4f1e` identifies Roc commit
`d5a4f1e9e128359a8d4d3caea40fe3ba7e6eb1e2`, recorded by the
[official nightly release](https://github.com/roc-lang/nightlies/releases/tag/nightly-2026-11-25-d5a4f1e)
and [upstream commit](https://github.com/roc-lang/roc/commit/d5a4f1e9e128359a8d4d3caea40fe3ba7e6eb1e2).
Bootstrap archive digests and sizes come from that release's asset metadata and
are checked against downloaded bytes before embedding. This does not establish
a complete compiler archive dependency or license inventory. The generation
recipe retains that uncertainty explicitly. The linker-input archive supplies the runtime inventories above. The
sandbox runner retains its separate pins.

Changes to the compiler, CLI imports, or linker-input producer fail closed
until this metadata and the generation recipe are reviewed together.

SPDX license identifiers and exceptions come from license-list-data v3.26.0.
The SPDX 3.0.1 JSON schema in tests/sbom/schema is the one published at
https://spdx.org/schema/3.0.1/spdx-json-schema.json, and the SPDX 2.3.1 schema
comes from the SPDX specification v2.3.1 tag. Both are kept byte for byte, and
`scripts/src/SbomTest.roc` pins their SHA-256 and holds the Roc validators to
their classes, members and enumerations.

Unknown Cargo licenses, target feature selection, optimized link elimination,
and opaque compiler/native closures remain explicit gaps. Resolution candidates
are preserved so consumers can investigate them without treating them as
proven shipped components.
