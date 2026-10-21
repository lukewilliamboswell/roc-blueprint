# Upstream SBOMs from real tools

These are what two widely used generators wrote for basic-cli 0.26.0-rc2's
`Cargo.toml` and `Cargo.lock` (copied from `sbom/upstream/`), on 2026-10-21:

| File | Generator | Command |
| --- | --- | --- |
| `syft.cdx.json` | Syft 1.54.0 | `syft scan dir:src -o cyclonedx-json` |
| `syft.spdx.json` | Syft 1.54.0 | `syft scan dir:src -o spdx-json` |
| `trivy.cdx.json` | Trivy 0.76.0 | `trivy fs --format cyclonedx src` |
| `trivy.spdx.json` | Trivy 0.76.0 | `trivy fs --format spdx-json src` |

Both tools come from nixpkgs (`nix shell nixpkgs#syft nixpkgs#trivy`). The
files are their output unchanged except that the absolute path of the scanned
directory, which Syft records in a file component's name and location, is
replaced by `/src`, so no developer path is committed.

`scripts/src/SbomTest.roc` requires each to import, with exactly the gaps
Blueprint reports for it, and they seed the `sbom-read` fuzz target.
