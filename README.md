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
	Task("test", [Run(["./ci/test.sh"])]),
	Task("bundle", [Run(["scripts/bundle.sh", "platform"])]),
]
```

```sh
blueprint shell        # enter the default shell
blueprint shell ci     # or another one
blueprint run test     # run a task in its shell
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
| `Task(TaskName, List(TaskSetting))` | A named command; names must be unique |
| `Run(List(Str))` | The task's command and arguments (required, once) |
| `In(EnvName)` | The shell the task runs in (optional, default `"default"`) |

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
	(tasks ((
		(name "test")
		(run ("./ci/test.sh"))
		(shell "default"))))
	(version 2))
```

Records are `((field value) ...)`, lists are `(a b)`, tags are `Tag` or
`(Tag payload ...)`. The CLI refuses an IR `version` it doesn't know.

## CLI

| Command | |
|---|---|
| `blueprint` / `blueprint gen` | Write `.blueprint/flake.nix`, lock it, sync `Blueprint.lock` |
| `blueprint shell [NAME]` | `gen`, then `nix develop` into the shell (default `default`) |
| `blueprint run TASK [ARGS...]` | `gen`, then run a task in its shell, appending `ARGS` |
| `blueprint tasks` | List the tasks |
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
scripts/bundle.sh platform                  # bundle into dist/ and smoke-test
```

Only `x64musl` is supported. Everything the platform links except
`libhost.a` (the musl C runtime, libc, and compiler-rt) is vendored in
`platform/targets/x64musl/`; see `platform/targets/README.md` for where it
came from and its checksums.

### Releasing

`roc-blueprint` and `roc-blueprint-ir` have independent release cycles.

- **roc-blueprint-ir:** push a tag like `ir-0.1.0`. `release-ir.yml` tests and
  bundles `ir/` and publishes release `ir-0.1.0` with the bundle.
- **roc-blueprint:** put the ir bundle URL the platform should use in
  `platform/ir-release`, then push a tag like `0.1.0`. `release.yml` runs the
  tests and publishes release `0.1.0` with the platform bundle and a prebuilt
  `blueprint` binary.

During development the platform uses `ir: "../ir/main.roc"`. `roc bundle`
only packs files below the entry point's directory, so `scripts/bundle.sh
platform <ir-url>` bundles a staged copy whose `ir:` is the given URL. With
no URL it bundles the local `ir/` and serves it from localhost. Either way
it serves the platform bundle from localhost and runs `Blueprint.roc` against
it as a smoke test. CI does both, so a platform change that needs an
unreleased ir fails before release.

The two packages need separate tags: Roc identifies a package by its URL
minus the version and hash, so two bundles under one tag look like one
package served with two hashes.

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
