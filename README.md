# roc-blueprint

<p align="center">
  <img src="docs/blueprint-gemini-gen.jpeg" alt="Blueprint illustration of robotic arms" width="560">
</p>

Describe a project's development environments, the commands that run in them,
its sandboxed builds and its ordered workflows in one typed file,
`Blueprint.roc`. The `blueprint` command realises that file through Nix, from
pins the project commits, so a contributor's machine and a CI runner get the
same tools.

**[Read the manual](https://lukewilliamboswell.github.io/roc-blueprint/)** ·
[Latest release](https://github.com/lukewilliamboswell/roc-blueprint/releases/latest)

```roc
# Blueprint.roc at the repository root
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/<version>/<hash>.tar.zst" }

config = [
	Name("my-project"),
	Overlay("roc", "github:roc-lang/roc-overlay"),
	Environment("base", [Tools(["git", "zig"])]),
	Environment("dev", [
		Extend("base"),
		Tools(["rocpkgs.nightly", "python3", "sqlite"]),
		Overlays(["roc"]),
	]),
	Shell("default", [Use("dev")]),
	Task("version", [Use("dev"), Run(["python3", "--version"])]),
]
```

```sh
blueprint update         # resolve the inputs and write Blueprint.lock
blueprint shell          # enter the default shell's environment
blueprint run version    # run the task's command in dev
```

[Get started](https://lukewilliamboswell.github.io/roc-blueprint/getting-started.html)
has this file with the latest release's platform URL filled in, and each
release's notes give its own.

## Install

`blueprint` needs [Nix](https://nixos.org/download) with flakes enabled, and
nothing else. Each
[release](https://github.com/lukewilliamboswell/roc-blueprint/releases/latest)
attaches a binary for x86_64 Linux, arm64 Linux and Apple Silicon macOS, with
SHA-256 sums in `blueprint.sha256`. Or run it from the flake:

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
