# Linker inputs

The `roc-blueprint` platform links a fully static musl executable. Roc reads
each target's inputs from `targets/<target>/`, as listed in `../main.roc`:

| Target               | Built here (`zig build`) | Fetched                                              |
|----------------------|--------------------------|------------------------------------------------------|
| x64musl, arm64musl   | `libhost.a`              | `crt1.o`, `libc.a`, `libzigc.a`, `libcompiler_rt.a`  |
| arm64mac, x64mac     | `libhost.a`              | none                                                 |

None of these files is committed. The fetched ones come from an immutable
[roc-platform-template-zig](https://github.com/lukewilliamboswell/roc-platform-template-zig)
linker-input release, selected by content in
[`link-inputs.lock.json`](../../link-inputs.lock.json) at the repository root.
From the repository root:

```sh
scripts/link_inputs.roc fetch   # download if not cached, verify, install
scripts/link_inputs.roc check   # verify what is installed, without the network
```

`fetch` keeps the release manifest and `link-inputs-all.tar` in
`.cache/link-inputs/<archive sha256>/`. On every run, whether or not they were
already there, it:

1. validates the lock, whose release name must be `link-inputs-sha256-` followed
   by the manifest's SHA-256;
2. checks the manifest's SHA-256 and that it pins the same archive as the lock;
3. recomputes the archive's size and SHA-256 before reading any member;
4. reads the archive itself, accepting only regular files with safe, unique
   relative names and bounded count and size;
5. checks every member against the archive's `dependency.json`, with nothing
   undeclared and nothing missing;
6. stages the files it needs, then moves them into `targets/` and
   `../linker-inputs/` (the licences and `dependency.json`, which
   `scripts/bundle.roc` ships in the platform bundle).

Any difference stops the run with a message naming it. A cached file that no
longer matches is removed and the run fails; run `fetch` again to download it.
Nothing falls back to another release or a local build, and no signing or
attestation service is consulted: the reviewed lock is the authority.

## Adopting a different release

Replace `link-inputs.lock.json` with the `link-inputs.lock.json` asset of the
new release, byte for byte, and run `scripts/link_inputs.roc fetch` and
`scripts/test.roc`. That is a dependency change: review the release, its source
revision and its provenance before merging, as described in roc-automation's
[artifact verification guide](https://github.com/lukewilliamboswell/roc-automation/blob/main/docs/artifact-verification.md).
