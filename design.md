# Roc Blueprint Design

## Status and purpose

This document defines the intended direction for two pure Roc packages:

- `roc-blueprint`, which lets Roc programs construct and validate a portable
  description of reproducible development environments and build work; and
- `roc-blueprint-nix`, which consumes that description plus explicit Nix
  bindings and renders a Nix flake.

The first release is a concept validation, not a complete build system. It
must prove that an ordinary Roc application can construct a useful portable
description, pass it to an ordinary Roc backend package, print the resulting
Nix source through an existing CLI platform, and use that source with normal
Nix commands.

This document is forward-looking. Examples illustrate the desired boundaries
and vocabulary; they do not commit the initial implementation to exact Roc
syntax or function names.

## Summary

The architecture has three responsibilities:

```text
Roc application
    |
    | ordinary pure Roc composition
    v
roc-blueprint
    | Blueprint: explicit, validated portable data
    v
roc-blueprint-nix
    | deterministic Nix expression rendering
    v
flake.nix
    |
    v
Nix evaluator, store, builders, caches, and CLI
```

`roc-blueprint` owns the meaning of the portable description.
`roc-blueprint-nix` owns the exact mapping from supported Blueprint concepts
to Nix. Nix remains responsible for flake input locking, evaluation,
derivation construction, realization, the store, substituters, remote
builders, and garbage collection.

Neither package performs effects. A Roc application supplies the effects by
using `basic-cli` or another platform to write the rendered source to stdout or
a file:

```sh
roc run my_blueprint.roc > flake.nix
nix flake lock
nix develop
```

Diagnostics must not be mixed into the generated stdout stream. The
application may render structured errors to stderr through its platform.

## Terminology

- **Blueprint**: the complete portable value constructed by an application.
- **Node**: one named item in a Blueprint, such as an environment, build step,
  check, source, or output.
- **Edge**: an explicit dependency from one node to another.
- **Requirement**: a portable declaration that a node needs an external tool
  or facility. A requirement does not itself say how Nix or Guix provides it.
- **Backend binding**: backend-specific data that maps a portable requirement
  or target to a concrete backend value.
- **Renderer**: a pure function that converts a validated Blueprint and its
  backend bindings into source text.
- **Realization**: execution performed by Nix, Guix, or another build system.
  Rendering a Blueprint is not realization.

The name “graph” describes part of the representation, but the public value is
called a Blueprint because it contains more than dependency edges: it also
contains targets, environments, requirements, declared outputs, and metadata.

## Design principles

### Pure packages, effectful applications

Both packages must be ordinary pure Roc packages. They must not:

- read or write files;
- inspect environment variables;
- execute commands;
- access the network, clock, process state, or host system;
- invoke Nix; or
- depend on a particular Roc platform.

All such work belongs to the application and its platform. Given equal values,
the package functions must return equal results.

### Explicit data crosses every boundary

A Blueprint must contain every dependency and target relationship required to
understand it. A renderer must not recover missing relationships from names,
command text, output paths, or collection order. Missing or contradictory data
is an error reported by the responsible package.

The application may use arbitrary Roc functions to construct a Blueprint, but
the completed Blueprint is closed data. It must not contain application
closures that a backend must execute to discover nodes, dependencies, target
conditions, or package mappings.

This property preserves the option to serialize, inspect, visualize, diff, or
pass a Blueprint directly to a future platform.

### One-way dependency

`roc-blueprint-nix` depends on `roc-blueprint`. `roc-blueprint` must never
depend on `roc-blueprint-nix` or contain Nix expression fragments, Nix
attribute paths, NixOS options, or flake concepts.

Other backend packages must be able to consume the same public Blueprint
without importing Nix code:

```text
roc-blueprint-nix   -> Nix
roc-blueprint-guix  -> Guix
future platform     -> direct inspection or execution
```

### Portability is a defined intersection

