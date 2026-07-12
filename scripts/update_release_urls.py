#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

from add_release_app_header import (
    PACKAGE_ALIASES,
    app_header,
    package_urls,
    read_bundle_names,
    require_single_line,
)


README_START = "<!-- BEGIN LATEST RELEASE -->"
README_END = "<!-- END LATEST RELEASE -->"


def update_examples(examples_dir: Path, urls: dict[str, str]) -> None:
    examples = sorted(examples_dir.glob("*/main.roc"))
    if not examples:
        raise SystemExit(f"no example applications found in {examples_dir}")

    for main_path in examples:
        source = main_path.read_text(encoding="utf-8")
        for package_name, alias in PACKAGE_ALIASES.items():
            pattern = re.compile(rf'(?m)^(\s*{alias}:\s*)"[^"]+"')
            source, count = pattern.subn(
                lambda match, url=urls[package_name]: f'{match.group(1)}"{url}"',
                source,
                count=1,
            )
            if count != 1:
                raise SystemExit(
                    f"{main_path} does not declare exactly one {alias} dependency"
                )
        main_path.write_text(source, encoding="utf-8")


def latest_release_block(repo: str, version: str, bundles: dict[str, str]) -> str:
    header = app_header(repo, version, bundles)
    header = header.replace("## Roc app header", "## Latest release", 1)
    header = header.replace(
        "Copy these package URLs into your application header:",
        (
            f"Version `{version}` publishes two packages. Copy these URLs into "
            "your application header:"
        ),
        1,
    )
    return f"{README_START}\n{header}\n{README_END}"


def update_readme(
    readme_path: Path, repo: str, version: str, bundles: dict[str, str]
) -> None:
    try:
        source = readme_path.read_text(encoding="utf-8")
    except FileNotFoundError as err:
        raise SystemExit(f"README is missing: {readme_path}") from err

    block = latest_release_block(repo, version, bundles)
    marker_pattern = re.compile(
        rf"{re.escape(README_START)}.*?{re.escape(README_END)}", re.DOTALL
    )
    source, count = marker_pattern.subn(block, source)
    if count > 1:
        raise SystemExit("README contains duplicate latest-release blocks")
    if count == 0:
        packages_heading = "\n## Packages\n"
        if source.count(packages_heading) != 1:
            raise SystemExit("README must contain exactly one Packages heading")
        source = source.replace(
            packages_heading, f"\n{block}\n{packages_heading}", 1
        )
    readme_path.write_text(source, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument(
        "--bundles", type=Path, default=Path(".release/release-bundles.json")
    )
    parser.add_argument("--repo", required=True)
    parser.add_argument("--version", required=True)
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

    bundles = read_bundle_names(args.bundles)
    urls = package_urls(repo, version, bundles)
    update_examples(args.root / "examples", urls)
    update_readme(args.root / "README.md", repo, version, bundles)
    print(f"Updated README and example package URLs for {version}")


if __name__ == "__main__":
    main()
