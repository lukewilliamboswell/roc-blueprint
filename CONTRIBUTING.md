# Contributing to roc-blueprint

## Layout

```
blueprint-ir-platform/   the roc-blueprint platform that Blueprint.roc apps use
  *.roc                  setting types, checked values, lowering to the IR
  host/, build.zig       Zig host, built into targets/{x64musl,arm64mac}/libhost.a
  targets/               linker inputs; all but libhost.a are vendored (see its README)
  ir-release             the released IR bundle URL a platform release uses
blueprint-ir-package/    roc-blueprint-ir: the IR types, Value, and the S-expression format
  fuzz/                  roc-fuzz targets: ir-parse, ir-round-trip
blueprint-cli/           the blueprint CLI (basic-cli + weaver)
  Backend.roc            the backend interface: render files, argv for lock/shell/run
  NixBackend.roc         the Nix backend (flake.nix)
  tests/                 IR fixtures and golden flakes
examples/all-settings/   uses every setting; CI runs blueprint against it
examples/extensions/     Custom blocks; CI checks blueprint refuses them clearly
scripts/                 prepare-basic-cli.sh, test.sh, bundle.sh, fuzz.sh
flake.nix                builds blueprint with the pinned Roc; user and contributor shells
```

The platform encodes the IR and the CLI parses it, both with
`blueprint-ir-package`, so the two always agree on the format.

## Setup

Full development and CI require x86_64 Linux with Nix and flakes enabled.

```sh
nix develop .#contributor
```

