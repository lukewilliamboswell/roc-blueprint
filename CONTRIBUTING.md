# Contributing to roc-blueprint

## Layout

```
blueprint-platform/   the roc-blueprint platform that Blueprint.roc apps use
  *.roc                  setting types, checked values, lowering to the Spec
  host/, build.zig       Zig host, built into targets/<target>/libhost.a
  targets/               linker inputs, none committed: libhost.a is built, the rest fetched (see its README)
  core-release           (when present) the released core bundle URL a platform release uses
blueprint-core/          roc-blueprint-core: Spec, Provider contract, validation, Steps, Value, codec
  Project.roc            pure normalization, references and provider capability checks
  fuzz/                  roc-fuzz targets: spec-parse, spec-round-trip
blueprint-nix/           importable pure Nix provider (depends only on blueprint-core)
  NixProvider.roc        shared pure request planning and flake rendering
  Locks.roc              Nix pins <-> the Lock: Sources plus a "nix" hint
  tests/                 Spec fixtures and golden flakes
blueprint-cli/           the blueprint CLI (basic-cli + weaver); as `blueprint __build-runner`
                         it is also each build's in-derivation argv/output/isolation check
fixtures/consumer/       independent consumer of the Spec and Nix packages
examples/all-settings/   environments, sources, scoped overlays, tasks and Raw
examples/composition/    imported pure module returning reusable task settings
examples/artifacts/      runnable source/dependency/workflow example and scripts
examples/extensions/     Custom blocks; CI checks blueprint refuses them clearly
scripts/                 test.sh, bundle.sh, fuzz.sh, link_inputs.roc, test_roc_packages.roc (Roc scripts share scripts/src/)
link-inputs.lock.json    the linker-input release the platform links, pinned by content
flake.nix                builds blueprint with the pinned Roc; user and contributor shells
```

The local platform and CLI share `blueprint-core`, including
`Project.validate`. The Spec wire format is major 2 (currently 2.5); published
major-1 bundles are not compatible. The architecture, terminology (Spec,
Provider, Lock, stages) and invariants are defined in
[docs/architecture.adoc](docs/architecture.adoc); keep it in sync with changes.

## Setup

Full development and CI require x86_64 Linux with Nix and flakes enabled.

```sh
nix develop .#contributor
```

