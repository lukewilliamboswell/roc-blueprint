# roc-blueprint

<p align="center">
  <img src="docs/blueprint-gemini-gen.jpeg" alt="Blueprint illustration of robotic arms" width="560">
</p>

Describe a project's development environments, the commands that run in them,
its managed artifact builds and its ordered workflows in one typed file,
`Blueprint.roc`. The file says where every program comes from: a download
checked against a digest the project commits, the machine itself, or a pinned
Nix package source. A contributor's machine and a CI runner get the same
tools, and Nix is started only for what a project takes from it.

**[Read the manual](https://lukewilliamboswell.github.io/roc-blueprint/)** ·
[Latest release](https://github.com/lukewilliamboswell/roc-blueprint/releases/latest)

```roc
# Blueprint.roc at the repository root
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/<version>/<hash>.tar.zst" }

import pf.Recipes

config = [
	Name("my-project"),
	Environment("dev", [
		Programs([Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-21-5349569"))]),
		Expect(["git"]),
	]),
	Shell("default", [Use("dev")]),
	Task("version", [Use("dev"), Run(["roc-stable", "version"])]),
	Task("status", [Use("dev"), Run(["git", "status", "--short"])]),
]
```

```sh
blueprint update         # record every download's digest in Blueprint.lock
blueprint run version    # run the task's command in dev
blueprint shell          # enter dev, with roc-stable on PATH
```

This project fetches its compiler, expects `git` of the machine and needs no
Nix. A tool from Nix is written with its source, `Tools(["nix#zig"])`, after
declaring `Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable")))`.
[Get started](https://lukewilliamboswell.github.io/roc-blueprint/getting-started.html)
has this file with the latest release's platform URL filled in, and each
release's notes give its own.

Tasks run your scripts in declared environments. Optional Builds add explicit
inputs, dependencies, an executor and a declared artifact output; compilation
and packaging stay in your scripts. Providers own native execution and caching.
See the [architecture](docs/architecture.adoc) and the [0.8.0 release notes](docs/releases/0.8.0.adoc).

## Install

Each
[release](https://github.com/lukewilliamboswell/roc-blueprint/releases/latest)
attaches a `blueprint` binary for x86_64 Linux, arm64 Linux, Apple Silicon
macOS and x86_64 Windows, with SHA-256 sums in `blueprint.sha256` and build
provenance in `roc-blueprint-provenance.sigstore.json`. It needs no Roc: it embeds
the compiler that reads `Blueprint.roc` and installs it into its cache on first use. [Nix](https://nixos.org/download)
with flakes enabled is needed for tools from a Nix package source and for
sandboxed builds, and where it is installed `blueprint` also runs from the
flake:

```sh
nix run github:lukewilliamboswell/roc-blueprint/<version> -- --help
```

Use each release's binary with that release's platform URL. Intel macOS is not
supported. Sandboxed builds run on x86_64 Linux only.

## Examples

The projects in [examples/](examples/README.md) follow `main` and use the
platform in this repository. To start a project, download the examples
attached to a
[release](https://github.com/lukewilliamboswell/roc-blueprint/releases/latest),
which name that release's platform.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). roc-blueprint is open source under the
[Universal Permissive License 1.0](LICENSE).
