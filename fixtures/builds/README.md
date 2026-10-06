# Real build gates

Run from the repository root, in the development shell (`nix develop`), after building the
platform host and the CLI:

```sh
roc build blueprint-cli/main.roc --output=./blueprint
scripts/test_builds.roc
```

The suite (`scripts/src/BuildGates.roc`, on the harness in
`scripts/src/BuildHarness.roc`) copies the fixture files into a temporary
project and renders `Blueprint.roc.in` with the local platform and the pinned
inputs. The tasks and builds of the fixture are Roc scripts on basic-cli, run
as `roc-stable <script>.roc -- ARGS` in an environment that declares that one
compiler and the two bundles the scripts need through `RocPackages`. Roc takes
the first `--` of its arguments for itself, so every command has one before
the script's own arguments.

## Pins and the network

Nothing floats. nixpkgs is the revision already recorded in
`fixtures/consumer/inputs.lock`; the Roc overlay revision, the compiler it
provides and the two Roc bundles are recorded with their hashes in
`fixtures/roc-inputs.lock.json`. The suite never changes either file.

The suite starts with one step that may use the network: it builds
`fixtures/warm.nix`, which fetches each pinned source by its hash and realises
the compiler and the other store paths the fixtures need, and then fetches
each reference as the fixtures spell it and compares the hash Nix reports
with the committed one. After that step every Nix call goes through a
recording `nix` (`fixtures/recording-nix/main.roc`, built once per run and put
first on `PATH`) that notes its arguments, adds `--offline` and runs the real
Nix. A store path missing after the first step is a failure, not a skip.
`--offline` stops Nix from using a binary cache and from refreshing what it
has already downloaded; it does not cut the network off.

Every command runs with a private `XDG_CACHE_HOME` inside the temporary
directory, so the Roc packages a task publishes never reach your own cache.
Only Nix's download cache there is yours, through a link, so that a source
fetched once is not fetched again by every run. Remote builders are disabled.

## What is checked

Only x86_64 Linux execution is supported. The suite needs a real Nix store
and daemon with effective build sandboxing; merely accepting `sandbox = true`
is not counted as evidence. The isolation build gets a unique token each run,
so an old cached result cannot satisfy the assertion. The same marker-file and
TCP probes (`probe.roc`) must pass as real host tasks before and after that
build: the marker is outside the project, readable by anyone and never
declared as an input, and the suite itself answers the listener while the
build runs. In the build the marker must be "not found" and the connection
must be refused, denied, unroutable or time out.

Assertions cover:

- exact binary file and directory outputs, diamond dependencies and metadata;
- literal argv including empty strings, quotes, newlines and shell injections;
- actual failed writes to source files/directories and dependency outputs;
- filtered local inputs, VCS metadata, authority, workspace and generated roots;
- fresh snapshots after untracked edits, task-generated files and deletion,
  and the first artifact again once the project holds its first bytes again;
- what Nix copies from the project, compared with a ledger the suite keeps
  for itself: bytes, the owner's execute bit and non-UTF-8 names preserved,
  symlinks and special files refused at any depth, excluded entries never
  inspected;
- the production runner on the host: fail-closed isolation before any effect,
  the source-farm policy, exit codes, a signal, the declared `PATH` and output
  checks;
- undeclared tools not found in a real build: a tool of another environment,
  a shell and a coreutils program;
- missing and symlink output failures with no successful artifact publication;
- immutable lock bytes, inode, mode and mtime for ordinary commands, including
  real shell entry, task execution and builds; no implicit Nix lock commands;
- missing locks and dirty local sources rejected before staging, followed by a
  successful explicit update;
- relocated authority and rebased derivative locks with out-of-tree workspaces,
  generated files and unrelated invocation cwd; identical final store artifact;
- a source fetched over HTTP whose archive holds a symlink, refused by the
  sandboxed runner before the build's command runs, and accepted without it.

A build's `PATH` holds only what its environment declares, and the suite
checks that with commands that are not Roc. A Roc script sees more: the Roc
compiler's package puts coreutils and a C compiler on the `PATH` of whatever
it runs. `build.roc` therefore checks only that it can find no shell.

Two things the earlier suite checked are checked elsewhere: an unsupported
provider in a build's dependency closure, refused before any effect, by the
workflow suite (`fixtures/workflows`) and the `NixProvider.roc` expects; and a
missing native package, by `scripts/test-consumer.sh` and the overlay scenario
in `scripts/test-b1.sh`.

Failures keep the temporary project and numbered argv/stdout/stderr logs and
say where. Set `BLUEPRINT_TEST_KEEP_TMP=1` to keep a passing run's too. The
fixture does not test Guix execution, workflows, cross-compilation or release
qualification.
