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
                "download/1.2.3/blueprint-hash.tar.zst\","
            ),
            (
                "\tblueprint_nix: \"https://github.com/owner/project/releases/"
                "download/1.2.3/nix-hash.tar.zst\","
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
