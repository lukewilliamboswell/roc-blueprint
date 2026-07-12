# Roc Blueprint

Two pure Roc packages for describing portable development environments and rendering them as Nix flakes.

## Packages

- `blueprint` owns portable requirements, target systems, environments, construction, and validation.
- `blueprint-nix` depends on `blueprint`, validates exact Nix bindings, and deterministically renders a complete flake through a typed Nix expression tree.

Neither package performs effects or invokes Nix.

## Development-shell example

Generate the maintained development-shell example:

```sh
roc examples/dev-shell.roc > flake.nix
nix flake lock
nix flake check
nix develop --command rustc --version
```

The example declares abstract `rust-compiler`, `cargo`, and `git` requirements in the portable Blueprint. Its Nix configuration binds those identities explicitly to `nixpkgs` package paths.

The renderer includes the final newline. The example uses the platform's line operation after removing that newline, so the resulting stdout remains byte-identical to [the golden flake](examples/dev-shell.golden.nix).

## Development

Run the pure package, example, bundle, and golden-output checks with:

```sh
./ci/all_tests.sh
```

With Nix installed, run the complete end-to-end acceptance test with:

```sh
./ci/test_nix_example.sh
```

That test checks repeat generation, the committed lockfile, `nix flake check`, and availability of `rustc` inside the generated development shell.

See [design.md](design.md) for the architecture, boundaries, and later phases.
