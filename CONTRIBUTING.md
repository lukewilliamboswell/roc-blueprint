# Contributing to roc-blueprint

## Layout

```
blueprint-ir-platform/   the roc-blueprint platform that Blueprint.roc apps use
  *.roc                  setting types, checked values, lowering to the IR
  host/, build.zig       Zig host, built into targets/x64musl/libhost.a
  targets/               linker inputs; all but libhost.a are vendored (see its README)
  ir-release             the released IR bundle URL a platform release uses
blueprint-ir-package/    roc-blueprint-ir: the IR types and S-expression format
  fuzz/                  roc-fuzz targets: ir-parse, ir-round-trip
blueprint-cli/           the blueprint CLI (basic-cli + weaver)
  Flake.roc              renders the IR as a Nix flake
  tests/                 golden files
examples/Blueprint.roc   uses every setting; CI runs blueprint against it
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

`roc Blueprint.roc` prints the IR, e.g.

```lisp
(
	(name "roc-blueprint")
	(overlays ("github:roc-lang/roc-overlay"))
	(shells ((
		(name "ci")
		(tools (("rocpkgs" "nightly") ("zig") ("git"))))))
	(systems (X86_64Linux))
	(tasks ((
		(name "test")
		(run ("./scripts/test.sh"))
		(shell "default"))))
	(version N))
```

(`N` is `Ir.current_version`.)

Records are `((field value) ...)`, lists are `(a b)`, tags are `Tag` or
`(Tag payload ...)`, and `;` starts a comment. Any change to the IR's shape
must bump `Ir.current_version`; the CLI refuses versions it doesn't know.

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
