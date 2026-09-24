# roc-blueprint

<p align="center">
  <img src="docs/blueprint-gemini-gen.jpeg" alt="Blueprint illustration of robotic arms" width="560">
</p>

Describe your project's development environment in a small Roc file,
`Blueprint.roc`, and get a reproducible Nix dev shell and project tasks from
it.

```roc
# Blueprint.roc
app [config] { pf: platform "<platform URL from the latest release>" }

config = [
	Name("my-project"),
	Overlay("github:roc-lang/roc-overlay"),
	Shell("default", [Tools(["rocpkgs.nightly", "zig", "python3", "sqlite"])]),
	Shell("ci", [Tools(["rocpkgs.nightly", "zig"])]),
	Task("test", [Run(["python3", "scripts/test.py"])]),
	Task("check", [Run(["python3", "scripts/check.py"]), In("ci")]),
]
```

```sh
blueprint shell          # enter the default dev shell
blueprint shell ci       # or another one
blueprint run test       # run a task inside its shell
blueprint --help         # lists this project's shells and tasks
```

`Blueprint.roc` is plain data. Roc checks it as it compiles, so a mistyped
setting, a tool name with a space in it, or a malformed flake reference is an
error in your editor, pointing at the line. With the development platform,
`roc check Blueprint.roc` also rejects whole-config errors such as a missing
project name or duplicate shells; this requires the pinned September 23, 2026
Roc nightly or a compatible newer compiler. Older platform releases may
require `blueprint check` for these rules.

## Install

You need [Nix](https://nixos.org/download) with flakes enabled.

Enter a shell with `blueprint` and the Roc compiler it's built for:

```sh
nix develop github:lukewilliamboswell/roc-blueprint
```

or add `packages.x86_64-linux.blueprint` from this flake to your own flake.
Each [release](https://github.com/lukewilliamboswell/roc-blueprint/releases)
also has a prebuilt `blueprint-x86_64-linux`; that one needs the Roc nightly
named in the release notes, on your `PATH` or in `ROC`.

Only x86_64 Linux is supported for running blueprint. `Systems` controls the
shells written into the generated flake; it does not add platform host targets.

## Writing `Blueprint.roc`

The file is a Roc app whose platform is a roc-blueprint release. Copy the
`app` line from the [latest
release](https://github.com/lukewilliamboswell/roc-blueprint/releases). The
app provides one value, `config`, a list of settings:

| Setting | Meaning |
|---|---|
| `Name(Str)` | Project name. Required, once. |
| `Systems(List(System))` | Systems to generate shells for, e.g. `"x86_64-linux"`, `"aarch64-darwin"`. Default: x86_64 and aarch64, Linux and macOS. |
| `Packages(InputName, FlakeRef)` | A package set. `"nixpkgs"` (nixos-unstable) is always there; declare it to pin a different one, or add more, e.g. `Packages("stable", "github:NixOS/nixpkgs/nixos-24.05")`. |
| `Overlay(FlakeRef)` | A flake whose `overlays.default` is applied to every package set, e.g. `"github:roc-lang/roc-overlay"`. |
| `Input(InputName, FlakeRef)` | Any other flake input. |
| `Shell(Name, List(ShellSetting))` | A dev shell. Names must be unique; `"default"` is the one `blueprint shell` enters. |
| `Task(Name, List(TaskSetting))` | A named command. Names must be unique. |
| `Raw(backend, target, Val)` | Settings passed straight to a backend, for anything the other settings don't cover. See below. |
| `Custom(kind, name, Val)` | A block for a future or third-party feature. The current `blueprint` refuses configs that use one. |

Inside a `Shell`:

| Setting | Meaning |
|---|---|
| `Tools(List(Tool))` | Package attribute paths, e.g. `"git"` or `"llvmPackages.bintools"`, from `nixpkgs`; `"stable#jq"` takes `jq` from the `stable` package set. Repeat to add more. |

Inside a `Task`:

| Setting | Meaning |
|---|---|
| `Run(List(Str))` | The command and its arguments. Required, once. |
| `In(Name)` | The shell to run it in. Default: `"default"`. |

It's still Roc, so you can share values:

```roc
common = ["git", "python3"]

config = [
	Name("my-project"),
	Shell("default", [Tools(common), Tools(["sqlite"])]),
	Shell("ci", [Tools(common)]),
]
```

### Raw settings

`Raw` passes data straight to a backend. The Nix backend understands two
targets:

```roc
Raw("nix", "shell:default", Attrs([
	("shellHook", Str("echo ready")),
	("RUST_LOG", Str("debug")),    # environment variables are just attributes
])),
Raw("nix", "flake", Attrs([("formatter", Str("nixpkgs-fmt"))])),
```

- `shell:<name>` adds attributes to that shell's `mkShell` call.
- `flake` adds attributes to the flake's outputs.

Values are `Str`, `Int`, `Bool`, `List([...])` and `Attrs([(name, value), ...])`.
They're data, not Nix code, so they can't refer to packages or inputs.

See [the examples](examples/README.md) for a complete environment and a
separate example of custom extensions.

## Commands

Run these in the directory that contains `Blueprint.roc`.

| Command | |
|---|---|
| `blueprint` / `blueprint gen` | Write `.blueprint/flake.nix`, lock it, and keep `Blueprint.lock` in sync |
| `blueprint shell [NAME]` | Generate, then enter a dev shell (default `default`) |
| `blueprint run TASK [-- ARGS...]` | Generate, then run a task in its shell, with extra arguments |
| `blueprint tasks` | List the tasks |
| `blueprint update` | Update `Blueprint.lock` to the latest nixpkgs and overlays |
| `blueprint check` | Validate `Blueprint.roc` |
| `blueprint ir` / `blueprint flake` | Print the intermediate form, or the generated files |
| `blueprint --help` | Help for this project: `run --help` lists its tasks, `shell --help` its shells and their tools |

- **Commit** `Blueprint.roc` and `Blueprint.lock`. The lock pins nixpkgs and
  every overlay, so everyone gets the same tools.
- **Ignore** `.blueprint/`. It's generated on every run.
- **`ROC`** chooses the Roc compiler. The Nix package sets it to the right one.

## How it works

`blueprint` compiles and runs `Blueprint.roc`. The roc-blueprint platform
checks the settings and prints them as an S-expression, defined by the
`roc-blueprint-ir` package. `blueprint` reads that, writes a Nix flake to
`.blueprint/`, and runs `nix develop` with it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
