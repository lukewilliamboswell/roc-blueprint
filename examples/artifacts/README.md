# Locked sources and dependent artifacts

From the repository's contributor shell, build the local platform host and CLI
as described in [CONTRIBUTING](../../CONTRIBUTING.md), then:

```sh
cd examples/artifacts
roc check Blueprint.roc
../../blueprint update
../../blueprint build app
../../blueprint workflow ci
```

`update` explicitly initializes `Blueprint.lock` (or deliberately updates it).
Normal builds/workflows preserve that authority. The implicit default package
source is Auto; the reference Nix consumer selects nixpkgs. Package names such
as `python3` remain backend-native, not a universal tool catalog.

`build app` builds `library` first. Its stdout is the artifact path resolved by
the planned Nix command, not `dist/app.txt` in your checkout. Read that printed
path; its exact initial bytes are:

```text
Artifact example
HELLO FROM THE WORKING TREE
```

`workflow ci` runs the ordinary `check` task, then builds `app`. It prints
`source checked` followed by the resolved artifact path. Tasks do **not**
automatically receive artifact paths; declared dependency access is build-only.

The library reads `src/message.txt` from a fresh filtered working-tree snapshot.
The app reads locked `assets/heading.txt` through `BLUEPRINT_INPUTS/assets` and
exactly the library's declared file through `BLUEPRINT_ARTIFACTS/library`.
Those are separate read-only locations, not files merged into the writable
build directory. Editing `src/message.txt` affects the next explicit build,
including untracked/task-generated changes. Editing `assets` instead requires
another explicit `update`; a dirty locked source fails rather than falling
back to its current working-tree bytes.

## Limits

- Source-only local platform reference; no compatible platform release is
  claimed. Loading configuration still invokes the pinned runtime Roc compiler.
- Verified builds require local x86_64 Linux and a sandbox-enabled Nix daemon.
  Fetching pinned tools/sources is separate from sandboxed build execution;
  initial update/tool provisioning may need network access.
- Compilation and tasks are not sandboxed. Only builds use the isolated runner.
- Project snapshots, source inputs and outputs reject all symlinks and special
  files. Ordinary project files, including untracked ones, enter the snapshot;
  keep secrets outside it. VCS metadata, authority, generated workspace and
  declared local source trees are excluded.
- Serialize shared-workspace use and avoid concurrent source mutation. There
  is no cross-step artifact-name cache, automatic update, or rollback.

The B3 integration gate runs a **temporary copy** of this complete example,
substituting only its local platform location and a supplied existing fixture
package revision. It checks real build/workflow bytes and immutable authority;
checked-in example files and repository pins are never updated by that smoke.