Portable concepts must have documented meaning independent of any backend.
The project must not call a feature portable merely because two renderers can
produce superficially similar text.

A backend that cannot faithfully represent a requested portable concept must
return a structured unsupported-feature error. It must not omit the concept,
approximate it, or silently change its meaning.

Backend-native features live in backend-owned configuration passed alongside
the Blueprint. They do not enter the portable package as raw strings or an
open-ended backend extension field.

### Deterministic output

Validation and rendering must be independent of hash-map iteration, filesystem
order, locale, current system, and process state. Ordering rules must be part
of each data contract:

- ordered user-facing lists preserve declared order where that order has
  meaning;
- sets and maps are rendered in a documented stable order; and
- errors are returned in a documented stable order.

The same package versions and equal input values must produce byte-identical
Nix source.

This guarantee concerns Blueprint processing and source generation. It does
not by itself guarantee that every Nix build is bit-for-bit reproducible;
realization has additional requirements owned by the generated Nix and its
builders.

### Safe source generation

`roc-blueprint-nix` must lower to a typed internal Nix expression tree before
printing text. User data must never be inserted by unescaped string
concatenation. The printer owns string escaping, identifier quoting,
precedence, indentation, and final newline policy.

The initial public API must not accept arbitrary raw Nix source. If native Nix
composition is added later, it should use explicit Nix expression types or
imports whose trust boundary is visible in the API.

Safe escaping prevents source injection through data fields; it does not make
an intentionally declared builder trustworthy. A Blueprint can describe a
command that deletes data, leaks secrets, or produces nondeterministic output.
The application and realization backend retain responsibility for deciding
which descriptions and builders they trust.

## `roc-blueprint`

### Responsibilities

The package must provide:

- opaque identity types for different node categories so unrelated identities
  cannot be accidentally interchanged;
- constructors and combinators for assembling a Blueprint;
- explicit target selection;
- explicit requirement declarations;
- explicit dependency edges;
- validation that does not depend on a backend;
- stable, structured validation errors; and
- inspection functions sufficient for backend packages to consume the
  validated result without breaking package opacity.

Validation must eventually cover at least:

- unique node identities within their category;
- references to declared nodes and requirements;
- duplicate or contradictory output declarations;
- dependency cycles where the portable model requires a DAG;
- empty or invalid target sets;
- incompatible target relationships; and
- fields required by the portable meaning of each node kind.

Validation should accumulate independent errors when doing so is unambiguous.
It must not continue from one invalid value by inventing replacement data.

### Portable model

The long-term portable model is expected to include:

- supported target systems;
- immutable or content-identified sources;
- external tool requirements;
- build steps with explicit inputs, commands, environment, and outputs;
- named build outputs;
- development environments;
- checks;
- applications or runnable commands; and
- dependency edges between those values.

The initial implementation includes only the subset needed by its acceptance example.
Unimplemented concepts should be absent from the API rather than represented
by placeholders with unclear meaning.

### Target model

Targets are explicit data, not strings interpreted by a backend. The first
phase may support a small closed set such as `x86_64-linux`, `aarch64-linux`,
`x86_64-darwin`, and `aarch64-darwin`. Before widening that set, the project
must decide whether targets are best represented as known values or as a
structured architecture/OS/ABI description.

A backend owns the exact mapping from a supported Blueprint target to its
native target name. Unknown mappings are errors.

### Requirement model

Portable requirements identify roles, not ecosystem package coordinates. For
example, an environment can require a tool identified as `rust-compiler` or
`git`, but `roc-blueprint` does not claim that a string such as `cargo`
universally identifies the same package in Nixpkgs and Guix.

The application supplies backend bindings separately:

```text
Blueprint requirement `rust-compiler`
    -> Nix binding: input `nixpkgs`, package path `rustc`
    -> future Guix binding: a Guix package identity
```

Requirement identities must be exact. A backend must not perform fuzzy package
search or guess a package from a display name.

