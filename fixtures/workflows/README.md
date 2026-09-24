# B3 real workflow gate

From the contributor shell, after building the platform host and CLI:

```sh
roc build blueprint-cli/main.roc --output=./blueprint
python3 scripts/test-b3.py
```

The runner renders `Blueprint.roc.in` into a temporary project, checks it through
`blueprint check`, and explicitly initializes authority with `blueprint update`.
The platform is local; the immutable nixpkgs revision comes from the existing
`fixtures/consumer/inputs.lock`. Repository pins are never changed. All Nix
calls are logged and then executed with `--offline`; missing cached source/tool
closures fail rather than skip. Real sandboxed builds require x86_64 Linux and
an effective Nix sandbox. Tasks deliberately run on the host.

The representative `ci` workflow is a task → build → task. Additional workflows
exercise nested/repeated tasks with literal empty, quoted, multiline and
shell-looking argv; task and build failures; and repeated artifact operations.
The fixture library embeds current source bytes, and its dependent app publishes
an exact binary payload, dependency store path and build argv. The runner checks
those bytes independently, not just command success or metadata.

Assertions also cover:

- Full task/build order in both real-process logs and CLI stdout. A transparent
  Nix exec logger and tasks append to an external event log, so observations do
  not change the snapshotted project or defeat caching.
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

Temporary projects and logs respect `TMPDIR`. Failures retain all files and
numbered argv/stdout/stderr logs; `B3_KEEP_TMP=1` retains passing runs too.
This gate uses no production monkeypatches or mocked compiler/backend results.
It is not Guix, non-Linux, isolation-probe or release-qualification evidence;
B2 retains the dedicated host-file/network isolation probes.
