# Foundation source handoff (B4)

This is the public boundary of the B0–B4 foundation, not a successor port or a
published release. Use the exact tested commit in
[foundation-snapshot.md](foundation-snapshot.md), together with
[foundation-manifest.json](foundation-manifest.json). Keep this staging repository
available until the later port passes its acceptance gates. No retirement,
backend autodetection, successor ownership paths or successor policy is included.

## Importable packages

| Boundary | Entry point | Public modules |
| --- | --- | --- |
| Configuration platform | `blueprint-ir-platform/main.roc` | `Config`, `EnvName`, `FlakeRef`, `InputName`, `System`, `TaskName`, `Tool`, `Val`, `WorkflowName` |
| Pure core | `blueprint-ir-package/main.roc` | `Ir`, `Project`, `Sexpr`, `Value`, `Request`, `Plan`, `Layout` |
| Pure Nix adapter | `blueprint-nix-package/main.roc` | `Backend`, `NixBackend`, `Locks` |

The Nix package depends only on the core and its bundled runner source, not the
reference CLI or its effectful platform. The configuration platform depends on
the same core. Vendor these source directories together, or distribute normal
Roc bundles with their dependency headers set to the same core package identity.
No consumer needs to invoke Blueprint or patch its modules. `Backend` contains
inspection metadata (`name`, `features`, `render`), not a backend registry.

`LockJson`, `TestData`, renderer helpers and graph traversal helpers are
implementation details, not additional consumer protocols. Roc's public module
surface may make internal associated functions reachable; the supported calls
and data contracts for this handoff are listed below.

## Authoring

The complete, formatted, checked examples are:

- [all-settings](../examples/all-settings/Blueprint.roc): environments, aliases,
  provider sources and scoped overlays;
- [composition](../examples/composition/Blueprint.roc): ordinary imported Roc
  functions returning `List(Config.Setting)`, using `EnvName` rather than an
  unchecked string for a dynamic environment argument;
- [artifacts](../examples/artifacts/Blueprint.roc): local locked source,
  dependency artifact, exact argv task, and typed workflow, with real scripts.