gives Roc (the nightly in `.roc-version`, from
[roc-overlay](https://github.com/roc-lang/roc-overlay)), Zig, `blueprint`,
python3, zstd, git and curl. Nix itself is also needed for `blueprint`.

`blueprint-cli/main.roc` uses the released basic-cli platform by URL. Roc
downloads it on first use outside Nix; the Nix blueprint package fetches the same
archive by hash, so its sandboxed build needs no network.

## Building and testing

```sh
scripts/link_inputs.roc fetch             # the musl runtime files the platform links
(cd blueprint-platform && zig build)      # targets/<target>/libhost.a for all four hosts
roc test blueprint-core/main.roc      # Spec round trips and format tests
roc test blueprint-cli/main.roc             # includes the golden flake test
roc build blueprint-cli/main.roc --output=./blueprint
(cd examples/all-settings && ../../blueprint run --help) # try the CLI
./scripts/test.sh                           # everything CI runs
./scripts/test.sh unit cli                  # or only some groups
scripts/fuzz.sh 300                         # fuzz each target for 5 minutes
```

The platform's linker inputs are not committed. `scripts/link_inputs.roc fetch`
downloads the release pinned in `link-inputs.lock.json` into `.cache/link-inputs/`,
verifies it and installs the files beside `libhost.a`; nothing that evaluates a
`Blueprint.roc` against the local platform links without them. It is a Roc
script: run it from the repository root with the pinned `roc` on `PATH`, or as
`"$ROC" scripts/link_inputs.roc fetch`. `scripts/link_inputs.roc check` verifies
what is installed without the network. See
[blueprint-platform/targets/README.md](blueprint-platform/targets/README.md).

`scripts/test.sh` is the full CI entry point: it fails if an object file, archive
or import library is tracked, fetches and verifies the linker inputs, builds the flake, invokes both
platform bundle modes (see below), and then runs each fuzz target for 30 seconds.
`scripts/test-config.sh` checks valid configurations, imported-module composition,
required settings, duplicates, unknown references, cycles and explicit-provider
tool grammar at compile time. It compares emitted Spec for inherited versus inline
environments, omitted versus explicit Auto, and composed versus inline settings.
Both bundle gates retain those assertions against the served platform, plus the
all-settings example.
`scripts/test_cli.roc` exercises the built CLI with and without a
configuration, checks validation and help/version handling, and records Nix
argv to verify shell selection and task arguments without entering a shell.
It holds what only a run can show: the order of checks before any effect, how
often the configuration is evaluated, exact provider argv and error text. Rules
that a pure `expect` in `blueprint-core` or `blueprint-nix` already holds are
not repeated there.
The all-settings integration tests separately run tasks through real Nix.
`scripts/test-b1.sh` executes imported composition tasks with exact argv-byte
assertions and noncommutative overlays in both orders, including inheritance
and an unselected-overlay native failure. `scripts/test-consumer.sh` checks
staged bytes, supplied-lock preservation, scoped overlay evaluation, native
missing-package diagnostics and package-target rejection. Parse fuzzing also
checks successful semantic normalization for idempotence.
`scripts/test-b2.py` adds real offline-capable artifact/dependency/source tests,
including host-file and TCP isolation with positive host controls, fail-closed
runner checks, exact argv, immutable locks, freshness and relocation. It also
checks what Nix copies from the project (bytes, the owner's execute bit, raw
names, exclusions, refused symlinks and special files) and that an undeclared
tool is not found. It runs `blueprint __build-runner` directly on the host for
the checks that need no sandbox, with a hand-written witness naming namespaces
the host does not have.
`scripts/test-b3.py` adds real ordered task/build workflows, nested repetitions,
failure stops, snapshot/dependency freshness, repeated locked-source verification,
whole-closure preflight and immutable authority, including out-of-tree layouts.
`scripts/test-update.py` checks local-source preflight, authority observation and
concurrent publication. `scripts/test-isolation.py` checks what a build stages
about its caller: the namespace identities, the CLI's own path as the runner,
and the refusals when either cannot be used. Both put a failing
`python3` on `PATH`: the CLI itself must not use a host Python.
`scripts/test_roc_packages.roc` is a Roc script, like `link_inputs.roc`. It
runs the real CLI and Nix with a Roc package cache of its own in a temporary
directory, and refuses to run if that directory lies inside `~/.cache`. It
checks publication into an empty cache, that a second run writes nothing, that
an existing package is left alone and an incomplete one replaced, that failures
leave nothing behind, and that a sandboxed build resolves its bundles with no
network while the same build without one of them does not.
Normal execution tests explicitly initialize authority with `update` first.
The complete artifacts example is executed in a temporary copy by
the workflow integration script (`scripts/test-b3.py`).

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

The October 4 nightly (`nightly-2026-10-04-130536d`) rejects redundant type
exposes, so it needs the basic-cli 0.24.0 release and roc-fuzz 0.4.3.

The complete suite requires x86_64 Linux, Zig 0.16 and a running Nix daemon. To test the CLI alone on macOS,
run the CLI unit tests and build with the pinned Roc binary. The native
CLI can run on macOS, but executing a Blueprint.roc still requires the
blueprint platform's Linux target.

## The Spec

`roc Blueprint.roc` prints the Spec as an S-expression: records are
`((field value) ...)`, lists `(a b)`, tags `Tag` or `(Tag payload ...)`, and
`;` starts a comment. `blueprint-core/Spec.roc` documents every field.

In outline:

- `format` — `((major 2) (minor 5))`; see compatibility below.
- `name`, `systems` (strings such as `"x86_64-linux"`).
- `sources` — `{ name, provider }`, where provider is `Auto`,
  `NixPackages(Str)` or `GuixPackages(Str)`. Validation supplies
  `{ name: "default", provider: Auto }` if omitted; it does not select a provider.
- `inputs` — `{ name, url, kind }`, where kind is `Overlay` or `Flake`.
- `environments` — `{ name, parents, tools, overlays }`; tools are
  `{ source, name }`, overlays are ordered input names. Validation resolves a
  single parent, deduplicates parent-first selections and clears `parents`.
- `system_tools` — optional `{ environment, system, tools }` selections. They
  inherit parent first and only enter the environment on their named System.
- `commands` — optional `{ environment, name, tool }` launchers. Validation
  flattens inheritance; a child replaces a same-named inherited command.
- `roc_packages` — optional `{ environment, name, source }`: a Roc bundle's
  content hash and the `build_sources` entry that fetches it. The platform
  derives both from the bundle URL (`roc-<hash>`, `tarball+<url>`);
  environments sharing a bundle share one source. Validation flattens
  inheritance, parent first.
- `shells` — `{ name, environment }` aliases.
- `tasks` — `{ name, environment, run }`, with nonempty executable argv.
- `build_sources` — `{ name, ref }`, locked non-flake sources, separate from
  package-provider `sources`.
- `builds` — `{ name, environment, inputs, needs, run, output }`; named source
  and build references, exact argv and contained relative file/directory output.
- `workflows` — `{ name, steps }`; typed `RunTask(Str, List(Str))`,
  `BuildArtifact(Str)` or `RunWorkflow(Str)` steps, with ordered bounded expansion.
- `raw` — `{ backend, target, value }`, passed through to one provider (the
  wire field keeps the name `backend`).
- `extensions` — `{ kind, name, value }`, blocks a provider may understand.
- `requires` — features the config uses beyond the core (`"raw"`,
  `"extensions"`, `"sources"`, `"builds"`, `"workflows"`, `"system-tools"`, `"commands"`, `"roc-packages"`), so an older `blueprint` can say what's missing.

`Value` is `Str`, `Int`, `Bool`, `List` or `Attrs`. Its S-expression encoder
and parser are hand-written to avoid recursive-codec derivation problems.
`requires` is reserved in Roc; the Roc field is `requires_`, and `Sexpr` drops
a trailing `_` on the wire. There is no major-1 shell `packages` field.

`Lower.lower` checks authoring-setting cardinality and calls `Project.validate`
as a top-level constant. The CLI calls that same semantic validator after
`Spec.parse` and required-feature checks, so external Spec does not bypass reference
or graph rules. `Spec.parse` rejects other majors before decoding nested records;
parsing alone does not establish semantic validity.

Static checks cover generic references, duplicates, inheritance cycles, argv
and provider-specific tool grammar when a source is explicit. `Auto` grammar is
checked after explicit provider selection, before staging effects. Package
existence and target availability are Nix runtime checks. Core validation never
probes the host or installs/fetches anything.

### The Lock

`Blueprint.lock` is a `blueprint-core/Lock.roc` value in the same S-expression
codec, with its own `format` (currently 1.0) and the same compatibility rules
as the Spec. It holds `intent` (the parts of the Spec Resolve consumed: source
and input declarations, build sources and per-environment overlay order), which
the CLI records on `update` and compares before every other command, failing
with what changed; `sources` (one provider-neutral `{ name, provider, ref,
rev, digest }` per declared input; `digest` is `sha256:<hex>`: the Nix
provider converts its NAR hashes for remote inputs, and local inputs carry
Blueprint's own tree digest from core `Tree`) and provider-namespaced
`hints`. The Nix provider's hint carries its declared input identity and the
complete native lock graph; decoding rejects a lock whose Sources disagree with
those pins, so hand edits to either side fail. Older JSON locks are not
migrated: run `blueprint update`. `scripts/lockfile.py` reads locks in tests,
and `fuzz/lock-parse` fuzzes the parser.

### Compatibility

- The decoder accepts the same `major`, whatever the `minor`; consumers must
  still reject unsupported required features and semantically invalid data.
- **Minor** (compatible): a new optional top-level field (missing fields
  default to empty, unknown ones are ignored), or a new `requires` feature.
- **Major** (breaking): anything else, such as a new required field, a new
  field inside a nested record, or a new `kind` tag.

### Providers

`Request`, `Steps` and `Layout` are importable pure core types.
`NixProvider.plan(project, request, target, layout, locks)` derives
an ordered `Steps.steps` sequence, each holding action, files, exact argv, artifact
metadata and materialization operations. `Request.Workflow(name)` uses the same
atomic planner as standalone tasks/builds. Execute each step's operations, stage
its files, then invoke its argv; stop immediately on failure. The entire plan
must succeed before effects.
The caller owns all effects; no provider registry or serialized config recipes
are involved. `blueprint-core/Provider.roc` is the Core/Provider contract:
`preflight`, `realise` (Steps from the Lock text), `resolve` plus
`lock_from_native` (what to stage and run to produce new pins) and `render`.
The CLI uses only that record; `scripts/test.sh` fails if it reaches into a
provider's modules directly. Nix is the only implemented provider. It:

- resolves Auto to its default nixpkgs source, without provider autodetection;
- imports each selected environment's package sources per system with only
  that environment's ordered overlay stack; aliases and task entries share it;
- checks provider compatibility for the requested environment/build closure, not
  unrelated valid source/environment declarations. `render` selects all
  shell/task/build environments; `render_environment` selects one. Whole-project
  structure, required features, declared targets and Nix Raw remain checked;
- emits native package attributes without translation, fallback or availability
  filtering: missing/unavailable packages fail in Nix. Explicit `system_tools`
  select packages for their named System before Nix evaluates them. Each
  `commands` entry becomes a package holding one launcher that execs the
  tool's main program;
- makes `roc_packages` available without a download. A shell or task step
  carries a `RocPackages` operation naming the environment's bundles and a
  `locate` argv (`nix eval --json` of the generated flake's
  `blueprintRocPackages.<environment>` output, with the staged lock read-only),
  which prints where each locked bundle is unpacked. The executor publishes the
  missing ones into Roc's package cache and runs `locate` only when one is
  missing. A build's specification instead lists the bundles and a `ln`, and
  `blueprint __build-runner` links them into a cache inside the build directory
  and sets `XDG_CACHE_HOME` for the build's command. There is no shell hook;
- rejects unsupported Nix target declarations and restricts build requests to
  x86_64 Linux. Other supported output shapes are not execution evidence;
- renders `raw` for backend `"nix"` at `shell:<alias>` and `flake` as data,
  rejecting invalid targets, duplicate attributes and managed-field overrides.
  Alias Raw does not affect other aliases or tasks; other providers' Raw is inert;
- refuses any `extensions` and advertises `"raw"`, `"sources"`, `"builds"`,
  `"workflows"`, `"system-tools"`, `"commands"` and `"roc-packages"`;
- builds ordinary derivations with exact argv, filtered project snapshots,
  read-only declared sources/artifacts and checked file/directory outputs. Each
  is a raw `derivation` whose builder is the CLI's own executable, run as
  `blueprint __build-runner`: no shell or interpreter stands between Nix and
  the user's argv, and the build's PATH is its environment's tools alone.

`Project.check_environment(project, Nix | Guix, name)` is a pure compatibility
check. Guix source intent, native tool grammar and overlay-capability rejection
are modeled; no Guix renderer, task implementation or executor exists. The
reference CLI explicitly selects Nix; selection policy belongs to consumers.

The source package exports `NixProvider` and `Locks`, without importing the CLI
or an effectful platform. `Locks.decode` parses the Lock, checks that its Sources match the
"nix" hint's pins, and validates the native Nix graph; `Locks.derive` validates declaration/ordered-overlay identity
and translates local project-relative paths into a disposable working lock.
`NixProvider.plan` uses that translation. The former opaque-text `render_files`
seam was removed, not retained as a bypass. `scripts/test-consumer.sh` compiles
an independent app using these APIs, including caller-selected paths, decoded
supplied authority and exact argv. `scripts/test-b2.py` separately proves actual
relocated local-source translation.

`gen`, `shell`, `run`, `build` and `workflow` require existing matching authority. Only
explicit `update` resolves new pins and publishes authority; normal commands
stage derivatives and prohibit native lock updates. Named input declarations
remain stable across selected closures; selected overlays remain scoped and
ordered. Local authority contains relative identity and Blueprint tree digests
(core `Tree`, computed and verified by the CLI without Nix), not checkout
paths. Dirty local inputs fail until explicit update. Local verification, caller
observation and Nix's filtered project copy repeat per explicit build, never reusing artifact results
by name across tasks.

A new feature usually means: a setting in the platform (`Config.roc`,
`Lower.roc`), then either an `extensions` kind or a new optional Spec field
(a minor bump), then support in a provider. Prototyping it as `Raw` or `Custom`
first needs no Spec change at all.

## Releasing

roc-blueprint and roc-blueprint-core have independent release cycles.

- **roc-blueprint-core:** push a tag like `core-X.Y.Z`. `release-core.yml` tests
  and bundles `blueprint-core/` and publishes release `core-X.Y.Z` with the bundle.
- **roc-blueprint:** put the core bundle URL the platform should use in
  `blueprint-platform/core-release`, set `version` in `blueprint-cli/main.roc`
  and `flake.nix` to the release, then push a tag like `X.Y.Z`. `release.yml`
  runs the tests, cross-builds the `blueprint` binaries on Linux with
  `scripts/build-release.sh`, runs each on its own kind of machine with
  `scripts/smoke-binary.sh`, and only then publishes release `X.Y.Z` with the
  platform bundle, the binaries and their sha256 sums.

A binary fetches the compiler named in `.roc-version` from the roc-overlay
revision in `NixProvider.roc_overlay`. Change that constant whenever
`flake.lock` moves the `roc-overlay` input; `scripts/test.sh` fails when the two
differ.

A tag with a `-` in it (e.g. `X.Y.Z-rc1`) is published as a pre-release.

During development the platform uses `core: "../blueprint-core/main.roc"`. `roc bundle`
only packs files below the entry point's directory, so `scripts/bundle.sh
platform <core-url>` bundles a staged copy whose `core:` is the given URL. With
no URL it bundles the local `blueprint-core/` and serves it from localhost. Either way
it then serves the platform bundle from localhost and runs
`examples/all-settings/Blueprint.roc` against it, plus the shared configuration
and composition regressions. There are two gates:

```sh
scripts/bundle.sh platform
scripts/bundle.sh platform "$(< blueprint-platform/core-release)"
```

Before bundling the platform, `scripts/bundle.sh` runs
`scripts/link_inputs.roc check`, so only linker inputs matching
`link-inputs.lock.json` are packed. Their licences and `dependency.json`
inventory go into the bundle under `linker-inputs/`, and `release.yml` records
the linker-input release and the lock's SHA-256 in the release notes.

`scripts/test.sh` runs the first on every commit. `release.yml` runs the second
when a platform release is tagged, and the release fails if the pinned core
cannot build the platform. A change that adds a Spec field therefore merges
with the existing pin; publish a `core-X.Y.Z` release containing the field and
update `core-release` before tagging the next platform release. Do not
substitute a local URL for the release check.

The two packages need separate tags: Roc identifies a package by its URL
minus the version and hash, so two bundles under one tag look like one
package served with two hashes.

To adopt a newer basic-cli release, change the URL in `blueprint-cli/main.roc`
and `fixtures/consumer/main.roc`, then update the matching entry in `rocPackages`
in `flake.nix` with the new URL and hash (`nix store prefetch-file <url>`). Add
any new transitive dependency to the same list. Rerun `scripts/test.sh` and the
pinned-core bundle gate.
If you change the weaver URL, update `rocPackages` in `flake.nix` to match.

## Upstream workarounds

Compile-time configuration lowering is restored with Roc
`nightly-2026-09-23-c7852fd`: `roc check Blueprint.roc` now rejects whole-config
errors, including a missing `Name` or duplicate shells. Older compilers
crashed while bundling a top-level constant dependent on the app's `config`;
the local-Spec and released-Spec bundle tests guard against that regression.
`blueprint check` retains a compiler check for diagnostics and reuses the Spec
already loaded for CLI parsing, rather than running the configuration again.
The loaded Spec is still needed for shared semantic validation and provider
compatibility checks. Runtime validation also protects consumers from external
Spec; it does not make major-1 platforms compatible with the current CLI. Loading the
Spec still executes Roc, so retain compiler provisioning in the Nix wrapper and
support for the `ROC` override.

These remaining dependencies and workarounds still apply:

- **Pinned Roc.** `.roc-version` selects the compiler, and the basic-cli
  release in `blueprint-cli/main.roc` must be compatible with it.
- **`roc bundle --output-dir` must be on the same filesystem as the working
  directory.** Otherwise the bundler fails with `CrossDevice`.
- **Error unions in `blueprint-core/Sexpr.roc` use a named extension
  (`..others`).** These preserve open error types without the compiler
  warning about a redundant bare `..`.
