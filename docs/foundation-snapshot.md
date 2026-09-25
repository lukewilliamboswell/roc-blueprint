# Tested foundation snapshot

**Source-only handoff:** `0365a2a861bdc846370817866813080a7f3b60c3`

This exact commit contains the implementation, examples, public API manifest and
all handoff tests. This acceptance record is a subsequent documentation-only
commit; it does not change that tested source. Import/vendor the tested source
together, not the incompatible published platform. The later consumer port has
**not** been performed. Keep this staging repository usable until that port's
acceptance gates pass.

- [Public API / execution contract](foundation-api.md)
- [Compiler, dependencies, exports and hashes](foundation-manifest.json)
- [Complete artifact/workflow example](../examples/artifacts/README.md)
- [Independent consumer](../fixtures/consumer/main.roc)

## Milestones and commits

| Milestone | Commit | Result |
| --- | --- | --- |
| B0 | `620d8da` | Baseline and importable pure renderer, independent consumer |
| B1 | `c779c01` | Reusable environments, generic tools/sources, scoped inherited overlays, shared validation, IR major 2 |
| B2 | `b8e2a40` | Locked sources, caller layout/authority, sandboxed artifact dependencies, IR 2.1 |
| B3 | `4914936` | Typed sequential workflows, whole-plan preflight, fresh explicit build operations, IR 2.2 |
| B4 | `df24050` | Detached normal-package consumer, complete example, public API/toolchain manifest |
| Review follow-up | `daa3006` | Used example state excluded from consumer/example staging |
| Validation follow-up | `0365a2a` | Identical emitted IR with tools available or absent from PATH |

The approved semantics are implemented: parent-first inherited tools/overlays;
separate read-only source/artifact views; working-tree snapshots including
untracked/generated files, excluding locked-source trees and generated metadata.
No services, secrets, machines, deployments, images, ISOs, executable plugins,
expanded Guix execution, backend autodetection or successor ownership policy.

## Exact acceptance run

Verified on local x86_64 Linux, using the unchanged pinned Roc
`nightly-2026-09-23-c7852fd`, basic-cli source
`473caa2cc4f3fe9ce4e4682158bb80ebc2e19169`, Zig 0.16.0, Python 3.14.7 and
Nix 2.34.8. Compiler provisioning and the explicit ROC override remain tested.
Dependency URLs/hashes/pins were not changed to obtain passing tests.

```sh
mkdir -p "$HOME/.cache/blueprint-tmp"
export TMPDIR="$HOME/.cache/blueprint-tmp"
nix develop .#contributor -c scripts/test.sh
# Exit 1: unchanged, incompatible published major-1 IR gate (details below).
nix develop .#contributor -c scripts/fuzz.sh
# Exit 0; independently runs the checks after the blocking release gate.
nix develop .#contributor -c roc test blueprint-nix-package/main.roc
# Exit 0.
```

| Gate | Verified result |
| --- | --- |
| Formatting, platform host, CLI/consumer checks/builds | Passed; zero CLI build errors/warnings |
| Core tests | 123 passed |
| Nix backend tests | 212 passed |
| CLI/imported tests | 428 passed |
| Independent source consumer/imported tests | 440 passed |
| Detached bundled consumer tests | 228 passed; URL-package dependency tests are not recursively counted |
| Local **and** local-bundled configuration | Each: 19 valid, 89 semantic failures, 4 checked-name failures; expected diagnostics asserted |
| Emitted IR invariants | Composition/default/inheritance equivalence; unchanged when PATH has no tools |
| CLI/update boundaries | Version/feature/semantic rejection, exact argv, override, no fallback, atomic authority publication passed; recording stubs explicitly distinguished from builds |
| Real B1 execution | Imported tasks and ordered/inherited/scoped overlays passed; expected native missing-package/target failures asserted |
| Real B2 execution | 61 process checks passed, including exact bytes, dependency graph, independent snapshot manifest, read-only views, fresh/deleted sources, dirty pins, relocated/out-of-tree paths |
| Effective sandbox isolation | Real host-file and live TCP probes succeeded on host and failed inside user derivation; unsandboxed runner failed closed before Run |
| Fetched source policy | Real HTTP-fetched symlink source rejected through production runner before Run; safe-source positive control succeeded |
| Real B3 execution | 19 process checks passed: ordering/repetition, literal argv, task/build failures, no-op workflows, full-closure rejection, fresh dependency bytes after tasks, unchanged-output reuse, dirty-source abort |
| Complete public example | 5 process checks passed in a temporary copy; actual artifact bytes and workflow output order verified |
| Lock immutability | Authority bytes/inode/mode/mtime preserved during normal operations; no implicit lock/update calls; derived pins preserved |
| Detached packages | Core/backend/config bundled with one core identity; same plans/IR; consumer ran after server shutdown with empty PATH and no Blueprint subprocess |
| Nix package | Built with pinned compiler; wrapped invocation passed; Linux and Darwin output evaluation passed |
| Local IR/platform bundle | Passed all configuration regressions |
| Published IR/platform bundle | **Failed as expected:** 30 schema/export diagnostics against unchanged major-1 `ir-0.2.0` |
| Parse fuzz | 1,136,906 runs, 31 seconds, exit 0 |
| Round-trip fuzz | 255,957 runs, 31 seconds, exit 0 |

