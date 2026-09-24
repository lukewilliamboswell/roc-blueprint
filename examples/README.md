# Examples

These are B1 source examples using the local platform and IR major 2, not
examples for the latest published platform. Each directory keeps its
`Blueprint.roc` and related files together.

- [all-settings](all-settings/Blueprint.roc): Auto and explicit Nix package
  sources, a named overlay scoped to `dev`, parent-first environment inheritance,
  shell aliases, argv tasks and raw Nix settings. `ci` uses `base` without that
  overlay. The integration and bundle scripts exercise this app.
- [composition](composition/Blueprint.roc): imports
  [ProjectTasks.roc](composition/ProjectTasks.roc), whose pure
  `settings : EnvName -> List(Config.Setting)` function supplies `fmt`, `test`
  and `args` tasks. The app concatenates them into `config`; all use `dev` directly.
  Inherited `git` is deduplicated before child `python3`. These tasks print tool
  versions or JSON argv; they do not format files or run a test suite. No plugin registration,
  generated CLI, implicit tool installation or runtime code loading is involved.
- [extensions](extensions/Blueprint.roc): custom extension blocks and raw
  values. The platform emits these, and the CLI reports unsupported extensions.

After building the CLI and platform host (see [contributing](../CONTRIBUTING.md)),
run on x86_64 Linux from the repository root:

```sh
roc check examples/all-settings/Blueprint.roc
roc check examples/composition/Blueprint.roc
(cd examples/all-settings && ../../blueprint check)
(cd examples/composition && ../../blueprint run fmt)
(cd examples/composition && ../../blueprint run test)
(cd examples/composition && ../../blueprint run args -- 'two words' '' '--literal')
scripts/test-config.sh
scripts/test-b1.sh
```

The configuration regression script checks the imported composition module both
locally and when invoked by the bundle smoke tests. It also compares composed
and inline emitted IR. Both bundle gates remain required; the old `ir-release`
pin is expected to block the released-IR variant until an actual compatible
release exists. These source examples are not a release qualification.
The extensions example intentionally fails `blueprint check` with an
unsupported-features error.

Commands that generate a shell write `.blueprint/` and sync `Blueprint.lock`
inside the example directory. Ordinary `gen`, `shell` and `run` still invoke
Nix locking; switching environment closures can change the lock. These test
outputs are ignored here; in your own projects, commit `Blueprint.lock`.
The immutable-lock lifecycle, locked non-flake sources, builds and workflows
remain deferred to B2/B3. See [B1 boundaries](../docs/b1.md).
