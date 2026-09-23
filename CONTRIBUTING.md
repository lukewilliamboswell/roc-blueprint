# Contributing to roc-blueprint

## Layout

```
blueprint-ir-platform/   the roc-blueprint platform that Blueprint.roc apps use
  *.roc                  setting types, checked values, lowering to the IR
  host/, build.zig       Zig host, built into targets/x64musl/libhost.a
  targets/               linker inputs; all but libhost.a are vendored (see its README)
  ir-release             the released IR bundle URL a platform release uses
blueprint-ir-package/    roc-blueprint-ir: the IR types, Value, and the S-expression format
  fuzz/                  roc-fuzz targets: ir-parse, ir-round-trip
blueprint-cli/           the blueprint CLI (basic-cli + weaver)
  Backend.roc            the backend interface: render files, argv for lock/shell/run
  NixBackend.roc         the Nix backend (flake.nix)
  tests/                 IR fixtures and golden flakes
examples/Blueprint.roc   uses every setting; CI runs blueprint against it
examples/extensions/     Custom blocks; CI checks blueprint refuses them clearly
scripts/                 test.sh (all of CI), bundle.sh, fuzz.sh
flake.nix                builds blueprint with the pinned Roc; user and contributor shells
```

The platform encodes the IR and the CLI parses it, both with
`blueprint-ir-package`, so the two always agree on the format.

## Setup

```sh
nix develop .#contributor
```

gives Roc (the nightly in `.roc-version`, from
[roc-overlay](https://github.com/roc-lang/roc-overlay)), Zig, `blueprint`,
python3, zstd and git. Nix itself is also needed for `blueprint`.

## Building and testing

```sh
(cd blueprint-ir-platform && zig build)      # blueprint-ir-platform/targets/x64musl/libhost.a
roc test blueprint-ir-package/main.roc      # IR round trips and format tests
roc test blueprint-cli/main.roc             # includes the golden flake test
roc build blueprint-cli/main.roc --output=./blueprint
(cd examples && ../blueprint run --help)    # try the CLI
./scripts/test.sh                           # everything CI runs
scripts/fuzz.sh 300                         # fuzz each target for 5 minutes
```

CI runs `scripts/test.sh`, which also builds the flake, bundles the platform
twice (see below), and runs each fuzz target for 30 seconds.

## The IR

`roc Blueprint.roc` prints the IR as an S-expression: records are
`((field value) ...)`, lists `(a b)`, tags `Tag` or `(Tag payload ...)`, and
`;` starts a comment. `blueprint-ir-package/Ir.roc` documents every field.

In outline:

- `format` — `(major minor)`; see the compatibility rules below.
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

`Value` is `Str`, `Int`, `Bool`, `List` or `Attrs`. Its codec is hand-written
(deriving it hangs the compiler), so the IR only encodes to S-expressions.
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
`examples/Blueprint.roc` against it. CI does both, so a platform change that
needs an unreleased ir fails before a release.

The two packages need separate tags: Roc identifies a package by its URL
minus the version and hash, so two bundles under one tag look like one
package served with two hashes.

If you change the basic-cli or weaver version in `blueprint-cli/main.roc`, update
`rocPackages` in `flake.nix` to match.

## Upstream workarounds

These are pinned or worked around until upstream fixes land. Search the code
for `TODO(compile-time-render)`.

- **Pinned Roc and basic-cli.** `.roc-version` and the basic-cli URL in
  `blueprint-cli/main.roc` are the newest pair that works together; newer
  nightlies crash the compiler on the CLI until basic-cli catches up.
- **The IR is built when the app runs, not at compile time.** It should be a
  top-level constant, so that `roc check Blueprint.roc` reports whole-config
  errors like duplicate shells, but `roc bundle` crashes on a constant that
  depends on the app's `config` (fixed on Roc main, not yet in a nightly we
  can use). For now `blueprint check` runs the app. Checks on individual
  values are still done while compiling.
- **`roc bundle --output-dir` must be on the same filesystem as the working
  directory.** Otherwise the bundler fails with `CrossDevice`.
- **Error unions in `blueprint-ir-package/Sexpr.roc` use a named extension
  (`..others`).** The pinned nightly needs them open, and newer compilers warn
  about a bare `..`; the named form keeps both quiet.
