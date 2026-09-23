# roc-blueprint

Describe a project's development environments in a small Roc file, and get a
working Nix dev shell from it.

```roc
# Blueprint.roc
app [config] { pf: platform "platform/main.roc" }

config = [
	Name("roc-blueprint"),
	Overlay("github:roc-lang/roc-overlay"),
	Systems([X86_64Linux]),
	Shell("default", [Tools(["rocpkgs.nightly", "zig_0_16", "git", "python3", "zstd", "nixfmt"])]),
	Shell("ci", [Tools(["rocpkgs.nightly", "zig_0_16", "git"])]),
]
```

```sh
blueprint shell        # enter the default shell
blueprint shell ci     # or another one
```

## How it fits together

```
Blueprint.roc ──roc──▶ roc-blueprint platform ──prints──▶ IR (S-expression)
                                                            │
                          blueprint CLI ◀──parses───────────┘
                               │
                               ├─▶ .blueprint/flake.nix
                               ├─▶ Blueprint.lock  (committed)
                               └─▶ nix develop
```

| Part | Path | What it is |
|---|---|---|
| `roc-blueprint` | `platform/` | The platform a `Blueprint.roc` uses. It supplies the setting types, checks each quoted value while compiling (`Tool`, `FlakeRef`, `EnvName`), lowers `config` to the IR and prints it. |
| `roc-blueprint-ir` | `ir/` | The IR types (`Ir`) and an S-expression format (`Sexpr`) with `encoder_for`/`parser_for` support. The platform encodes with it and the CLI parses with it, so both sides share one definition. |
| `blueprint` | `cli/` | A [basic-cli](https://github.com/roc-lang/basic-cli) app that runs `Blueprint.roc`, parses the IR, renders the flake and drives `nix`. |

The repository uses itself: `Blueprint.roc` at the root defines the shells for
working on roc-blueprint.

### Settings

| Setting | Meaning |
|---|---|
| `Name(Str)` | Project name (required, once) |
| `Systems(List(System))` | Nix systems to generate shells for (default: all four) |
| `Overlay(FlakeRef)` | A flake whose `overlays.default` is applied to nixpkgs |
| `Shell(EnvName, List(ShellSetting))` | A dev shell; names must be unique |
| `Tools(List(Tool))` | nixpkgs attribute paths, e.g. `"llvmPackages.bintools"` |

### The IR

`roc Blueprint.roc` prints something like:

```lisp
(
	(name "roc-blueprint")
	(overlays ("github:roc-lang/roc-overlay"))
	(shells ((
		(name "ci")
		(tools (("rocpkgs" "nightly") ("zig_0_16") ("git"))))))
	(systems (X86_64Linux))
	(version 1))
```

Records are `((field value) ...)`, lists are `(a b)`, tags are `Tag` or
`(Tag payload ...)`. The CLI refuses an IR `version` it doesn't know.

## CLI

| Command | |
|---|---|
| `blueprint` / `blueprint gen` | Write `.blueprint/flake.nix`, lock it, sync `Blueprint.lock` |
| `blueprint shell [NAME]` | `gen`, then `nix develop` into the shell (default `default`) |
| `blueprint update` | Update `Blueprint.lock` to the latest inputs |
| `blueprint check` | Type-check and run `Blueprint.roc` to validate it |
| `blueprint ir` | Print the IR |
| `blueprint flake` | Print the generated flake |
| `blueprint version` | Print the version |

`ROC` selects the compiler (default `roc`). `.blueprint/` is generated and
ignored by git; `Blueprint.lock` is committed.

## Development

Needs the Roc nightly in `.roc-version`, Zig 0.16 and Nix.

```sh
zig build                                   # platform/targets/x64musl/libhost.a
roc Blueprint.roc                           # print the IR
roc build cli/main.roc --output=./blueprint
./ci/test.sh                                # everything CI runs
scripts/bundle.sh                           # bundle into dist/ and smoke-test
```

Only `x64musl` is supported. Everything the platform links except
`libhost.a` (the musl C runtime, libc, and compiler-rt) is vendored in
`platform/targets/x64musl/`; see `platform/targets/README.md` for where it
came from and its checksums.

### Releasing

Push a tag like `0.1.0`. `.github/workflows/release.yml` runs the tests,
bundles, and publishes two releases: `0.1.0` with the `roc-blueprint`
platform bundle and a prebuilt `blueprint` binary, and `0.1.0-ir` with the
`roc-blueprint-ir` bundle. They're separate because Roc identifies a package
by its URL minus the version and hash, so two bundles under one tag look like
one package served with two hashes.

`roc bundle` only packs files below the entry point's directory, so the
platform can't carry `../ir` inside its bundle. `scripts/bundle.sh` bundles
`ir` first, then bundles a staged copy of the platform whose `ir:`
dependency points at the ir bundle's URL: localhost for the smoke test, and
the GitHub release for a release.

## Upstream workarounds

These are pinned or worked around for now. Search for `TODO(compile-time-render)`.

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
