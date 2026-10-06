# roc-blueprint

<p align="center">
  <img src="docs/blueprint-gemini-gen.jpeg" alt="Blueprint illustration of robotic arms" width="560">
</p>

Describe reusable environments, argv tasks, sandboxed artifact builds and ordered
workflows in `Blueprint.roc`. The reference CLI executes pure Nix plans.

**Status (Spec 2.5):** these examples use the local source platform, not the
latest published release. The architecture, terminology and invariants are in
[docs/architecture.adoc](docs/architecture.adoc).

```roc
# Blueprint.roc at the repository root
app [config] { pf: platform "blueprint-platform/main.roc" }

config = [
	Name("my-project"),
	Systems(["x86_64-linux"]),
	Overlay("roc", "github:roc-lang/roc-overlay"),
	Environment("base", [Tools(["git", "zig"])]),
	Environment("dev", [
		Extend("base"),
		Tools(["rocpkgs.nightly", "python3", "sqlite"]),
		Overlays(["roc"]),
	]),
	Shell("default", [Use("dev")]),
	Shell("ci", [Use("base")]),
	Task("version", [Use("dev"), Run(["python3", "--version"])]),
	Task("check", [Use("base"), Run(["git", "--version"])]),
]
```

```sh
blueprint update         # explicitly initialize/update dependency pins
blueprint shell          # enter the default shell's environment
blueprint shell ci       # enter base, without the roc overlay
blueprint run version    # run argv directly in dev
blueprint --help         # list this project's shells and tasks
```

Roc checks quoted values and whole-config rules, including missing names,
duplicate declarations, unknown references and inheritance cycles, during
`roc check Blueprint.roc`. This requires the pinned September 23, 2026 Roc
nightly or a compatible compiler. Explicit sources also enable static
provider-specific tool grammar checks; `Auto` defers those checks until the
consumer selects a provider. Package existence is resolved by Nix, not Roc.

## Install

