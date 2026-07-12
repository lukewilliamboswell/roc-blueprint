#!/usr/bin/env python3
from __future__ import annotations

import argparse
import functools
import http.server
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ("blueprint", "blueprint-nix")
ROC = os.environ.get("ROC", "roc")


def run(cmd: list[str], *, cwd: Path = ROOT) -> subprocess.CompletedProcess[str]:
    print("+", " ".join(cmd))
    completed = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        if completed.stdout:
            print(completed.stdout)
        if completed.stderr:
            print(completed.stderr, file=sys.stderr)
        raise SystemExit(
            f"command failed with exit code {completed.returncode}: {' '.join(cmd)}"
        )
    return completed


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def build_bundles(bundle_dir: Path) -> dict[str, Path]:
    run(["scripts/bundle.sh", "--output-dir", str(bundle_dir)])
    bundles = {}
    for package_name in PACKAGES:
        matches = sorted((bundle_dir / package_name).glob("*.tar.zst"))
        if len(matches) != 1:
            raise SystemExit(
                f"expected exactly one {package_name} bundle, found {len(matches)}"
            )
        bundles[package_name] = matches[0]
    return bundles


def start_server(directory: Path) -> tuple[http.server.ThreadingHTTPServer, str]:
    port = find_free_port()
    handler = functools.partial(
        http.server.SimpleHTTPRequestHandler, directory=str(directory)
    )
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{port}"


def rewrite_examples(
    target_dir: Path, urls: dict[str, str], platform_url: str | None
) -> list[Path]:
    shutil.copytree(ROOT / "examples", target_dir)
    examples = sorted(target_dir.glob("*.roc"))
    for example in examples:
        source = example.read_text(encoding="utf-8")
        for package_name in PACKAGES:
            key = package_name.replace("-", "_")
            pattern = re.compile(rf'(?m)^(\s*{key}:\s*)"[^"]+"')
            source, count = pattern.subn(
                lambda match, url=urls[package_name]: f'{match.group(1)}"{url}"',
                source,
                count=1,
            )
            if count != 1:
                raise SystemExit(
                    f"{example.name} does not declare the expected {package_name} dependency"
                )
        if platform_url is not None:
            platform_pattern = re.compile(r'(?m)^(\s*pf:\s*platform\s*)"[^"]+"')
            source, count = platform_pattern.subn(
                lambda match: f'{match.group(1)}"{platform_url}"', source, count=1
            )
            if count != 1:
                raise SystemExit(
                    f"{example.name} does not declare the expected platform dependency"
                )
        example.write_text(source, encoding="utf-8")
    return examples


def exercise_examples(examples: list[Path], build_dir: Path) -> None:
    cwd = examples[0].parent
    for example in examples:
        run([ROC, "check", example.name, "--no-cache"], cwd=cwd)
        run([ROC, "test", example.name, "--no-cache"], cwd=cwd)
    build_dir.mkdir(parents=True, exist_ok=True)

    for example in examples:
        expected_path = cwd / f"{example.stem}.golden.nix"
        expected = expected_path.read_text(encoding="utf-8")

        interpreted = run([ROC, example.name, "--no-cache"], cwd=cwd)
        if interpreted.stdout != expected:
            raise SystemExit(f"interpreted output did not match {expected_path.name}")

        executable_name = f"{example.stem}.exe" if os.name == "nt" else example.stem
        output = build_dir / executable_name
        run([ROC, "build", example.name, f"--output={output}", "--no-cache"], cwd=cwd)
        compiled = run([str(output)])
        if compiled.stdout != expected:
            raise SystemExit(f"compiled output did not match {expected_path.name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--bundle-path", type=Path, help="Use the release bundle supplied by CI"
    )
    args = parser.parse_args()

    tmp_parent = Path(
        os.environ.get("ROC_BLUEPRINT_TMPDIR", ROOT / ".roc-blueprint-tmp")
    )
    tmp_parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="bundle-test-", dir=tmp_parent) as tmp:
        tmp_dir = Path(tmp)
        bundle_dir = tmp_dir / "bundles"
        bundle_dir.mkdir()
        bundles = build_bundles(bundle_dir)

        if args.bundle_path is not None:
            bundle_name = os.environ.get("BUNDLE_NAME", "")
            if bundle_name not in PACKAGES:
                raise SystemExit(f"unknown or missing BUNDLE_NAME: {bundle_name!r}")
            source = args.bundle_path.resolve()
            if not source.is_file():
                raise SystemExit(f"bundle does not exist: {source}")
            replacement = bundle_dir / bundle_name / source.name
            shutil.copy2(source, replacement)
            bundles[bundle_name] = replacement

        server, base_url = start_server(bundle_dir)
        try:
            urls = {
                name: f"{base_url}/{path.relative_to(bundle_dir).as_posix()}"
                for name, path in bundles.items()
            }
            platform_url = None
            platform_bundle_text = os.environ.get("ROC_PLATFORM_BUNDLE")
            if platform_bundle_text:
                platform_bundle = Path(platform_bundle_text).resolve()
                if not platform_bundle.is_file():
                    raise SystemExit(f"platform bundle does not exist: {platform_bundle}")
                served_platform = bundle_dir / platform_bundle.name
                shutil.copy2(platform_bundle, served_platform)
                platform_url = f"{base_url}/{served_platform.name}"

            examples = rewrite_examples(tmp_dir / "examples", urls, platform_url)
            exercise_examples(examples, tmp_dir / "build")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