gives Roc (the nightly in `.roc-version`, from
[roc-overlay](https://github.com/roc-lang/roc-overlay)), Zig, `blueprint`,
python3, zstd and git. Nix itself is also needed for `blueprint`.

Run `scripts/prepare-basic-cli.sh` before compiling the CLI directly. It builds
the source-pinned basic-cli platform with Nix and creates the ignored
`.basic-cli` symlink used by `blueprint-cli/main.roc`. `scripts/test.sh` also
runs this setup. The Nix blueprint package includes the platform automatically.

## Building and testing

```sh
scripts/prepare-basic-cli.sh                # basic-cli source + Rust host
(cd blueprint-ir-platform && zig build)      # targets/{x64musl,arm64mac}/libhost.a
roc test blueprint-ir-package/main.roc      # IR round trips and format tests
roc test blueprint-cli/main.roc             # includes the golden flake test
roc build blueprint-cli/main.roc --output=./blueprint
(cd examples/all-settings && ../../blueprint run --help) # try the CLI
./scripts/test.sh                           # everything CI runs
scripts/fuzz.sh 300                         # fuzz each target for 5 minutes
```

CI runs `scripts/test.sh`, which also builds the flake, bundles the platform
twice (see below), and runs each fuzz target for 30 seconds.

## Nightly updates

`.github/workflows/update-roc-nightly.yml` checks daily at 13:10 UTC, or on
manual dispatch, using the SHA-pinned reusable workflow from
[roc-automation](https://github.com/lukewilliamboswell/roc-automation).
`.roc-version` remains the compiler pin for CI, releases and the Nix flake;
the shared updater supports this file without `compiler_roots` configuration.

`.github/roc-nightly.json` selects `ci.yml`, whose `nightly_validation` dispatch
runs all of `scripts/test.sh`: tests, CLI execution, Nix builds, both platform
bundle smoke tests and fuzzing. The tag-triggered release workflows are not
dispatched and validation does not publish. A separate Nightly configuration
workflow checks the consumer configuration on pull requests.

The shared controller creates a signed pin-only PR and merges it only after
validation and repository rules pass. The required check for this CI is `test`.
The active main-branch ruleset requires that check from GitHub Actions, strict
up-to-date checks, and pull requests. Keep its required check names aligned
with the validation workflow when changing CI. Once the workflows are on
`main`, manually dispatch the updater and inspect the candidate's validation
results.

The Nix overlay is independently locked. A nightly absent from the locked
overlay will fail Nix validation and cannot auto-merge. Update the `roc-overlay`
input with `nix flake update roc-overlay` once upstream lists that nightly,
then retry the updater. Do not skip the Nix check to accept a compiler bump.

The September 23 nightly (`nightly-2026-09-23-c7852fd`) uses basic-cli
[PR #499](https://github.com/roc-lang/basic-cli/pull/499), pinned to commit
`473caa2cc4f3fe9ce4e4682158bb80ebc2e19169` in `flake.nix` and `flake.lock`.
The released 0.23.0-rc1 platform stalls with this compiler; the pinned source
passes the CLI and imported platform tests. Nix builds its Rust host for
x64musl on Linux and arm64mac on macOS using the upstream Rust toolchain version and locked Cargo dependencies.
The Rust host is reused across Roc nightly updates.

The complete suite requires x86_64 Linux, Zig 0.16 and a running Nix daemon. To test the CLI alone on macOS,
check out that exact basic-cli commit, run `python3 scripts/build.py` there,
and link its `platform` directory at `.basic-cli` in this repository. Then
run the CLI unit tests and build with the September 23 Roc binary. The native
CLI can run on macOS, but executing a Blueprint.roc still requires the
blueprint platform's Linux target.

## The IR

`roc Blueprint.roc` prints the IR as an S-expression: records are
`((field value) ...)`, lists `(a b)`, tags `Tag` or `(Tag payload ...)`, and
`;` starts a comment. `blueprint-ir-package/Ir.roc` documents every field.

In outline:

- `format` — `((major 1) (minor 0))`; see the compatibility rules below.
- `name`, `systems` (strings such as `"x86_64-linux"`).
- `inputs` — `{ name, url, kind }`, where kind is `Packages` (a package set),
  `Overlay` or `Flake`. The IR implies no inputs; the platform always writes an
  explicit `nixpkgs`.
- `shells` — `{ name, packages }`, each package `{ source, path }` where
  `source` names a `Packages` input.
- `tasks` — `{ name, shell, run }`.
- `raw` — `{ backend, target, value }`, passed through to one backend.
- `extensions` — `{ kind, name, value }`, blocks a backend may understand.
- `requires` — features the config uses beyond the core (`"raw"`,
  `"extensions"`), so an older `blueprint` can say what's missing.

`Value` is `Str`, `Int`, `Bool`, `List` or `Attrs`. Its S-expression encoder
and parser are hand-written to avoid recursive-codec derivation problems.
`requires` and `packages` are reserved words in Roc; the Roc fields are
`requires_` and `packages_`, and `Sexpr` drops a trailing `_` on the wire.

### Compatibility

- A consumer accepts any IR with the same `major`, whatever the `minor`.
- **Minor** (compatible): a new optional top-level field (missing fields
  default to empty, unknown ones are ignored), or a new `requires` feature.
- **Major** (breaking): anything else, such as a new required field, a new
  field inside a nested record, or a new `kind` tag.

### Backends

`blueprint-cli/Backend.roc` is the interface: a backend is pure. It renders the
IR into files and gives the argv for locking, updating, entering a shell and
running a task; `main.roc` does the effects. `NixBackend.roc` is the only
backend. It:

- imports every `Packages` input once per system and applies every overlay to
  each;
- renders `raw` entries for backend `"nix"` (targets `shell:<name>` and
  `flake`) as data, and ignores raw entries for other backends;
- refuses any `extensions` (it supports none yet) and advertises the
  `"raw"` feature.

A new feature usually means: a setting in the platform (`Config.roc`,
`Lower.roc`), then either an `extensions` kind or a new optional IR field
(a minor bump), then support in a backend. Prototyping it as `Raw` or `Custom`
first needs no IR change at all.

## Releasing

roc-blueprint and roc-blueprint-ir have independent release cycles.

- **roc-blueprint-ir:** push a tag like `ir-X.Y.Z`. `release-ir.yml` tests
  and bundles `blueprint-ir-package/` and publishes release `ir-X.Y.Z` with the bundle.
- **roc-blueprint:** put the ir bundle URL the platform should use in
  `blueprint-ir-platform/ir-release`, then push a tag like `X.Y.Z`. `release.yml` runs the
  tests and publishes release `X.Y.Z` with the platform bundle and a prebuilt
  `blueprint` binary.

A tag with a `-` in it (e.g. `X.Y.Z-rc1`) is published as a pre-release.

During development the platform uses `ir: "../blueprint-ir-package/main.roc"`. `roc bundle`
only packs files below the entry point's directory, so `scripts/bundle.sh
platform <ir-url>` bundles a staged copy whose `ir:` is the given URL. With
no URL it bundles the local `blueprint-ir-package/` and serves it from localhost. Either way
it then serves the platform bundle from localhost and runs
`examples/all-settings/Blueprint.roc` against it. CI does both, so a platform change that
needs an unreleased ir fails before a release.

The two packages need separate tags: Roc identifies a package by its URL
minus the version and hash, so two bundles under one tag look like one
package served with two hashes.

Update the basic-cli source revision in `flake.nix` and refresh its lock input
when adopting a newer commit. When switching back to a released platform,
restore its URL in `blueprint-cli/main.roc` and add its archive to `rocPackages`.
If you change the weaver URL, update `rocPackages` in `flake.nix` to match.

## Upstream workarounds

These are pinned or worked around until upstream fixes land. Search the code
for `TODO(compile-time-render)`.

- **Pinned Roc and basic-cli.** `.roc-version` selects the compiler and the
  `basic-cli-src` flake input selects compatible platform source. Replace this
  temporary source dependency when a compatible basic-cli release is available.
- **The IR is built when the app runs, not at compile time.** It should be a
  top-level constant, so that `roc check Blueprint.roc` reports whole-config
  errors like duplicate shells. Runtime rendering was introduced after older
  compilers crashed while bundling a constant that depends on the app's
  `config`. Revalidate bundle behavior before removing this workaround. For
  now `blueprint check` runs the app; individual values are checked at compile time.
- **`roc bundle --output-dir` must be on the same filesystem as the working
  directory.** Otherwise the bundler fails with `CrossDevice`.
- **Error unions in `blueprint-ir-package/Sexpr.roc` use a named extension
  (`..others`).** These preserve open error types without the compiler
  warning about a redundant bare `..`.
