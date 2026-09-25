# Contributing to roc-blueprint

## Layout

```
blueprint-ir-platform/   the roc-blueprint platform that Blueprint.roc apps use
  *.roc                  setting types, checked values, lowering to the IR
  host/, build.zig       Zig host, built into targets/{x64musl,arm64mac}/libhost.a
  targets/               linker inputs; all but libhost.a are vendored (see its README)
  ir-release             the released IR bundle URL a platform release uses
blueprint-ir-package/    roc-blueprint-ir: semantic IR, shared validation, Value and codec
  Project.roc            pure normalization, references and provider capability checks
  fuzz/                  roc-fuzz targets: ir-parse, ir-round-trip
blueprint-nix-package/   importable pure Nix backend (depends only on the IR)
  NixBackend.roc          shared pure request planning and flake rendering
  Locks.roc              validated authority/native Nix lock translation
  build-runner.py        in-derivation argv/output/isolation checks
  tests/                 IR fixtures and golden flakes
blueprint-cli/           the blueprint CLI (basic-cli + weaver)
fixtures/consumer/      independent consumer of the IR and Nix packages
examples/all-settings/   environments, sources, scoped overlays, tasks and Raw
examples/composition/    imported pure module returning reusable task settings
examples/artifacts/      runnable source/dependency/workflow example and scripts
examples/extensions/     Custom blocks; CI checks blueprint refuses them clearly
scripts/                 prepare-basic-cli.sh, test.sh, bundle.sh, fuzz.sh
flake.nix                builds blueprint with the pinned Roc; user and contributor shells
```

The local platform and CLI share `blueprint-ir-package`, including
`Project.validate`. B1 changes the wire format to major 2; published major-1
bundles are not compatible. This is a source-only, not release-qualified
snapshot. Both bundle gates remain required; the unchanged `ir-release` gate
is expected to block until an actual compatible IR artifact is available.
B2 adds compatible IR 2.1 fields; B3 adds IR 2.2 workflows and ordered plans.
See the [B4 handoff API](docs/foundation-api.md),
[exact tested snapshot](docs/foundation-snapshot.md), [B3 workflow contracts](docs/b3.md),
[B2 build/lock contracts](docs/b2.md) and historical [B1 record](docs/b1.md).

## Setup

Full development and CI require x86_64 Linux with Nix and flakes enabled.

```sh
nix develop .#contributor
```

