# Roc Blueprint

An early-stage pair of Roc packages for describing blueprints and rendering them for Nix.

## Packages

- `blueprint` exposes the placeholder `Plan` data structure.
- `blueprint-nix` depends on `blueprint` and currently exposes a small placeholder renderer.

## Example

Run the example app with:

```sh
roc examples/hello.roc
```

It uses [roc-platform-template-zig 1.0.0](https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/tag/1.0.0) and prints a value produced using both packages.

The expected output is:

```text
{ field1 = "hello from roc-blueprint"; field2 = 42; }
```

## Development

Enter the Nix development shell with `nix develop`, or use direnv. Run all checks with:

```sh
./ci/all_tests.sh
```