`Config.Setting` supports `Name`, `Systems`, `Packages`, `Input`, `Overlay`,
`Environment`, `Shell`, `Task`, `Source`, `Build`, `Workflow`, `Raw` and `Custom`.
`Custom` is retained as unsupported extension data: it grants no capabilities.
See [README](../README.md#writing-blueprint-roc) for constructor signatures.

There is one generic `Tools` list. `Packages(name, Auto)` leaves provider
selection to the consumer; `From(NixPackages(ref))` or `From(GuixPackages(ref))`
expresses a source constraint. Tool suffixes are native package names, not a
translation catalog. Named overlays apply only through environment selection.
`Extend` accepts one parent; parent tools/overlays precede child additions,
deduplicated by first occurrence. Empty child lists do not clear inheritance.
Shells and tasks use environments directly; there is no legacy `In` adapter.

`Build` requires `Use`, `Run` and `Output`; optional `Inputs` names non-flake
sources and `Needs` names artifacts. A dependency exposes exactly its declared
file/directory, not its full build tree. Sources and artifacts are separate
read-only views under `BLUEPRINT_INPUTS` and `BLUEPRINT_ARTIFACTS`. Those variable
names are the Nix runner contract; they are not provider-branded authoring
constructors. Nothing automatically passes artifacts to ordinary tasks.

`Workflow` contains typed `RunTask`, `BuildArtifact` and `RunWorkflow` steps.
Ordering and repetition are preserved; failures stop later effects, without
rollback or retries. Every explicit build operation snapshots current project
files and resolves its dependency graph from that snapshot. An intervening task
can change untracked/generated project files; it cannot silently change locked
source contents. Immutable plan recipe sharing is not artifact-result caching.

## Decode, validate, plan

The [independent consumer](../fixtures/consumer/main.roc) is the executable API
example. Its supported call sequence is:

1. `Ir.parse(compiler_stdout)` checks wire syntax and major version.
2. `Project.validate(ir)` validates and normalizes the semantic project.
3. `Locks.decode(authority_text)` validates supplied resolved lock data.
4. `NixBackend.plan(project, request, target, layout, locks)` returns a complete
   `Try(Plan, Str)` without discovering paths, selecting a backend or executing
   anything. It repeats semantic/feature/lock checks at this runtime boundary.

A consumer can call `NixBackend.preflight(ir, request, target, layout)` before
reading authority. It returns `Try({}, Str)` and checks the entire requested
closure, including all later workflow steps. Filesystem observations and actual
package existence remain execution-time checks. `Ir.unsupported_features` is
available for loaders; `Ir.parse` alone is not a complete compatibility check.

Core calls and values:

| API | Contract |
| --- | --- |
| `Ir.current_format` | `{ major: 2, minor: 2 }` |
| `Ir.to_str`, `Ir.parse` | Canonical S-expression codec; same-major minor compatibility |
| `Project.validate` | Whole-project structural validation and inheritance normalization |
| `Project.build_closure(ir, name)` | Unique dependency-first build declarations |
| `Project.workflow_steps(ir, name)` | Ordered atomic task/build steps, preserving repetition |
| `Project.check_environment(ir, Nix \| Guix, name)` | Requested environment's provider grammar/constraint/capability check; not a Guix executor |
| `Request` | `Generate`, `Shell(Str)`, `Run(Str, List(Str))`, `Build(Str)`, `Workflow(Str)` |
| `Layout` | Caller-owned normalized absolute `project_root`, `workspace`, `generated_root`, `lock_path` |
| `Layout.validate` | Pure lexical layout validation; runtime symlink checks remain required |

IR required features currently supported by Nix are `raw`, `sources`, `builds`
and `workflows`; `extensions` remains unsupported. Workflow/build/source fields
cannot be silently discarded by an older compliant consumer: lowering includes
the corresponding required features. Unknown major versions, required features
and typed step tags fail. The canonical field/type definitions live in
[Ir.roc](../blueprint-ir-package/Ir.roc), not a second dynamic configuration schema.
Compile-time lowering remains the platform's top-level `rendered` constant.

## Plan and executor contract

`Plan` contains `steps: List(Plan.Step)`. Each step has:

- `action`: `Generate`, `Shell(name)`, `Run(name)` or `Build(name)`;
- `files`: absolute generated paths and contents, never authoritative lock writes;
- `argv`: exact strings, executable first (empty only for Generate);
- `artifacts`: dependency-first records `{name, installable, output, dependencies}`;
- `operations`: ordered `VerifyLocal({path, nar_hash})` and, for builds,
  `Snapshot({root, destination, exclude})` values.

The consumer obtains **the entire plan before executing a step**. For each step,
perform operations, stage files, then run argv from `layout.project_root`;
stop immediately on failure. Repeated build steps must perform their Snapshot
operations again. Resolve artifact paths using the planned backend command;
`installable` is not a guessed store path. There is intentionally no serialized
Plan decoder in the configuration protocol.

The reference executor in `blueprint-cli/main.roc` demonstrates path checks,
local NAR verification, atomic derivative writes, process invocation and failure
reporting. `scripts/blueprint-runtime.py` supplies filesystem-only effects,
embedded into that CLI. A consumer owns equivalent execution and confirmation
policy; importing the pure packages does not give them effects.

The Nix runner is embedded data in the backend package and staged by its plans.
It requires a snapshot plus the separate `.isolation.json` namespace witness
specified by `Plan.Operation`. Before user Run, it rejects shared caller/build
mount or network namespaces. Preserve this materialization contract when
porting; do not replace it with an assumption that client sandbox flags were
honored by the daemon. Real host-file/TCP tests remain necessary too.

## Lock lifecycle

There is one caller-selected authoritative lock. The reference format is a
version-1 JSON envelope with declaration/ordered-overlay identity and a native
Nix version-7 graph. A consumer receiving a native Nix lock can explicitly use
`Locks.from_nix(ir, layout, text)` to obtain the checked value in memory; it need
not create a second authoritative file. Supplied graph input identities must
match the configuration's named declarations.

- `Locks.decode`, `encode`: validated authority serialization.
- `Locks.from_nix`: validate resolved native observations and canonicalize local
  source identities to relative project paths plus their NAR hashes.
- `Locks.derive`: check configuration identity and produce a derivative native
  lock, rebased to the caller root, with local verification operations.
- `NixBackend.update_files`, `local_checks`: pure inputs for the caller's
  **explicit** resolution/update operation. Only after validating its result
  should the caller publish replacement authority.
- `NixBackend.render`, `render_environment`: shared-renderer inspection helpers,
  not an alternative execution protocol. Builds need planned materialization.

Normal gen/shell/task/build/workflow execution never initializes or updates
pins. Native commands receive both no-update/no-write lock flags. Local source
changes fail even if old inputs/artifacts remain cached. Relocating a project
changes derivative paths, not authority or artifact contents. All local inputs
are checked on each executable step, including otherwise unselected declarations.

## Verified limits and trust

- Execution: local **x86_64 Linux**. macOS package evaluation is not execution
  qualification. Guix intent/grammar validation only; no Guix executor.
- The Nix wrapper supplies pinned Roc and Python. A standalone CLI still needs
  Roc, Python 3.9+, and Nix. `ROC` is an explicit tested override; the reference
  loader requires the pinned compiler version. Compile-time checks do not remove
  runtime configuration compilation or sandbox its imports.
- Snapshots include ordinary untracked/task-generated files. Exclude VCS metadata,
  supplied workspace/generated roots, authority and all declared local input
  trees. All symlinks and special files in snapshots/sources/outputs are rejected.
  Keep sensitive files outside the included tree; no secret detection is claimed.
- Read-only input views and contained outputs are enforced by the Nix runner.
  Tasks and compilation are not sandboxed. Trust the Nix daemon/kernel/package
  sources; remote builders are disabled for the tested isolation contract.
- Serialize shared-workspace use; do not mutate source trees/path components
  concurrently with materialization. No filesystem transaction against hostile
  concurrent writers is claimed.
- Bounded build/workflow graphs and lock parsing are documented in
  [B2](b2.md) and [B3](b3.md). Workflow rendered text is limited incrementally;
  this is not a universal total-memory bound for arbitrary Roc values.
- No services, secrets, machines, deployment, images, ISOs, executable plugins,
  package translation, backend autodetection or successor ownership policy.

## Port acceptance material

Carry the three source directories, host/linker inputs, exact toolchain/dependency
pins, runtime effects, and these tests—not merely an API sketch:

- `scripts/test-config.sh`: local/bundled compile-time positive/negative fixtures;
- core/backend/consumer `roc test` roots, S-expression fuzz corpus and generators;
- `scripts/test-cli.py`, `test-update.py`: loader/argv/effect-boundary regressions;
- `test-b1.sh`, `test-b2.py`, `test-b3.py`: real Nix environments, immutable locks,
  artifact bytes, input/output policy, isolation and workflow failure/freshness;
- `test-consumer.sh`: supplied-lock plans and real Nix checks without Blueprint;
- `test-handoff.py`: detached normal package imports, bundled configuration using
  the same core, byte-identical plans, and a consumer executable running with no
  server, Nix, Roc or Blueprint on PATH;
- `scripts/test.sh`: Nix package build and both existing platform bundle gates.

The old released major-1 IR gate must remain blocking. A compatible release has
not been invented or substituted. The tested local core/platform/backend together
are sufficient for a **source-only** handoff; they are not release-qualified.
