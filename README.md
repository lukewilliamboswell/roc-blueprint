# roc-blueprint

<p align="center">
  <img src="docs/blueprint-gemini-gen.jpeg" alt="Blueprint illustration of robotic arms" width="560">
</p>

Describe reusable environments, argv tasks, sandboxed artifact builds and ordered
workflows in `Blueprint.roc`. The reference CLI executes pure Nix plans.

**Foundation API (B4, IR 2.2):** these examples use the local source
platform, not the latest published release. This snapshot is source-only and
not release-qualified; the pinned released-IR bundle gate is expected to block
until an actual compatible IR release exists. See the [public handoff API](docs/foundation-api.md)
and [exact tested snapshot](docs/foundation-snapshot.md). The staging repository
remains available until the later port succeeds.

```roc
# Blueprint.roc at the repository root
app [config] { pf: platform "blueprint-ir-platform/main.roc" }

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
consumer selects a backend. Package existence is resolved by Nix, not Roc.

## Install

Development and verified execution require x86_64 Linux and
[Nix](https://nixos.org/download) with flakes enabled. From this checkout:

```sh
nix develop .                 # blueprint plus its pinned Roc compiler
nix develop .#contributor     # also supplies build/test tools
```

You can add `packages.x86_64-linux.blueprint` from this source flake to your
own flake. Keep the CLI and configuration platform on the same compatible
source snapshot. Build the platform host before running local examples; see
[CONTRIBUTING.md](CONTRIBUTING.md).

The upstream flake is available via
`nix develop github:lukewilliamboswell/roc-blueprint`; published binaries are
listed under [releases](https://github.com/lukewilliamboswell/roc-blueprint/releases).
Do not assume either accepts this development API. A prebuilt
`blueprint-x86_64-linux` needs the compatible Roc nightly named in its release
notes, on `PATH` or in `ROC`, plus Nix and Python 3.9+ for runtime effects.
The source Nix package supplies Roc and Python. Compile-time validation does
**not** eliminate the compiler requirement: loading a configuration invokes Roc.

`Systems` controls generated Nix output shapes; it neither installs platform
host targets nor proves execution support. Only x86_64 Linux execution is
verified. macOS output evaluation is not a platform execution test.

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
| `Raw(backend, target, Val)` | Backend-specific data; see below. |
| `Custom(kind, name, Val)` | Extension data. The current CLI rejects unsupported extensions. |

Inside an `Environment`, each setting occurs at most once:

| Setting | Meaning |
|---|---|
| `Tools(List(Tool))` | Native package names. `"git"` uses source `default`; `"stable#jq"` uses source `stable`. |
| `Overlays(List(InputName))` | Ordered selection of declared overlay names. |
| `Extend(EnvName)` | Inherit one environment's tools and overlays before appending this environment's selections. |

Inheritance deduplicates by first occurrence, parent first. Omitted or empty
`Tools`/`Overlays` lists do not clear inherited values. A standalone environment
has no overlays unless selected. `Run` must contain a nonempty executable;
arguments remain separate strings, including extra CLI arguments after `--`.
There is no `In` setting or implicit task environment.

Provider details stay in source declarations (a fragment inside `config`):

```roc
Packages("stable", From(NixPackages("github:NixOS/nixpkgs/nixos-24.05"))),
Environment("dev", [Tools(["git", "stable#jq"])]),
```

The core does not inspect `PATH`, autodetect a backend or translate package
names. The reference CLI explicitly selects Nix. Guix source intent and pure
capability validation exist, but there is **no Guix renderer or executor**.
An incompatible requested environment fails; it never retries another provider.
Missing native packages and unavailable target packages fail in Nix rather than
being silently filtered out. Unsupported Nix target declarations fail before
file writes or backend execution.

Use ordinary Roc lists and functions for composition, not a plugin registry.
[ProjectTasks.roc](examples/composition/ProjectTasks.roc) returns
`List(Config.Setting)`; its [app](examples/composition/Blueprint.roc)
concatenates those settings into `config`. Imports do not install tools or add
runtime operations to the CLI.

### Artifact builds

Inside `config`, with `scripts/build.py` in the project:

```roc
Source("assets", "path:./assets"),
Build("app", [
	Use("dev"),
	Inputs(["assets"]),
	Run(["python3", "scripts/build.py"]),
	Output("dist/app"),
]),
```

Run `blueprint update`, then `blueprint build app`. The printed store path is
resolved by Nix and contains exactly the declared file or directory. Missing
outputs fail. `Needs(["library"])` adds build dependencies; cycles fail during
configuration validation. Sources live under `$BLUEPRINT_INPUTS/<name>` and
needed artifacts under `$BLUEPRINT_ARTIFACTS/<name>`, both read-only and separate
from the writable project copy.

Each build snapshots current project files, including untracked/task-generated
files, excluding VCS metadata, caller-generated roots, authority and all local
input trees. Changing a locked local source requires explicit update. Initial
source/output policy rejects symlinks and special files. Only local x86_64 Linux
sandboxed execution is verified; tasks/config compilation are not sandboxed.
See the [complete runnable example](examples/artifacts/README.md),
[real build fixture](fixtures/builds/README.md) and [API](docs/b2.md).

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
See the [real workflow fixture](fixtures/workflows/README.md) and [limits/API](docs/b3.md).

### Raw settings

The Nix backend accepts attribute data at two targets:

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
managed `packages`/`devShells` are rejected. Raw for other backends is ignored.

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
| `blueprint ir` / `blueprint flake` | Print semantic IR or the generated flake |
| `blueprint --help` | Project help; subcommand help lists tasks, aliases and builds |

Backend capability checks follow the requested environment closure; unrelated
valid provider declarations do not block selected operations. Whole-project
structural validation and required-feature checks still apply. Full rendering
(`gen`, `update`, `check`, `flake`) checks all shell/task/build environments.

- **Commit** `Blueprint.roc` and the authority (default `Blueprint.lock`);
  **ignore** generated state (default `.blueprint/`).
- Normal `gen`, `shell`, `run`, `build` and `workflow` require matching pins and never
  rewrite authority or independently update derived locks. B1 raw locks need
  an explicit `update` to become the validated versioned B2 envelope.
- **`BLUEPRINT_WORKSPACE`**, **`BLUEPRINT_GENERATED_ROOT`**, **`BLUEPRINT_LOCK`**
  choose caller paths; relative values resolve against the selected project
  root, not the invocation directory. Out-of-tree generated roots are supported.
- **`BLUEPRINT_TARGET`** selects a declared target (default `x86_64-linux`).
  **`ROC`** selects the pinned compatible compiler; the Nix wrapper supplies it.
- Handoff qualification (B4) remains pending. No Guix executor or parallel
  workflow scheduler is implemented.

## How it works

The platform lowers and validates the whole config at top level, then prints
IR 2.2 as an S-expression. The CLI invokes Roc, parses and revalidates that
IR through the shared pure `Project` boundary, explicitly selects Nix, and
owns file writes, locking and execution. The importable core and Nix renderer
perform no host discovery or effects.

See [B3 API and validation](docs/b3.md), [B2 build guarantees](docs/b2.md), [B1 history](docs/b1.md),
[examples](examples/README.md) and
[CONTRIBUTING.md](CONTRIBUTING.md).
