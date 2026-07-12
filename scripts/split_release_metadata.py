#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


PACKAGES = ("blueprint", "blueprint-nix")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--bundles", type=Path, default=Path(".release/release-bundles.json")
    )
    parser.add_argument("--output-dir", type=Path, default=Path(".release"))
    args = parser.parse_args()

    try:
        payload = json.loads(args.bundles.read_text(encoding="utf-8"))
    except FileNotFoundError as err:
        raise SystemExit(f"release bundle metadata is missing: {args.bundles}") from err
    except json.JSONDecodeError as err:
        raise SystemExit(f"release bundle metadata is invalid JSON: {err}") from err

    if not isinstance(payload, list):
        raise SystemExit("release bundle metadata must be a JSON list")

    by_name: dict[str, dict[str, object]] = {}
    for entry in payload:
        if not isinstance(entry, dict):
            raise SystemExit("release bundle entries must be objects")
        name = entry.get("name")
        if name not in PACKAGES:
            raise SystemExit(f"unexpected release bundle name: {name!r}")
        if name in by_name:
            raise SystemExit(f"duplicate release bundle name: {name}")
        by_name[name] = entry

    missing = sorted(set(PACKAGES) - set(by_name))
    if missing:
        raise SystemExit(f"missing release bundle metadata: {', '.join(missing)}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name in PACKAGES:
        output = args.output_dir / f"release-bundles-{name}.json"
        output.write_text(
            json.dumps([by_name[name]], indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"Created {output}")


if __name__ == "__main__":
    main()
