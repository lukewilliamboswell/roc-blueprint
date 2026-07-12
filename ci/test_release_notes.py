#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="roc-blueprint-release-notes-") as tmp:
        tmp_dir = Path(tmp)
        notes = tmp_dir / "release-notes.md"
        bundles = tmp_dir / "release-bundles.json"
        notes.write_text("**Full Changelog**: example\n", encoding="utf-8")
        bundles.write_text(
            json.dumps(
                [
                    {
                        "name": "blueprint-nix",
                        "artifact_file": "nix-hash.tar.zst",
                    },
                    {
                        "name": "blueprint",
                        "artifact_file": "blueprint-hash.tar.zst",
                    },
                ]
            ),
            encoding="utf-8",
        )

        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/add_release_app_header.py"),
                "--notes",
                str(notes),
                "--bundles",
                str(bundles),
                "--repo",
                "owner/project",
                "--version",
                "1.2.3",
            ],
            cwd=ROOT,
            check=True,
        )

        split_dir = tmp_dir / "split"
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/split_release_metadata.py"),
                "--bundles",
                str(bundles),
                "--output-dir",
                str(split_dir),
            ],
            cwd=ROOT,
            check=True,
        )

        for package_name in ("blueprint", "blueprint-nix"):
            split = json.loads(
                (split_dir / f"release-bundles-{package_name}.json").read_text(
                    encoding="utf-8"
                )
            )
            if len(split) != 1 or split[0]["name"] != package_name:
                raise SystemExit(
                    f"release metadata was not isolated for {package_name}"
                )

        update_root = tmp_dir / "update"
        example_dir = update_root / "examples" / "hello"
        example_dir.mkdir(parents=True)
        (update_root / "README.md").write_text(
            "# Project\n\nDescription.\n\n## Packages\n\nPackage list.\n",
            encoding="utf-8",
        )
        (example_dir / "main.roc").write_text(
            "app [main!] {\n"
            '\tblueprint: "../../packages/blueprint/main.roc",\n'
            '\tblueprint_nix: "../../packages/blueprint-nix/main.roc",\n'
            "}\n",
            encoding="utf-8",
        )
        update_command = [
            sys.executable,
            str(ROOT / "scripts/update_release_urls.py"),
            "--root",
            str(update_root),
            "--bundles",
            str(bundles),
            "--repo",
            "owner/project",
            "--version",
            "1.2.3",
        ]
        subprocess.run(update_command, cwd=ROOT, check=True)
        first_update = (
            (update_root / "README.md").read_bytes(),
            (example_dir / "main.roc").read_bytes(),
        )
        subprocess.run(update_command, cwd=ROOT, check=True)
        second_update = (
            (update_root / "README.md").read_bytes(),
            (example_dir / "main.roc").read_bytes(),
        )
        if first_update != second_update:
            raise SystemExit("release URL update was not idempotent")
        readme_text = first_update[0].decode("utf-8")
        example_text = first_update[1].decode("utf-8")
        for text in (readme_text, example_text):
            if "download/1.2.3-blueprint/blueprint-hash.tar.zst" not in text:
                raise SystemExit("blueprint release URL was not updated")
            if "download/1.2.3-blueprint-nix/nix-hash.tar.zst" not in text:
                raise SystemExit("blueprint-nix release URL was not updated")
        if readme_text.count("<!-- BEGIN LATEST RELEASE -->") != 1:
            raise SystemExit("README latest-release marker was not stable")

        content = notes.read_text(encoding="utf-8")
        expected_lines = [
            "## Roc app header",
            "",
            "Copy these package URLs into your application header:",
            "",
            "```roc",
            "app [main!] {",
            (
                "\tpf: platform \"https://github.com/lukewilliamboswell/"
                "roc-platform-template-zig/releases/download/1.0.0/"
                "AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst\","
            ),
            (
                "\tblueprint: \"https://github.com/owner/project/releases/"
                "download/1.2.3-blueprint/blueprint-hash.tar.zst\","
            ),
            (
                "\tblueprint_nix: \"https://github.com/owner/project/releases/"
                "download/1.2.3-blueprint-nix/nix-hash.tar.zst\","
            ),
            "}",
            "```",
            "",
            "**Full Changelog**: example",
            "",
        ]
        expected = "\n".join(expected_lines)
        if content != expected:
            raise SystemExit("generated release app header did not match expected output")


if __name__ == "__main__":
    main()
