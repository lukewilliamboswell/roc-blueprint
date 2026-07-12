# Roc Blueprint

Two pure Roc packages for describing portable development environments and rendering them as Nix flakes.

## Packages

- `blueprint` owns portable requirements, target systems, environments, construction, and validation.
- `blueprint-nix` depends on `blueprint`, validates exact Nix bindings, and deterministically renders a complete flake through a typed Nix expression tree.

Neither package performs effects or invokes Nix.

## Example catalog

Use these as copy-paste starting points for real projects:

1. `examples/hello-shell/main.roc` - minimal hello-world dev shell.
2. `examples/dev-shell/main.roc` - the canonical baseline example.
3. `examples/rust-tooling/main.roc` - Rust tools (`rustc`, `cargo`, `git`).
4. `examples/node-tooling/main.roc` - JavaScript tooling (`nodejs`, `git`).
5. `examples/python-tooling/main.roc` - Python tooling (`python3`, `git`).
6. `examples/dev-and-ci-workflow/main.roc` - multiple environments (`default`, `ci`) in one workspace.
7. `examples/multi-platform-shell/main.roc` - same environment across `x86_64-linux` and `aarch64-darwin`.

Each example is self-contained with its Roc application, golden generated
source, and locked Nix input:

```text
example/
├── main.roc
├── flake.golden.nix
└── flake.lock
```

The applications temporarily declare repository-relative package paths so the
first bundles can be produced. Integration tests never use those paths: they
rewrite temporary copies to content-addressed bundles served over localhost.
After the first release, the checked-in applications can point directly at the
published package bundles.

### How to run an example

From the repo root:

```sh
cd examples/hello-shell
roc main.roc > flake.nix
nix flake check
nix develop --command hello
```

Swap `hello-shell` for any other folder to try the other examples.

For the canonical sample used by the acceptance test, use:

```sh
cd examples/dev-shell
roc main.roc > flake.nix
nix flake check
nix develop --command rustc --version
```

## Development

With Roc and Nix installed, run the complete package, documentation, example,
generated-flake, and bundle checks with:

```sh
./ci/all_tests.sh
```

The test runner recursively discovers every example, bundles both packages,
rewrites the temporary application copies to localhost bundle URLs, and then
checks and tests them. It compares repeat generation with the golden source,
verifies each example's lockfile, runs `nix flake check`, builds the
application, compares compiled stdout, and confirms `rustc` is available from
the canonical development shell.

See [design.md](design.md) for the architecture, boundaries, and later phases.
