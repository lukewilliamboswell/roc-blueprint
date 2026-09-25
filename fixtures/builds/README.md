# B2 real build gate

Run from the contributor shell after building the platform host and root CLI:

```sh
roc build blueprint-cli/main.roc --output=./blueprint
python3 scripts/test-b2.py
```

The runner copies the listed fixture inputs into a temporary project and renders
`Blueprint.roc.in` with the local platform and the immutable nixpkgs revision
already recorded in `fixtures/consumer/inputs.lock`. It never changes repository
pins. Every Nix subprocess is transparently logged and executed with
`--offline`; the pinned source and Python/stdenv/Bash/coreutils closures must
already be cached. Missing cache entries fail, not skip. Dependency provisioning
is separate from user build-command networking. Remote builders are disabled.

Only x86_64 Linux execution is supported by this gate. It requires a real Nix
store/daemon with effective build sandboxing; merely accepting `sandbox = true`
is not counted as evidence. The isolation build gets a unique nonce each run so
an old cached result cannot satisfy the assertion. The same marker-file and TCP
listener probes must pass as real host tasks before and after that build.
The marker is outside the project, readable, and never declared as an input.

Assertions cover:

- exact binary file and directory outputs, diamond dependencies and metadata;
- literal argv including empty strings, quotes, newlines and shell injections;
- actual failed writes to source files/directories and dependency outputs;
- filtered local inputs, VCS metadata, authority, workspace and generated roots;
- fresh snapshots after untracked edits, task-generated files and deletion;
- missing and symlink output failures with no successful artifact publication;
- immutable lock bytes, inode, mode and mtime for ordinary commands, including
  real shell entry, task execution and builds; no implicit Nix lock commands;
- missing locks and dirty local sources rejected before staging, followed by a
  successful explicit update;
- unsupported dependency provider rejected before any backend/staging effects,
  and an actual native Nix missing-package failure;
- relocated authority and rebased derivative locks with out-of-tree workspaces,
  generated files and unrelated invocation cwd; identical final store artifact.

Failures retain the temporary project and numbered argv/stdout/stderr logs.
Set `B2_KEEP_TMP=1` to retain passing runs too. The fixture does not test Guix
execution, workflows, cross-compilation or release qualification.
