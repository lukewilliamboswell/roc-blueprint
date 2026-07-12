#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


PACKAGES = ("blueprint", "blueprint-nix")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dist", type=Path, default=Path("dist"))
    parser.add_argument("--output", type=Path, default=Path("dist/release-bundles.json"))
    args = parser.parse_args()

    manifest = []
    for package_name in PACKAGES:
        bundles = sorted((args.dist / package_name).glob("*.tar.zst"))
        if len(bundles) != 1:
            raise SystemExit(
                f"expected exactly one {package_name} bundle, found {len(bundles)}"
            )
        manifest.append(
            {
                "name": package_name,
                "path": bundles[0].as_posix(),
                "test_os": ["ubuntu-latest"],
            }
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Created {args.output}")


if __name__ == "__main__":
    main()
