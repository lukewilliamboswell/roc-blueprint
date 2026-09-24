# Examples

Each example keeps its `Blueprint.roc` and related files in one directory.

- [all-settings](all-settings/Blueprint.roc): package inputs, overlays, shells,
  tasks and raw Nix settings. CI runs the CLI against this example and uses it
  to smoke-test platform bundles.
- [extensions](extensions/Blueprint.roc): custom extension blocks and raw
  values. The platform emits these, and the CLI reports unsupported extensions.

After building the CLI and platform host (see [contributing](../CONTRIBUTING.md)),
run `../../blueprint check` from `all-settings/` on x86_64 Linux. The extensions
example intentionally fails that check with an unsupported-features error.

Commands that generate a shell write `.blueprint/` and `Blueprint.lock` inside
the example directory. These generated test outputs are ignored here; in your
own projects, commit `Blueprint.lock` to share the same tool versions.