Bindings may be target-specific. For every requirement used by an environment
on a target, the Nix configuration must supply exactly one applicable binding.
A missing or overlapping binding is an error. Initially, a binding supplied
to a project but used by no environment on any declared target is also an error;
this catches misspelled identities and accidental configuration drift.

### API shape

The intended flow is conceptually:

```roc
draft = Blueprint.workspace({...})

validated : Result(Blueprint.Valid, List(Blueprint.Error))
validated = Blueprint.validate(draft)
```

Whether invalid intermediate states are representable is an implementation
choice. The public API must make it impossible to call a backend renderer as if
an invalid Blueprint were valid.

## `roc-blueprint-nix`

### Responsibilities

The package must provide:

- Nix flake input declarations;
- exact bindings from Blueprint requirements to Nix package expressions;
- exact mappings from supported Blueprint targets to Nix system strings;
- validation of Nix-specific names, paths, bindings, and representability;
- lowering from a validated Blueprint into a typed Nix expression tree;
- deterministic formatting of that tree as a complete flake; and
- structured errors tied back to Blueprint identities where possible.

The conceptual API is:

```roc
render : Blueprint.Valid, Nix.Config -> Result(Str, List(Nix.Error))
```

`Nix.Config` is backend data. It may declare flake inputs and bind portable
requirements to exact expressions such as a package from an input's package
set for the current system.

### Nix ownership boundary

The package produces conventional Nix source. It does not:

- generate or modify `flake.lock`;
- evaluate the resulting expression;
- verify that remote input URLs exist;
- query Nixpkgs for package names;
- build derivations;
- enter development shells;
- copy store paths; or
- implement the Nix store or evaluator.

Those operations remain ordinary Nix operations invoked by the surrounding
application, shell, or future platform.

### Rendering contract

For supported inputs, rendering must either return a complete flake or a
structured error. It must not return a partially valid flake with unsupported
nodes omitted.

The generated source must:

- contain a generated-file notice;
- declare every referenced flake input exactly once;
- emit only declared target systems;
- expose supported values through conventional flake output names;
- use stable formatting and ordering;
- escape all application-supplied text correctly; and
- end with one newline.

The renderer should expose the typed Nix tree separately from text formatting
once doing so is useful for testing or composition. Text is the only required
output in the initial implementation.

## Initial implementation: end-to-end concept validation

### Goal

Prove the smallest useful path from pure Roc data to a working Nix flake. The
phase validates the package boundary and user workflow; it does not validate
the complete long-term build model.

### Scope

The initial implementation supports:

- one Blueprint workspace;
- one or more explicitly declared target systems;
- one named development environment;
- a list of abstract tool requirements for that environment;
- one `nixpkgs` flake input declared in `Nix.Config`;
- exact Nix package bindings for every requirement;
- lowering to `devShells.<system>.<name>`; and
- deterministic rendering of a complete `flake.nix`.

Supporting a single default environment first is acceptable if the data model
does not make multiple named environments impossible.

### Illustrative application

```roc
blueprint =
    Blueprint.workspace({
        name: "example",
        targets: [Blueprint.x86_64_linux],
        environments: [
            Blueprint.environment({
                name: "default",
                requires: [rust_compiler, cargo, git],
            }),
        ],
    })

nix =
    Nix.config({
        inputs: [Nix.github_input("nixpkgs", "NixOS/nixpkgs", "nixos-unstable")],
        requirements: [
            Nix.package(rust_compiler, "nixpkgs", ["rustc"]),
            Nix.package(cargo, "nixpkgs", ["cargo"]),
            Nix.package(git, "nixpkgs", ["git"]),
        ],
    })

source = Blueprint.validate(blueprint)? |> Nix.render(nix)?
Stdout.write!(source)
```

The exact syntax may change. The separation must not: portable requirements
are declared in the Blueprint and resolved explicitly in Nix configuration.
The platform write operation must emit the returned string exactly; because the
renderer includes the final newline, a line-printing operation must not append a
second one.