Development and verified execution require x86_64 Linux and
[Nix](https://nixos.org/download) with flakes enabled. From this checkout:

```sh
nix run . -- --help           # the blueprint CLI, built with its pinned Roc compiler
nix develop                   # the toolchain for working on this repository
```

You can add `packages.x86_64-linux.blueprint` from this source flake to your
own flake. Keep the CLI and configuration platform on the same compatible
source snapshot. Build the platform host before running local examples; see
[CONTRIBUTING.md](CONTRIBUTING.md).

Prebuilt `blueprint` binaries for x86_64 Linux, arm64 Linux and Apple Silicon
macOS are attached to each [release](https://github.com/lukewilliamboswell/roc-blueprint/releases),
with their sha256 sums. A binary needs Nix; builds also use coreutils
`readlink`. It does not need Python or Roc installed: loading a configuration runs one exact Roc nightly, and the
binary uses a `roc` on `PATH` when that is the right one, and otherwise fetches
it through Nix from a pinned roc-overlay revision. Set `ROC` to choose the
executable yourself; it must be that same nightly.

Use each release's binary with that release's platform URL. The upstream flake
also runs the CLI directly: `nix run github:lukewilliamboswell/roc-blueprint`.
Do not assume a published release accepts this development API.

`Systems` controls generated Nix output shapes; it neither installs platform
host targets nor proves execution support. Configurations execute on x86_64
Linux, arm64 Linux and Apple Silicon macOS. No Intel macOS binary is released:
the platform has a host for it and the CLI evaluates configurations there, but
entering an environment fails with current nixpkgs, which has dropped that
system.
Sandboxed builds remain x86_64 Linux only.

## Writing `Blueprint.roc`

Use the local platform path appropriate to your app, as in the
[checked examples](examples/README.md). The app provides `config`, a list of
settings:

| Setting | Meaning |
|---|---|
| `Name(Str)` | Project name. Required, once. |
| `Systems(List(System))` | Declared targets. Defaults to x86_64 and aarch64 on Linux and macOS; an empty list is invalid. |
| `Packages(InputName, Auto)` | Named source using the consumer-selected provider's default. Omitting `Packages("default", Auto)` has the same meaning. |
| `Packages(InputName, From(Provider))` | Explicit source intent: `NixPackages(FlakeRef)` or `GuixPackages(Str)`. |
| `Overlay(InputName, FlakeRef)` | Named overlay input; only environments selecting its name apply it. |
| `Input(InputName, FlakeRef)` | Other flake input; not a tool source or overlay. |
| `Environment(EnvName, List(EnvironmentSetting))` | Named tools and scoped overlays, optionally inherited. |
| `Shell(EnvName, List(ShellSetting))` | Named alias with exactly one `Use(environment)`. `blueprint shell` selects alias `"default"`. |
| `Task(TaskName, List(TaskSetting))` | Named argv command with exactly one `Use(environment)` and one `Run(argv)`. No shell alias is required. |
| `Source(InputName, FlakeRef)` | Locked non-flake input, e.g. `Source("assets", "path:./assets")`. |
| `Build(InputName, List(BuildSetting))` | Sandboxed artifact with required `Use`, exact argv `Run`, relative `Output`; optional `Inputs` and `Needs`. |
| `Workflow(WorkflowName, List(WorkflowStep))` | Ordered `RunTask(name, extra_argv)`, `BuildArtifact(name)` and `RunWorkflow(name)` steps. |
| `Raw(backend, target, Val)` | Provider-specific data; see below. |
| `Custom(kind, name, Val)` | Extension data. The current CLI rejects unsupported extensions. |

Inside an `Environment`, `Tools` and `Overlays` occur at most once, `ToolsFor`
occurs at most once per System, `Command` occurs at most once per command
name, and `RocPackages` occurs at most once:

| Setting | Meaning |
|---|---|
| `Tools(List(Tool))` | Native package names. `"git"` uses source `default`; `"stable#jq"` uses source `stable`. |
| `ToolsFor(System, List(Tool))` | Add tools only for a declared target System. Each System occurs at most once per Environment. |
| `Command(Str, Tool)` | Expose one tool's main program under another command name, without adding the tool's own executables. |
| `RocPackages(List(Str))` | Released Roc bundle URLs to lock, so Roc programs in the environment resolve them without downloading. |
| `Overlays(List(InputName))` | Ordered selection of declared overlay names. |
| `Extend(EnvName)` | Inherit one environment's tools, overlays, commands and Roc packages before appending this environment's selections. |

Inheritance deduplicates by first occurrence, parent first. Omitted or empty
`Tools`/`ToolsFor`/`Overlays` lists do not clear inherited values. A standalone environment
has no overlays unless selected. `Run` must contain a nonempty executable;
arguments remain separate strings, including extra CLI arguments after `--`.
There is no `In` setting or implicit task environment.

Provider details stay in source declarations (a fragment inside `config`):

```roc
Packages("stable", From(NixPackages("github:NixOS/nixpkgs/nixos-24.05"))),
Environment("dev", [Tools(["git", "stable#jq"])]),
```

The core does not inspect `PATH`, autodetect a provider or translate package
names. The reference CLI explicitly selects Nix. Guix source intent and pure
capability validation exist, but there is **no Guix renderer or executor**.
An incompatible requested environment fails; it never retries another provider.
Missing native packages and unavailable target packages fail in Nix rather than
being silently filtered out. Unsupported Nix target declarations fail before
file writes or provider execution.

For a shell shared by Linux and macOS, put common tools in `Tools` and declare
platform libraries explicitly:

```roc
Environment("dev", [
	Tools(["git", "python3"]),
	ToolsFor("x86_64-linux", ["wayland", "alsa-lib"]),
]),
```

`ToolsFor` is provider-neutral Spec intent. It applies to inherited environments,
shells, tasks and builds on that System; undeclared systems and duplicate
declarations are rejected during evaluation.

`Command` keeps a pinned tool beside another tool of the same name. For example,
repository scripts can run on one fixed Roc release while the project is built
with whichever `roc` is already on `PATH`:

```roc
Overlay("roc", "github:roc-lang/roc-overlay"),
Environment("dev", [
	Overlays(["roc"]),
	Command("roc-stable", "rocpkgs.nightly-2026-09-10-a670e34"),
]),
```

The environment gains `roc-stable` and no `roc`, so a script can start with
`#!/usr/bin/env roc-stable`. The command runs the tool's main program as its
package declares it; a package that declares none fails in Nix. Command names
are plain file names. An extending environment inherits commands and replaces
one by declaring the same name.

### Roc packages

A Roc script names its platform and packages by release URL, and Roc downloads
them on first use. `RocPackages` locks those bundles instead, so the scripts of
an environment run without a download, and run at all in a sandboxed build,
which has no network:

```roc
Overlay("roc", "github:roc-lang/roc-overlay"),
Environment("scripts", [
	Overlays(["roc"]),
	Command("roc-stable", "rocpkgs.nightly-2026-10-04-130536d"),
	RocPackages([
		"https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
		"https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	]),
]),
Task("release", [Use("scripts"), Run(["roc-stable", "scripts/release.roc"])]),
Build("notes", [Use("scripts"), Run(["roc-stable", "scripts/notes.roc"]), Output("notes.txt")]),
```

Each URL must be `https://` and end in `<hash>.tar.zst`. `blueprint update`
records every bundle in `Blueprint.lock` like any other source, and Nix checks
the downloaded bytes against that pin. An extending environment inherits its
parent's bundles.

**List every bundle, including dependencies of dependencies.** basic-cli above
depends on `http`, so both are listed. `roc deps <file>` prints the URLs a
program depends on. Blueprint does not read package headers, so it cannot add a
missing one for you. A bundle that is not listed is downloaded by Roc as usual
in a shell or task, and fails to resolve in a sandboxed build.

What Blueprint writes, and where:

- **`blueprint shell` and `blueprint run`** publish the environment's bundles
  into Roc's own package cache before entering it: the directory
  `roc/packages` under `$XDG_CACHE_HOME`, or under `~/.cache` when that is
  unset. Each bundle becomes the directory `<hash>` there, a copy of the locked
  files, which is where Roc looks before downloading. A `<hash>` directory that
  already has a `main.roc` is never touched, whether Roc downloaded it or an
  earlier run published it; one without a `main.roc` is incomplete and is
  replaced, as Roc itself would. The copy is made in a temporary directory
  beside it, named `blueprint-<hash>.<random>.tmp`, and renamed into place, so
  another Roc process never sees half a package. Nothing else is written, and
  nothing at all when every bundle is already there or the environment has no
  Roc packages. If the cache is deleted, the next run publishes again.
- **`blueprint build`** does not use that cache. The build gets a package cache
  of its own inside its build directory, holding only its environment's
  bundles, and `XDG_CACHE_HOME` points the build's command at it.

A build sees only the tools its environment declares, so a build that runs Roc
needs a Roc tool, such as the `roc-stable` command above.

Use ordinary Roc lists and functions for composition, not a plugin registry.
[ProjectTasks.roc](examples/composition/ProjectTasks.roc) returns
`List(Config.Setting)`; its [app](examples/composition/Blueprint.roc)
concatenates those settings into `config`. Imports do not install tools or add
runtime operations to the CLI.

### Artifact builds

Inside `config`, with `scripts/build.roc` in the project and the `scripts`
environment of [Roc packages](#roc-packages) above:

```roc
Source("assets", "path:./assets"),
Build("app", [
	Use("scripts"),
	Inputs(["assets"]),
	Run(["roc-stable", "scripts/build.roc"]),
	Output("dist/app"),
]),
```

`Run` is any argv; nothing about a build requires Roc. Roc takes the first
`--` of its arguments for itself, so pass a script its own arguments after
one: `Run(["roc-stable", "scripts/build.roc", "--", "--release"])`.

Run `blueprint update`, then `blueprint build app`. The printed store path is
resolved by Nix and contains exactly the declared file or directory. Missing
outputs fail. `Needs(["library"])` adds build dependencies; cycles fail during
configuration validation. Sources live under `$BLUEPRINT_INPUTS/<name>` and
needed artifacts under `$BLUEPRINT_ARTIFACTS/<name>`, both read-only and separate
from the writable project copy.

Each build snapshots current project files, including untracked/task-generated
files, excluding VCS metadata, caller-generated roots, authority and all local
input trees. Nix makes that copy directly from the project, so a file is
executable in a build only when its owner may execute it. Changing a locked
local source requires explicit update. Initial
source/output policy rejects symlinks and special files. Only local x86_64 Linux
sandboxed execution is verified; tasks/config compilation are not sandboxed.
A build's `PATH` holds exactly the tools its environment declares. Earlier
versions also put `python3`, coreutils and `bash` there, so a build that ran
`sh`, `cp`, `mkdir` or `python3` without declaring it now fails with `build
command not found`, or inside its own script when that script calls one: add
the tool (`bash`, `coreutils`, `python3`) to the environment's `Tools`. A build
also no longer sees the variables Nix's `stdenv` used to export. A tool may
give what it runs more than the build was given: the Roc compiler's package
puts coreutils and a C compiler on the `PATH` of a script it runs.
The `blueprint` executable is itself each build's builder inside the sandbox,
so `blueprint build` refuses to run unless that executable is an x86_64 Linux
one.
See the [complete runnable example](examples/artifacts/README.md),
[real build fixture](fixtures/builds/README.md).

### Ordered workflows

Inside `config`, referring to existing tasks and builds:

```roc
Workflow("ci", [RunTask("check", ["--verbose"]), BuildArtifact("app"), RunWorkflow("verify")]),
Workflow("verify", [RunTask("version", [])]),
```

`blueprint workflow ci` plans the complete dependency/capability/layout/lock
closure before executing any task. Steps run in order and stop on the first
failure. Repeated explicit tasks and builds repeat; every build snapshots current
project files and rebuilds its dependency graph from that snapshot. Nix may reuse
unchanged inputs, but Blueprint never caches artifact results across tasks.
Locked sources are verified again; task edits to them require explicit update.
Cycles and excessive depth/expansion fail during configuration validation.
See the [real workflow fixture](fixtures/workflows/README.md).

### Raw settings

The Nix provider accepts attribute data at two targets:

```roc
Raw("nix", "shell:default", Attrs([
	("shellHook", Str("echo ready")),
	("RUST_LOG", Str("debug")),
])),
Raw("nix", "flake", Attrs([("formatter", Str("nixpkgs-fmt"))])),
```

- `shell:<alias>` adds attributes to that alias's `mkShell` call, not other
  aliases or tasks using the same environment.
- `flake` adds attributes to flake outputs.

Values are `Str`, `Int`, `Bool`, `List([...])` and `Attrs([(name, value), ...])`.
They are data, not Nix expressions. Duplicate attributes and overrides of
managed `packages`/`devShells` are rejected. Raw for other providers is ignored.

## Commands

Run these in the directory containing `Blueprint.roc`, or set `BLUEPRINT_ROOT`.

| Command | Meaning |
|---|---|
| `blueprint` / `blueprint gen` | Generate `.blueprint/` from existing matching authoritative pins |
| `blueprint shell [NAME]` | Generate the selected alias's environment, then enter it (default alias `default`) |
| `blueprint run TASK [-- ARGS...]` | Generate the task's environment, then run its argv with extra arguments |
| `blueprint build NAME` | Snapshot and build an artifact plus dependencies; print its actual store path |
| `blueprint workflow NAME` | Execute an ordered task/build workflow, stopping on failure |
| `blueprint tasks` | List tasks and their environments |
| `blueprint update` | Explicitly initialize/update and atomically publish the authoritative lock |
| `blueprint check` | Run the compiler check and validate all shell/task/build environments without requiring a lock |
| `blueprint spec` / `blueprint flake` | Print the Spec or the generated flake |
| `blueprint --help` | Project help; subcommand help lists tasks, aliases and builds |

Provider capability checks follow the requested environment closure; unrelated
valid provider declarations do not block selected operations. Whole-project
structural validation and required-feature checks still apply. Full rendering
(`gen`, `update`, `check`, `flake`) checks all shell/task/build environments.

- **Commit** `Blueprint.roc` and the authority (default `Blueprint.lock`, a
  versioned S-expression listing each pinned source and its digest);
  **ignore** generated state (default `.blueprint/`). A lock written by an
  older `blueprint` is refused; run `blueprint update`.
- Normal `gen`, `shell`, `run`, `build` and `workflow` require matching pins and never
  rewrite authority or independently update derived locks.
- `nix develop` takes the bash it runs a shell or task with from a flake input
  named `nixpkgs`, so the generated flake gives that name to the `default`
  package source (or, without one, the first Nix package source declared) and
  that bash is pinned by `Blueprint.lock` like every tool, unless the project
  declares an input named `nixpkgs` itself.
- **`BLUEPRINT_WORKSPACE`**, **`BLUEPRINT_GENERATED_ROOT`**, **`BLUEPRINT_LOCK`**
  choose caller paths; relative values resolve against the selected project
  root, not the invocation directory. Out-of-tree generated roots are supported.
- **`BLUEPRINT_TARGET`** selects a declared target (default: this machine's
  System). **`ROC`** selects the compatible compiler; unset, it is found on
  `PATH` or fetched.
- No Guix executor or parallel workflow scheduler is implemented.

## How it works

The platform lowers and validates the whole config at top level, then prints
Spec 2.5 as an S-expression. The CLI invokes Roc, parses and revalidates that
Spec through the shared pure `Project` boundary, explicitly selects Nix, and
owns file writes, locking and execution. The importable core and Nix renderer
perform no host discovery or effects.

See [the architecture](docs/architecture.adoc),
[examples](examples/README.md) and
[CONTRIBUTING.md](CONTRIBUTING.md).