Imported test-root counts overlap; do not sum them. Negative fixtures are
asserted failures, not unexplained broken tests. The B2/B3 process counts include
clearly identified boundary/unit/negative cases, not that many distinct builds.

The full suite is **not green and not release-qualified**. Both bundle modes
were run; the old release gate was neither skipped nor redirected to a fabricated
compatible release. Its failure prevents the suite's trailing fuzz invocation,
so both fuzz targets were run independently afterward. No required check was
omitted from final evidence. Non-Linux execution and a successor port were not
tested or claimed.

Baseline distinction: the original major-1 baseline
`e7b80f0d7b1005765a1a26f41eea0870c6b63d22` passed both bundle modes; B0 also
passed. The published-IR incompatibility is the deliberate schema evolution
introduced by this work, not a preexisting unexplained failure. A source-only
handoff is permitted by the foundation plan; publishing needs a real compatible
IR artifact and renewed release validation.

## Evidence files

Local logs are retained under `$HOME/.cache/blueprint-tmp/` (not committed):

| Filename | SHA-256 |
| --- | --- |
| `foundation-0365a2a861bdc846370817866813080a7f3b60c3.log` | `6af88ce0e01d01dbc63f7330a8cae47deb36db23b7d85dfa1192750b7dcf2c42` |
| `foundation-0365a2a861bdc846370817866813080a7f3b60c3-fuzz.log` | `97ea3c3f9163fbee0eb122585b874214bdd5a4bb7d0c35ea071a4c3d49540cfc` |
| `foundation-0365a2a861bdc846370817866813080a7f3b60c3-backend.log` | `24033b571692f0dae1e58870cefaa5ce0913144c76e4a8d877f64b0bc06b97e1` |

`b4-used-example.log` separately records a detached archive with synthetic
preexisting ignored example authority/workspace: handoff and real example smoke
passed without copying that state or deleting user files. Review findings were
addressed with targeted regressions, then the exact final snapshot was retested.

## Remaining limits and preservation

- Source-only, no compatible published bundle claimed. Compiler still required
  at runtime; Nix package supplies it and Python.
- Local x86_64 Linux execution only; Darwin evaluation is not execution.
  No Guix executor or remote-build isolation qualification.
- Strict symlink/special-file rejection, bounded graphs/plans/lock data, trusted
  Nix daemon/kernel/packages, serialized workspace use and no concurrent source
  mutation. Ordinary tasks and configuration compilation are not sandboxed.
- Included ordinary project files are not scanned for secrets. Sensitive files
  must be outside the snapshot or in excluded trees.
- Staging repository retained; no successor port, retirement or successor files.
- Plans remain Git-ignored. Existing untracked
  `examples/all-settings/Invalid.roc` remains byte-identical, SHA-256
  `870deb1b5b9fdaf4849a12b252f54fc2c068e6bfbe23137697f48459c0ecc7ea`.