gives Roc (the nightly in `.roc-version`, from
[roc-overlay](https://github.com/roc-lang/roc-overlay)), Zig, `blueprint`,
python3, zstd and git. Nix itself is also needed for `blueprint`.

Run `scripts/prepare-basic-cli.sh` before compiling the CLI directly. It builds
the source-pinned basic-cli platform with Nix and creates the ignored
`.basic-cli` symlink used by `blueprint-cli/main.roc`. `scripts/test.sh` also
runs this setup. The Nix blueprint package includes the platform automatically.

## Building and testing

```sh
scripts/prepare-basic-cli.sh                # basic-cli source + Rust host
(cd blueprint-ir-platform && zig build)      # targets/{x64musl,arm64mac}/libhost.a
roc test blueprint-ir-package/main.roc      # IR round trips and format tests
roc test blueprint-cli/main.roc             # includes the golden flake test
roc build blueprint-cli/main.roc --output=./blueprint
(cd examples/all-settings && ../../blueprint run --help) # try the CLI
./scripts/test.sh                           # everything CI runs
scripts/fuzz.sh 300                         # fuzz each target for 5 minutes
```

`scripts/test.sh` is the full CI entry point: it builds the flake, invokes both
platform bundle modes (see below), and then runs each fuzz target for 30 seconds.
B1's released-IR incompatibility is an expected blocking failure, not a passing
full-suite result; it can prevent later steps from running.
`scripts/test-config.sh` checks valid configurations, imported-module composition,
required settings, duplicates, unknown references, cycles and explicit-provider
tool grammar at compile time. It compares emitted IR for inherited versus inline
environments, omitted versus explicit Auto, and composed versus inline settings.
Both bundle gates retain those assertions against the served platform, plus the
all-settings example; the old released IR cannot yet satisfy the B1 gate.
`python3 scripts/test-cli.py` exercises the built CLI with and without a
configuration, checks validation and help/version handling, and records Nix
argv to verify shell selection and task arguments without entering a shell.
The all-settings integration tests separately run tasks through real Nix.
`scripts/test-b1.sh` executes imported composition tasks with exact argv-byte
assertions and noncommutative overlays in both orders, including inheritance
and an unselected-overlay native failure. `scripts/test-consumer.sh` checks
staged bytes, supplied-lock preservation, scoped overlay evaluation, native
missing-package diagnostics and package-target rejection. Parse fuzzing also
checks successful semantic normalization for idempotence.
`scripts/test-b2.py` adds real offline-capable artifact/dependency/source tests,
including host-file and TCP isolation with positive host controls, fail-closed
runner checks, exact argv, immutable locks, freshness and relocation.
`scripts/test-b3.py` adds real ordered task/build workflows, nested repetitions,
failure stops, snapshot/dependency freshness, repeated locked-source verification,
whole-closure preflight and immutable authority, including out-of-tree layouts.
`scripts/test-update.py` checks local-source preflight and concurrent publication.
Normal execution tests explicitly initialize authority with `update` first.
`scripts/test-handoff.py` verifies the frozen dependency/export manifest, bundles
core/backend/config with one core identity, and checks/builds/runs the consumer
outside this checkout without invoking Blueprint. It runs before the release
bundle gate. The complete artifacts example is executed in a temporary copy by
the B3 integration script.

## Nightly updates

`.github/workflows/update-roc-nightly.yml` checks daily at 13:10 UTC, or on
manual dispatch, using the SHA-pinned reusable workflow from
[roc-automation](https://github.com/lukewilliamboswell/roc-automation).
`.roc-version` remains the compiler pin for CI, releases and the Nix flake;
the shared updater supports this file without `compiler_roots` configuration.

`.github/roc-nightly.json` selects `ci.yml`, whose `nightly_validation` dispatch
runs all of `scripts/test.sh`: tests, CLI execution, Nix builds, both platform
bundle smoke tests and fuzzing. The tag-triggered release workflows are not
dispatched and validation does not publish. A separate Nightly configuration
workflow checks the consumer configuration on pull requests.

The shared controller creates a signed pin-only PR and merges it only after
validation and repository rules pass. The required check for this CI is `test`.
The active main-branch ruleset requires that check from GitHub Actions, strict
up-to-date checks, and pull requests. Keep its required check names aligned
with the validation workflow when changing CI. Once the workflows are on
`main`, manually dispatch the updater and inspect the candidate's validation
results.

The Nix overlay is independently locked. A nightly absent from the locked
overlay will fail Nix validation and cannot auto-merge. Update the `roc-overlay`
input with `nix flake update roc-overlay` once upstream lists that nightly,
then retry the updater. Do not skip the Nix check to accept a compiler bump.

The September 23 nightly (`nightly-2026-09-23-c7852fd`) uses basic-cli
[PR #499](https://github.com/roc-lang/basic-cli/pull/499), pinned to commit
`473caa2cc4f3fe9ce4e4682158bb80ebc2e19169` in `flake.nix` and `flake.lock`.
This source includes both [PR #495](https://github.com/roc-lang/basic-cli/pull/495)
(implicit error unions) and [PR #498](https://github.com/roc-lang/basic-cli/pull/498)
(the SQLite inference-hang workaround); #495 alone is insufficient.
As of September 24, 2026, no published basic-cli release includes both fixes;
0.23.0-rc1 remains the newest prerelease and stalls with this compiler.
Keep the reproducible source pin until a compatible release is published.
The pinned source passes the CLI and imported platform tests. Nix builds its
Rust host for x64musl on Linux and arm64mac on macOS using the upstream Rust
toolchain version and locked Cargo dependencies.
The Rust host is reused across Roc nightly updates.

The complete suite requires x86_64 Linux, Zig 0.16 and a running Nix daemon. To test the CLI alone on macOS,
check out that exact basic-cli commit, run `python3 scripts/build.py` there,
and link its `platform` directory at `.basic-cli` in this repository. Then
run the CLI unit tests and build with the September 23 Roc binary. The native
CLI can run on macOS, but executing a Blueprint.roc still requires the
blueprint platform's Linux target.

## The IR

`roc Blueprint.roc` prints the IR as an S-expression: records are
`((field value) ...)`, lists `(a b)`, tags `Tag` or `(Tag payload ...)`, and
`;` starts a comment. `blueprint-ir-package/Ir.roc` documents every field.

In outline:

- `format` — `((major 2) (minor 2))`; see compatibility below.
- `name`, `systems` (strings such as `"x86_64-linux"`).
- `sources` — `{ name, provider }`, where provider is `Auto`,
  `NixPackages(Str)` or `GuixPackages(Str)`. Validation supplies
  `{ name: "default", provider: Auto }` if omitted; it does not select a backend.
- `inputs` — `{ name, url, kind }`, where kind is `Overlay` or `Flake`.
- `environments` — `{ name, parents, tools, overlays }`; tools are
  `{ source, name }`, overlays are ordered input names. Validation resolves a
  single parent, deduplicates parent-first selections and clears `parents`.
- `shells` — `{ name, environment }` aliases.
- `tasks` — `{ name, environment, run }`, with nonempty executable argv.
- `build_sources` — `{ name, ref }`, locked non-flake sources, separate from
  package-provider `sources`.
- `builds` — `{ name, environment, inputs, needs, run, output }`; named source
  and build references, exact argv and contained relative file/directory output.
- `workflows` — `{ name, steps }`; typed `RunTask(Str, List(Str))`,
  `BuildArtifact(Str)` or `RunWorkflow(Str)` steps, with ordered bounded expansion.
- `raw` — `{ backend, target, value }`, passed through to one backend.
- `extensions` — `{ kind, name, value }`, blocks a backend may understand.
- `requires` — features the config uses beyond the core (`"raw"`,
  `"extensions"`, `"sources"`, `"builds"`, `"workflows"`), so an older `blueprint` can say what's missing.

`Value` is `Str`, `Int`, `Bool`, `List` or `Attrs`. Its S-expression encoder
and parser are hand-written to avoid recursive-codec derivation problems.
`requires` is reserved in Roc; the Roc field is `requires_`, and `Sexpr` drops
a trailing `_` on the wire. There is no major-1 shell `packages` field in B1.

`Lower.lower` checks authoring-setting cardinality and calls `Project.validate`
as a top-level constant. The CLI calls that same semantic validator after
`Ir.parse` and required-feature checks, so external IR does not bypass reference
or graph rules. `Ir.parse` rejects other majors before decoding nested records;
parsing alone does not establish semantic validity.

Static checks cover generic references, duplicates, inheritance cycles, argv
and provider-specific tool grammar when a source is explicit. `Auto` grammar is
checked after explicit backend selection, before staging effects. Package
existence and target availability are Nix runtime checks. Core validation never
probes the host or installs/fetches anything.

### Compatibility

- The decoder accepts the same `major`, whatever the `minor`; consumers must
  still reject unsupported required features and semantically invalid data.
- **Minor** (compatible): a new optional top-level field (missing fields
  default to empty, unknown ones are ignored), or a new `requires` feature.
- **Major** (breaking): anything else, such as a new required field, a new
  field inside a nested record, or a new `kind` tag.

### Backends

`Request`, `Plan` and `Layout` are importable pure core types.
`NixBackend.plan(project, request, target, layout, locks)` derives
an ordered `Plan.steps` sequence, each holding action, files, exact argv, artifact
metadata and materialization operations. `Request.Workflow(name)` uses the same
atomic planner as standalone tasks/builds. Execute each step's operations, stage
its files, then invoke its argv; stop immediately on failure. The entire plan
must succeed before effects. See [actual exports and limits](docs/b3.md).
The caller owns all effects; no backend registry or serialized config recipes
are involved. `Backend.roc` retains only inspection metadata. Nix is the only
implemented backend. It:

- resolves Auto to its default nixpkgs source, without backend autodetection;
- imports each selected environment's package sources per system with only
  that environment's ordered overlay stack; aliases and task entries share it;
- checks provider compatibility for the requested environment/build closure, not
  unrelated valid source/environment declarations. `render` selects all
  shell/task/build environments; `render_environment` selects one. Whole-project
  structure, required features, declared targets and Nix Raw remain checked;
- emits native package attributes without translation, fallback or availability
  filtering: missing/unavailable packages fail in Nix;
- rejects unsupported Nix target declarations and restricts build requests to
  x86_64 Linux. Other supported output shapes are not execution evidence;
- renders `raw` for backend `"nix"` at `shell:<alias>` and `flake` as data,
  rejecting invalid targets, duplicate attributes and managed-field overrides.
  Alias Raw does not affect other aliases or tasks; other backends' Raw is inert;
- refuses any `extensions` and advertises `"raw"`, `"sources"`, `"builds"` and
  `"workflows"`;
- builds ordinary derivations with exact argv, filtered project snapshots,
  read-only declared sources/artifacts and checked file/directory outputs.

`Project.check_environment(project, Nix | Guix, name)` is a pure compatibility
check. Guix source intent, native tool grammar and overlay-capability rejection
are modeled; no Guix renderer, task implementation or executor exists. The
reference CLI explicitly selects Nix; selection policy belongs to consumers.

The source package exports `NixBackend` and `Locks`, without importing the CLI
or an effectful platform. `Locks.decode` validates the versioned authority and
native Nix graph; `Locks.derive` validates declaration/ordered-overlay identity
and translates local project-relative paths into a disposable working lock.
`NixBackend.plan` uses that translation. The former opaque-text `render_files`
seam was removed, not retained as a bypass. `scripts/test-consumer.sh` compiles
an independent app using these APIs, including caller-selected paths, decoded
supplied authority and exact argv. `scripts/test-b2.py` separately proves actual
relocated local-source translation.

`gen`, `shell`, `run`, `build` and `workflow` require existing matching authority. Only
explicit `update` resolves new pins and publishes authority; normal commands
stage derivatives and prohibit native lock updates. Named input declarations
remain stable across selected closures; selected overlays remain scoped and
ordered. Local authority contains relative identity and NAR hashes, not checkout
paths. Dirty local inputs fail until explicit update. See [B2](docs/b2.md) for
the complete lock, snapshot, output and isolation contracts. B3 repeats local
verification and fresh snapshot operations per explicit build, never reusing
artifact results by name across tasks. B4 provides a source-only handoff;
the released-IR gate remains a release blocker. Keep this staging repository
usable until the later port passes acceptance.

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
`examples/all-settings/Blueprint.roc` against it, plus the shared configuration
and composition regressions. Keep both gates:

```sh
scripts/bundle.sh platform
scripts/bundle.sh platform "$(< blueprint-ir-platform/ir-release)"
```

The committed `ir-release` still names `ir-0.2.0`, whose major-1 schema is
incompatible with B1's major 2 and shared `Project` export. Its gate is expected
to fail until a real compatible IR artifact is published and the pin deliberately
updated. Do not skip it, substitute a local URL for the release check, or invent
a release. Local-IR success permits a source-only snapshot, not a release-qualified
platform. The [B0 validation record](docs/foundation-validation.md) describes
historical major-1 results, not a passing B1 release gate.

The two packages need separate tags: Roc identifies a package by its URL
minus the version and hash, so two bundles under one tag look like one
package served with two hashes.

Update the basic-cli source revision in `flake.nix` and refresh its lock input
when adopting a newer commit. Switching back to a released platform is blocked
on publication of a release containing both #495 and #498; the committed Nix
source build does not require that release or a machine-local override.
Once published, restore the release URL in `blueprint-cli/main.roc`, add the
same archive URL and verified hash to `rocPackages` in `flake.nix`, and remove
the source-host build and unused flake inputs (refresh `flake.lock`). Rerun
`scripts/test.sh`, including both bundle variants, before adopting that release.
If you change the weaver URL, update `rocPackages` in `flake.nix` to match.

## Upstream workarounds

Compile-time configuration lowering is restored with Roc
`nightly-2026-09-23-c7852fd`: `roc check Blueprint.roc` now rejects whole-config
errors, including a missing `Name` or duplicate shells. Older compilers
crashed while bundling a top-level constant dependent on the app's `config`;
the local-IR and released-IR bundle tests guard against that regression.
`blueprint check` retains a compiler check for diagnostics and reuses the IR
already loaded for CLI parsing, rather than running the configuration again.
The loaded IR is still needed for shared semantic validation and backend
compatibility checks. Runtime validation also protects consumers from external
IR; it does not make major-1 platforms compatible with the B1 CLI. Loading the
IR still executes Roc, so retain compiler provisioning in the Nix wrapper and
support for the `ROC` override.

These remaining dependencies and workarounds still apply:

- **Pinned Roc and basic-cli.** `.roc-version` selects the compiler and the
  `basic-cli-src` flake input selects compatible platform source. Replace this
  temporary source dependency when a compatible basic-cli release is available.
- **`roc bundle --output-dir` must be on the same filesystem as the working
  directory.** Otherwise the bundler fails with `CrossDevice`.
- **Error unions in `blueprint-ir-package/Sexpr.roc` use a named extension
  (`..others`).** These preserve open error types without the compiler
  warning about a redundant bare `..`.
