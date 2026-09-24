# Foundation validation record

## B0 baseline

Baseline source: `e7b80f0d7b1005765a1a26f41eea0870c6b63d22`.
Verified on x86_64 Linux using `nix develop .#contributor`, with `TMPDIR`
under the user's cache directory (not `/tmp`).

Toolchain and dependency pins (unchanged by extraction):

| Component | Revision |
| --- | --- |
| Roc | `nightly-2026-09-23-c7852fd` |
| basic-cli source | `473caa2cc4f3fe9ce4e4682158bb80ebc2e19169` |
| roc-overlay | `06198bdac7c2a171c93d0a6f0ddeea562867ee1e` |
| nixpkgs | `6774f7bc253789b113a4f39285dc0fa100abeacc` |
| rust-overlay | `fb058ecf6d14837ea152a3d5225ce7f88ee5cde1` |
| Weaver | `0.9.0` (URL/hash in CLI/flake) |
| Zig | `0.16.0` |
| Nix | `2.34.8` |
| IR | `1.0` |

The GitHub release API still lists basic-cli `0.23.0-rc1` as the newest
prerelease; no release including the required fixes was adopted. Compiler,
platform source, URLs, hashes and dependency locks remain unchanged. The
pinned pair compiled the CLI, including imported basic-cli tests, and built
the Nix package. Compiler provisioning remains a runtime requirement.

`scripts/test.sh` passed from a pristine archive of the baseline commit:
formatting; 25 IR tests; platform host; local compile-time validation;
256 CLI/imported tests; CLI build and argument tests; real Nix tasks;
golden Nix parsing; explicit extension rejection; Nix package build and
wrapped compiler; both system output evaluations; local-IR and released-IR
platform bundles and their compile-time validation; both 30-second fuzz runs.
No baseline checks were skipped. macOS was evaluated, not executed.

The initial in-place baseline invocation reached both fuzz targets but its
shell reread a concurrently edited test script and exited with a stray-command
error. The pristine baseline rerun above was completed unchanged, with exit 0;
the stray-command error is not a product failure.

## B0 extraction

`blueprint-nix-package/main.roc` exports `Backend` and `NixBackend`; the
reference CLI now imports this package. The original renderer and its goldens
are shared, not copied. The IR package and configuration platform are unchanged.

The independent `fixtures/consumer/main.roc` imports the IR and Nix packages,
chooses its own project/workspace/generated/lock paths and obtains generated
files without importing or invoking the Blueprint executable. Its five pure
assertions cover exact rendered files and supplied lock bytes, target rejection,
path traversal rejection, explicit rejection of not-yet-supported local inputs,
and exact command argv (including empty arguments).
`scripts/test-consumer.sh` checks/tests/builds/runs the consumer, compares stdout
byte-for-byte, and asks real Nix to accept its supplied pins offline with
`--no-update-lock-file`, then verifies unchanged lock bytes.

After extraction, the complete `scripts/test.sh` passed again with exit 0:
25 IR tests, 256 CLI/imported tests, 261 independent-consumer/imported tests,
all existing integration/build/bundle gates, and both fuzz targets
(1,336,441 parse runs and 246,353 round-trip runs). No checks were skipped.
The fixture lock was created by real Nix, is committed with the consumer,
and contains only remote revision/hash identities, not machine-local paths.

This is only the initial library seam, **not a B4 handoff**. In particular,
`Backend.LockedInputs` currently carries trusted Nix lock bytes, not a validated
source identity protocol. The reference CLI still has the baseline lock
lifecycle. Environment/source/build/workflow semantics, runtime path validation,
and relocation of local inputs remain later milestones. No sandbox/artifact or
Guix execution claims follow from these tests.
