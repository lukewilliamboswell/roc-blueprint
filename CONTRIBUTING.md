# Contributing to roc-blueprint

## Layout

| Path | What |
|---|---|
| `platform/` | **roc-blueprint**, the platform a `Blueprint.roc` uses: the setting types and checked values (`Config`, `Tool`, `FlakeRef`, `EnvName`, `TaskName`), lowering to the IR (`Lower`), and `main.roc`. |
| `platform/host/`, `platform/build.zig` | The platform's Zig host, built into `platform/targets/x64musl/libhost.a`. |
| `platform/targets/` | Linker inputs. Everything except `libhost.a` is vendored; see `platform/targets/README.md` for provenance and checksums. |
| `platform/ir-release` | The released roc-blueprint-ir bundle URL a platform release depends on. |
| `ir/` | **roc-blueprint-ir**: the IR types (`Ir`) and the S-expression format (`Sexpr`), with `encoder_for`/`parser_for` support. Shared by the platform (encode) and the CLI (parse). |
| `cli/` | **blueprint**, the CLI: a [basic-cli](https://github.com/roc-lang/basic-cli) app using [weaver](https://github.com/lukewilliamboswell/weaver) for arguments. `Flake.roc` renders the IR as a flake; `cli/tests/` has its golden file. |
| `examples/Blueprint.roc` | An example using every setting; CI runs `blueprint` against it. |
| `fuzz/` | [roc-fuzz](https://github.com/lukewilliamboswell/roc-fuzz) targets for the IR: `ir-parse` (arbitrary text into `Ir.parse`) and `ir-round-trip` (generated IR through `to_str` and back). |
| `scripts/` | `test.sh` (everything CI runs), `bundle.sh`, `fuzz.sh`. |
| `flake.nix` | Builds `blueprint` with the pinned Roc; dev shells for users and contributors. |

## Setup

```sh
nix develop .#contributor
```

gives Roc (the nightly in `.roc-version`, from
[roc-overlay](https://github.com/roc-lang/roc-overlay)), Zig 0.16, `blueprint`,
python3, zstd and git. Nix itself is also needed for `blueprint`.

## Building and testing

```sh
(cd platform && zig build)                  # platform/targets/x64musl/libhost.a
roc test ir/main.roc                        # IR round trips and format tests
roc test cli/main.roc                       # includes the golden flake test
roc build cli/main.roc --output=./blueprint
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
		(tools (("rocpkgs" "nightly") ("zig_0_16") ("git"))))))
	(systems (X86_64Linux))
	(tasks ((
		(name "test")
		(run ("./scripts/test.sh"))
		(shell "default"))))
	(version 2))
```

Records are `((field value) ...)`, lists are `(a b)`, tags are `Tag` or
`(Tag payload ...)`, and `;` starts a comment. Any change to the IR's shape
must bump `Ir.current_version`; the CLI refuses versions it doesn't know.

## Releasing

roc-blueprint and roc-blueprint-ir have independent release cycles.

- **roc-blueprint-ir:** push a tag like `ir-0.1.0`. `release-ir.yml` tests
  and bundles `ir/` and publishes release `ir-0.1.0` with the bundle.
- **roc-blueprint:** put the ir bundle URL the platform should use in
  `platform/ir-release`, then push a tag like `0.1.0`. `release.yml` runs the
  tests and publishes release `0.1.0` with the platform bundle and a prebuilt
  `blueprint` binary.

A tag with a `-` in it (e.g. `0.1.0-rc1`) is published as a pre-release.

During development the platform uses `ir: "../ir/main.roc"`. `roc bundle`
only packs files below the entry point's directory, so `scripts/bundle.sh
platform <ir-url>` bundles a staged copy whose `ir:` is the given URL. With
no URL it bundles the local `ir/` and serves it from localhost. Either way
it then serves the platform bundle from localhost and runs
`examples/Blueprint.roc` against it. CI does both, so a platform change that
needs an unreleased ir fails before a release.

The two packages need separate tags: Roc identifies a package by its URL
minus the version and hash, so two bundles under one tag look like one
package served with two hashes.

If you change the basic-cli or weaver version in `cli/main.roc`, update
`rocPackages` in `flake.nix` to match.

## Upstream workarounds

These are pinned or worked around for now. Search for
`TODO(compile-time-render)`.

- **Roc `nightly-2026-09-19-d025939`, basic-cli `0.23.0-rc1`.** On
  `nightly-2026-09-22` the compiler segfaults while checking the CLI with
  basic-cli 0.23.0-rc1. The basic-cli changes for newer compilers are in
  roc-lang/basic-cli#495.
- **The IR is built when the app runs, not at compile time.** It should be a
  top-level constant, so that `roc check Blueprint.roc` reports whole-config
  errors like duplicate shells. `roc bundle` crashes on a constant that
  depends on the app's `config` in every nightly up to 2026-09-22 (fixed on
  roc main at `e87f3eb`). For now `blueprint check` runs the app. Checks on
  individual values are still done while compiling.
- **`roc bundle --output-dir` must be on the same filesystem as the working
  directory.** Otherwise the bundler fails with `CrossDevice`.
- **Error unions in `ir/Sexpr.roc` use a named extension (`..others`).**
  nightly-2026-09-19 needs them open, and newer compilers warn about a bare
  `..`, so the named form keeps both quiet.
