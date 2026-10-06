# Real workflow gates

Run from the repository root, in the contributor shell, after building the
platform host and the CLI:

```sh
roc build blueprint-cli/main.roc --output=./blueprint
scripts/test_workflows.roc
```

The suite (`scripts/src/BuildWorkflowGates.roc`, on the harness in
`scripts/src/BuildHarness.roc`) renders `Blueprint.roc.in` into a temporary
project, checks it through `blueprint check`, and explicitly initializes
authority with `blueprint update`. The platform is local. The pins, the one
step that may use the network, the recording `nix` that adds `--offline` to
every later call and the private `XDG_CACHE_HOME` are those of the build
suite: see [its README](../builds/README.md). Real sandboxed builds require
x86_64 Linux and an effective Nix sandbox. Tasks deliberately run on the host.

The tasks and builds are Roc scripts on basic-cli, run as
`roc-stable <script>.roc -- ARGS`.

The representative `ci` workflow is a task → build → task. Additional workflows
exercise nested/repeated tasks with literal empty, quoted, multiline and
shell-looking argv; task and build failures; and repeated artifact operations.
The fixture library embeds current source bytes, and its dependent app publishes
an exact binary payload, dependency store path and build argv. The suite checks
those bytes independently, not just command success or metadata.

Assertions also cover:

- Full task/build order in both real-process records and CLI stdout. The
  recording `nix` and each task leave a record in one directory outside the
  project, named by the time, so observations do not change the snapshotted
  project or defeat caching.
- A build → source-editing task → same build refreshes both the app and its
  library dependency. Unchanged repeated builds retain the same store path.
- Task/build failures prevent all subsequent task and build invocations.
- A later nested task with an unsupported provider, or a later build with an
  unsupported transitive dependency, fails before any marker, Nix call or
  staging mutation. These negative configs change only the relevant Use.
- A task dirtying a locked source between builds causes the later build to fail
  without publishing the previously cached artifact as a new success.
- Empty and nested-empty workflows succeed with empty stdout, zero Nix calls,
  and unchanged generated/workspace bytes, inode, mode and mtime (including
  directories). Missing authority rejects both no-ops and productive workflows
  before effects. Every ordinary command preserves authority bytes, inode, mode
  and mtime; no implicit Nix lock/update occurs.
- Caller-selected out-of-tree workspace/generated roots work from an unrelated
  invocation directory without a second authority or changed artifact identity.
- A temporary copy of the complete [artifacts example](../../examples/artifacts/README.md),
  changed only in where the platform is and in the pins: explicit update, a
  real build and workflow, exact bytes and immutable authority.

Temporary projects and logs respect `TMPDIR`. Failures keep all files and
numbered argv/stdout/stderr logs; `BLUEPRINT_TEST_KEEP_TMP=1` keeps a passing
run's too. The suite uses no production monkeypatches or mocked compiler or
backend results. It is not Guix, non-Linux, isolation-probe or
release-qualification evidence; the build suite has the host-file and network
isolation probes.