### Acceptance test

One maintained example must demonstrate:

```sh
roc run examples/dev-shell.roc > flake.nix
nix flake lock
nix flake check
nix develop --command rustc --version
```

The test succeeds when:

- generation needs no custom platform or compiler change;
- the generated file parses and evaluates as a flake;
- every requirement has exactly one Nix binding;
- the requested command is available in the development environment;
- rerunning generation produces byte-identical `flake.nix`; and
- invalid fixtures produce stable structured errors rather than Nix source.

The example's locked inputs make its Nix evaluation repeatable. The renderer
does not itself produce the lockfile.

The clean-checkout test harness must supply a known Roc compiler and exact
package versions. The initial implementation does not yet make the generator bootstrap through the
flake it generates. The generated-file notice must make the generator package
versions explicit inputs when the example knows them.

### Explicit exclusions

The initial implementation does not include:

- build steps or multi-node build DAGs;
- source fetching or content hashes;
- packages, apps, or checks flake outputs;
- NixOS or Home Manager modules;
- overlays;
- arbitrary Nix expressions;
- imports of handwritten Nix modules;
- Guix;
- a dedicated CLI or platform;
- direct execution of a Blueprint; or
- a stable serialized Blueprint format.

These exclusions keep the first result capable of disproving the architecture
quickly and cheaply.

### Falsification criteria

The initial implementation is successful only if its small result provides evidence for the split,
not merely a working Nix template. The design must be revised before Stage 2
if any of the following occurs:

- the Blueprint package needs to expose a Nix attribute path, flake output, or
  Nix expression to describe the environment;
- `Nix.Config` must repeat environment structure instead of only supplying
  backend-owned inputs and requirement bindings;
- the renderer needs to inspect display names or generated text to discover
  targets or requirements;
- adding a second named environment requires changing the meaning of the first;
  or
- the same Blueprint cannot be inspected and rendered by a trivial test
  consumer that has no Nix dependency.

## Short-term goals

After the initial implementation proves the boundary, the short-term objective is a useful
portable build graph rather than a larger catalog of Nix conveniences.

### Build nodes and outputs

Add build steps with explicit:

- identities;
- target systems;
- source and dependency inputs;
- tools;
- command and argument values;
- environment variables;
- declared output names; and
- edges to other build outputs.

Commands are data. They are not shell text from which dependencies or outputs
are inferred. If shell execution is supported, it is an explicit command mode
with documented quoting and portability limits.

Before these types become public, Stage 2 must define their execution contract:
working directory, environment inheritance, network availability, writable
paths, failure status, output discovery, sandbox assumptions, and the meaning
of a target system. Nix and Guix must not receive two different meanings from
one underspecified command node.

### Nix build lowering

Map the portable build subset to ordinary Nix derivations and expose named
results through `packages` and `checks`. The Nix package must report any
portable operation it cannot represent exactly.

### Composition

Allow Roc modules and packages to contribute Blueprint fragments whose
identities and dependencies are combined explicitly. Composition must detect
collisions rather than letting the last value win.

### Developer workflow

Provide example applications for stdout generation and safe file replacement.
Atomic file replacement, stale-file checking, and invoking `nix` belong to an
application or later CLI, not the pure packages.

## Long-term goals

### A backend-neutral reproducible description

Grow the portable model only from concepts demonstrated by at least one
backend and defined independently of it. The goal is a useful shared model, not
the union of every backend's native language.

### A second backend

Implementing `roc-blueprint-guix` is the decisive portability test. It should
happen only after the Nix backend supports real build nodes, but before the
portable API is declared stable. Any concept that cannot retain the same
meaning across the two backends must be narrowed, moved to backend
configuration, or explicitly marked unsupported.

### Backend-native composition

