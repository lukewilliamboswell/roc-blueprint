# Contributing to roc-blueprint

The contributor guide is the
[Contribute chapter](https://lukewilliamboswell.github.io/roc-blueprint/contributing.html)
of the manual ([source](docs/contributing.adoc)). It covers the layout of the
repository, what to install, how to build, and what each test group checks.
Releasing and moving a compiler are in the
[Maintain and release chapter](https://lukewilliamboswell.github.io/roc-blueprint/maintaining.html)
([source](docs/maintaining.adoc)).

Use issues for bugs and design discussion, and pull requests for changes.
Before opening a pull request, run from the repository root:

```sh
nix develop -c scripts/test.roc
```

Report a suspected vulnerability privately, as [SECURITY.md](SECURITY.md)
describes.
