#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path


PACKAGE_ALIASES = {
    "blueprint": "blueprint",
    "blueprint-nix": "blueprint_nix",
}
PLATFORM_URL = (
    "https://github.com/lukewilliamboswell/roc-platform-template-zig/"
    "releases/download/1.0.0/"
    "AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst"
)


def require_single_line(value: str, description: str) -> str:
    if not value or "\n" in value or "\r" in value:
        raise SystemExit(f"{description} must be a non-empty single line")
    return value


def read_bundle_names(path: Path) -> dict[str, str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as err:
        raise SystemExit(f"release bundle metadata is missing: {path}") from err
    except json.JSONDecodeError as err:
        raise SystemExit(f"release bundle metadata is invalid JSON: {err}") from err

    if not isinstance(payload, list):
        raise SystemExit("release bundle metadata must be a JSON list")

    bundles: dict[str, str] = {}
    for index, item in enumerate(payload):
        if not isinstance(item, dict):
            raise SystemExit(f"release bundle entry {index} must be an object")
        name = item.get("name")
        artifact_file = item.get("artifact_file")
        if name not in PACKAGE_ALIASES:
            raise SystemExit(f"unexpected release bundle name: {name!r}")
        if name in bundles:
            raise SystemExit(f"duplicate release bundle name: {name}")
        if not isinstance(artifact_file, str) or not re.fullmatch(
            r"[A-Za-z0-9._-]+\.tar\.zst", artifact_file
        ):
            raise SystemExit(f"invalid artifact filename for {name}: {artifact_file!r}")
        if Path(artifact_file).name != artifact_file:
            raise SystemExit(f"artifact filename contains a directory: {artifact_file}")
        bundles[name] = artifact_file

    missing = sorted(set(PACKAGE_ALIASES) - set(bundles))
    if missing:
        raise SystemExit(f"missing release bundle metadata: {', '.join(missing)}")
    return bundles


def app_header(repo: str, version: str, bundles: dict[str, str]) -> str:
    urls = package_urls(repo, version, bundles)
    package_lines = [
        f'\t{PACKAGE_ALIASES[name]}: "{urls[name]}",'
        for name in PACKAGE_ALIASES
    ]
    return "\n".join(
        [
            "## Roc app header",
            "",
            "Copy these package URLs into your application header:",
            "",
            "```roc",
            "app [main!] {",
            f'\tpf: platform "{PLATFORM_URL}",',
            *package_lines,
            "}",
            "```",
        ]
    )


def package_urls(repo: str, version: str, bundles: dict[str, str]) -> dict[str, str]:
    return {
        name: (
            f"https://github.com/{repo}/releases/download/"
            f"{version}-{name}/{bundles[name]}"
        )
        for name in PACKAGE_ALIASES
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--notes", type=Path, default=Path(".release/release-notes.md")
    )
    parser.add_argument(
        "--bundles", type=Path, default=Path(".release/release-bundles.json")
    )
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--version", default=os.environ.get("RELEASE_VERSION", ""))
    args = parser.parse_args()

    repo = require_single_line(args.repo, "repository")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise SystemExit(f"repository must use owner/name form: {repo!r}")
    version = require_single_line(args.version, "release version")
    if not re.fullmatch(
        r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
        r"(?:-[0-9A-Za-z.-]+)?",
        version,
    ):
        raise SystemExit(f"release version must be semantic: {version!r}")

    try:
        existing_notes = args.notes.read_text(encoding="utf-8").strip()
    except FileNotFoundError as err:
        raise SystemExit(f"generated release notes are missing: {args.notes}") from err
    if not existing_notes:
        raise SystemExit(f"generated release notes are empty: {args.notes}")

    bundles = read_bundle_names(args.bundles)
    content = f"{app_header(repo, version, bundles)}\n\n{existing_notes}\n"
    args.notes.write_text(content, encoding="utf-8")
    print(f"Added package app header to {args.notes}")


if __name__ == "__main__":
    main()