Support advanced Nix and Guix ecosystems without polluting the portable
Blueprint. Likely Nix additions include typed Nix expressions, flake imports,
overlays, NixOS modules, and backend-owned output declarations. These values
must remain visibly backend-specific.

### Stable inspection and serialization

Once the model has survived multiple backends, define a versioned serialized
form if real use cases require caching, interchange, visualization, or tools
written outside Roc. The in-memory Roc API must not accidentally become a wire
format.

### A Blueprint platform

A future Roc platform may require an application to provide a Blueprint and
may inspect, render, visualize, or realize it directly. This platform should
consume the same package-defined value. It must not require applications to
rewrite their build descriptions.

The pure-package workflow remains valuable even after such a platform exists:
it is simple, inspectable, and usable with any existing platform capable of
writing text.

## Roadmap and decision gates

### Stage 0: vocabulary and fixtures

- Write representative Roc examples before fixing the public API.
- Define Blueprint identities, targets, requirements, and environment data.
- Define validation error categories and deterministic ordering.
- Define the minimal typed Nix expression tree and printer contract.

Gate: the example can be expressed without a Nix concept appearing in
`roc-blueprint`.

### Stage 1: minimal development shell

- Implement the initial subset in both packages.
- Add unit tests for construction, validation, binding completeness, escaping,
  and deterministic formatting.
- Add the maintained end-to-end Nix example and golden generated source.

Gate: the initial acceptance test passes from a clean checkout.

### Stage 2: real build graph

- Define the portable process, filesystem, source, and declared-output
  contracts before exposing build-node constructors.
- Add sources, build nodes, outputs, checks, and explicit dependency edges.
- Add cycle and reference validation.
- Lower the supported subset to Nix derivations, packages, and checks.
- Test a multi-node build in which one output is an input to another.

Gate: no renderer infers dependencies from command strings, paths, or names,
and Nix realizes the graph successfully.

### Stage 3: composition and practical Nix interoperability

- Compose Blueprint fragments from Roc packages.
- Reference existing flake inputs and selected handwritten Nix modules through
  explicit Nix-owned APIs.
- Add apps and richer development environments where their portable meaning is
  clear.
- Establish release/versioning policy for both packages.

Gate: an existing Nix project can adopt a generated output incrementally
without surrendering its lockfile, caches, or native modules.

### Stage 4: second-backend pressure test

- Prototype `roc-blueprint-guix` against the same build fixtures.
- Record which concepts transfer exactly, which require backend bindings, and
  which are Nix-specific.
- Revise the still-pre-stable portable API from this evidence.

Gate: at least one nontrivial multi-node Blueprint is realized by both
backends with the same documented dependency and output meaning.

### Stage 5: platform and ecosystem

- Explore a platform that consumes Blueprint values directly.
- Add visualization, explanation, safe generation, and realization tooling as
  separate effectful layers.
- Consider a versioned interchange format only after concrete consumers exist.

Gate: applications using the package-defined Blueprint need no description
rewrite to use the platform.

## Testing requirements

### `roc-blueprint`

- Constructor and composition tests.
- Stable error tests for every validation rule.
- Duplicate identity, unknown reference, and cycle tests.
- Determinism tests across different construction orders where order is
  declared irrelevant.
- Generated small typed graph tests once build nodes exist; avoid a catalog of
  handwritten graph scenarios.

### `roc-blueprint-nix`

- Nix expression printer tests for strings, paths, identifiers, lists,
  attribute sets, function application, and precedence.
- Golden tests for complete generated flakes.
- Requirement-binding tests: missing, duplicate, unused where prohibited, and
  wrong-target bindings.
- Stable ordering and byte-for-byte repeat rendering tests.
- End-to-end tests using `nix flake check`, `nix eval`, and `nix develop` or
  `nix build` for maintained examples.
- Negative tests proving unsupported Blueprint nodes return errors and are not
  omitted.

Pure unit tests must not require Nix. Nix integration tests belong to the Nix
package's integration suite and CI environment.

