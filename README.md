# roc-blueprint

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
error in your editor, pointing at the line.

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

Only x86_64 Linux is supported for now.

## Writing `Blueprint.roc`

The file is a Roc app whose platform is a roc-blueprint release. Copy the
`app` line from the [latest
release](https://github.com/lukewilliamboswell/roc-blueprint/releases). The
app provides one value, `config`, a list of settings:

| Setting | Meaning |
|---|---|
| `Name(Str)` | Project name. Required, once. |
| `Systems(List(System))` | Nix systems to generate shells for: `X86_64Linux`, `Aarch64Linux`, `X86_64Darwin`, `Aarch64Darwin`. Default: all four. |
| `Overlay(FlakeRef)` | A flake whose `overlays.default` is applied to nixpkgs, e.g. `"github:roc-lang/roc-overlay"`. |
| `Shell(Name, List(ShellSetting))` | A dev shell. Names must be unique; `"default"` is the one `blueprint shell` enters. |
| `Task(Name, List(TaskSetting))` | A named command. Names must be unique. |

Inside a `Shell`:

| Setting | Meaning |
|---|---|
| `Tools(List(Tool))` | nixpkgs attribute paths, e.g. `"git"` or `"llvmPackages.bintools"`. Repeat to add more. |

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

See [`examples/Blueprint.roc`](examples/Blueprint.roc) for every setting in
one file.

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
| `blueprint ir` / `blueprint flake` | Print the intermediate form, or the generated flake |
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
