# Examples

These examples use the platform in this repository and Spec 2.5, not the latest
published platform. Each directory keeps its
`Blueprint.roc` and related files together.

- [all-settings](all-settings/Blueprint.roc): Auto and explicit Nix package
  sources, a named overlay scoped to `dev`, parent-first environment inheritance,
  shell aliases, argv tasks, a locked Roc package and raw Nix settings. `ci` uses `base` without that
  overlay. `scripts/test_scenarios.roc` runs this app through the CLI and
  `scripts/bundle.roc` against a platform bundle.
- [composition](composition/Blueprint.roc): imports
  [ProjectTasks.roc](composition/ProjectTasks.roc), whose pure
  `settings : EnvName -> List(Config.Setting)` function supplies `fmt`, `test`
  and `args` tasks. The app concatenates them into `config`; all use `dev` directly.
  Inherited `git` is deduplicated before child `python3`. These tasks print tool
  versions or JSON argv; they do not format files or run a test suite. No plugin registration,
  generated CLI, implicit tool installation or runtime code loading is involved.
- [artifacts](artifacts/Blueprint.roc): a complete local locked source,
  sandboxed library/app dependency pair, and typed task/build workflow.
  [Usage and output](artifacts/README.md) include explicit update and read-only
  source/artifact locations. Its integration smoke runs in a temporary copy.
- [extensions](extensions/Blueprint.roc): custom extension blocks and raw
  values. The platform emits these, and the CLI reports unsupported extensions.

After building the CLI and platform host (see [contributing](../CONTRIBUTING.md)),
run on x86_64 Linux from the repository root:

```sh
roc check examples/all-settings/Blueprint.roc
roc check examples/composition/Blueprint.roc
roc check examples/artifacts/Blueprint.roc
(cd examples/all-settings && ../../blueprint check)
(cd examples/composition && ../../blueprint update)
(cd examples/composition && ../../blueprint run fmt)
(cd examples/composition && ../../blueprint run test)
(cd examples/composition && ../../blueprint run args -- 'two words' '' '--literal')
scripts/test_config.roc
scripts/test_scenarios.roc
```

`scripts/test_config.roc` checks the imported composition module and compares
its emitted Spec with the same settings written inline; `scripts/bundle.roc`
repeats that against the served platform bundle.
The extensions example intentionally fails `blueprint check` with an
unsupported-features error.

Only explicit `update` initializes or changes `Blueprint.lock`. Ordinary
`gen`, `shell`, `run`, `build` and `workflow` require matching pins and preserve
that authority; generated `.blueprint/flake.lock` is a derivative. Example locks
and generated files are ignored here; commit the authority in your own project.
See [the architecture](../docs/architecture.adoc).