## Compatibility and evolution

The packages should remain pre-1.0 while the second-backend test is pending.
Before 1.0:

- public constructors may change when a portability claim is disproved;
- generated Nix formatting may change deliberately with golden updates;
- release notes must distinguish source-compatible API changes from generated
  output changes; and
- the package version used to generate a file should appear in its header when
  that version is available as explicit renderer input.

After a serialized format exists, its version is separate from the Roc package
API version and the generated Nix formatting version.

## Non-goals

The project is not initially:

- a replacement for Nix or Guix;
- a new store, evaluator, scheduler, or sandbox;
- a universal package-name registry;
- a transpiler from arbitrary Roc functions to Nix functions;
- a parser or formatter for existing Nix source;
- a guarantee that arbitrary builders are deterministic;
- a NixOS deployment system; or
- justification for compiler changes.

## Risks and open questions

### The portable core may be too small

If every useful project needs backend-native configuration, the Blueprint adds
little value. Stage 2 must test real dependency graphs, not only development
shells.

### The portable core may absorb Nix accidentally

Package attribute paths, flake output names, Nix strings with interpolation,
and NixOS module rules are tempting conveniences. They must remain in
`roc-blueprint-nix` unless they can be defined and tested independently.

### Requirement binding may be too indirect

Abstract requirements create portability but add configuration. Examples must
test whether explicit bindings remain understandable at realistic sizes.
Reusable backend binding libraries may reduce repetition without moving the
bindings into the portable core.

### Identity and composition may conflict

Human-readable global string identities are convenient initially but are
fragile when independent Roc packages contribute fragments. Display names and
node identity must remain separate. Before Stage 3, the project must choose an
explicit namespacing or composition-owned identity scheme; it must not resolve
collisions by module name guessing or last-writer-wins replacement.

### Target vocabulary may not generalize

Nix system strings do not fully describe every backend's target model. The
initial closed target set is intentionally provisional.

### Build-step meaning may not be portable

An argument list alone does not define a reproducible process. Nix and Guix can
differ in sandbox policy, available filesystem roots, environment setup,
network access, multi-output handling, and cross-compilation roles. Stage 2's
execution contract is a design gate. Features without one shared meaning must
move into backend-owned configuration rather than acquire vague portable
fields.

### Text generation may become the accidental API

Consumers may begin depending on formatting details or editing generated files.
Generated files must clearly identify their source, and composition should move
toward typed backend values rather than textual substitution.

### Nix interoperability has a boundary

A portable graph cannot express every lazy Nix function, overlay, or module
without reproducing Nix itself. Complete access to the Nix ecosystem therefore
requires explicit Nix-owned composition alongside the portable Blueprint. The
project must describe that boundary honestly.

### Bootstrapping can become circular

Nix evaluation cannot assume it may execute the Roc generator. The initial
workflow generates `flake.nix` before Nix evaluates it. Projects may commit the
generated file and verify it is current in CI. Import-from-derivation is not a
default architecture.

### Generated source can be mistaken for a security boundary

A typed Nix printer prevents malformed quoting and accidental source injection,
but it does not validate the behavior of declared commands or imported Nix.
Documentation and future tooling must distinguish source safety, evaluation
purity, sandboxing, and builder trust.

## Success criteria

The concept succeeds when:

- useful build and environment descriptions are ordinary pure Roc values;
- backend packages consume explicit data without reconstructing intent;
- the Nix renderer produces conventional flakes usable by ordinary Nix tools;
- generation is deterministic and safely escaped;
- backend limitations are explicit errors;
- a second backend can reuse the portable graph without importing Nix
  concepts; and
- a future platform can consume the same Blueprint type without forcing
  applications to rewrite their descriptions.

The concept should be reconsidered if the smallest honest portable model is
too weak for real projects, or if useful Nix lowering consistently requires
placing Nix-specific meaning inside `roc-blueprint`.
