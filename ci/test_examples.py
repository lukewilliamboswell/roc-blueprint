#!/usr/bin/env python3
from __future__ import annotations

import argparse
import functools
import http.server
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ("blueprint", "blueprint-nix")
ROC = os.environ.get("ROC", "roc")


def run(
    cmd: list[str], *, cwd: Path, capture_stdout: bool = False
) -> subprocess.CompletedProcess[bytes]:
    print("+", " ".join(cmd), f"(in {cwd})", flush=True)
    completed = subprocess.run(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        if completed.stdout:
            sys.stdout.buffer.write(completed.stdout)
        if completed.stderr:
            sys.stderr.buffer.write(completed.stderr)
        raise SystemExit(
            f"command failed with exit code {completed.returncode}: {' '.join(cmd)}"
        )
    if not capture_stdout:
        if completed.stdout:
            sys.stdout.buffer.write(completed.stdout)
        if completed.stderr:
            sys.stderr.buffer.write(completed.stderr)
    return completed


def discover_examples(examples_dir: Path) -> list[Path]:
    example_dirs = sorted(path for path in examples_dir.iterdir() if path.is_dir())
    if not example_dirs:
        raise SystemExit(f"no example directories found in {examples_dir}")

    for example_dir in example_dirs:
        for filename in ("main.roc", "flake.golden.nix", "flake.lock"):
            required = example_dir / filename
            if not required.is_file():
                raise SystemExit(f"missing example file: {required}")

    return example_dirs


def build_bundles(bundle_dir: Path) -> dict[str, Path]:
    run(
        ["scripts/bundle.sh", "--output-dir", str(bundle_dir)],
        cwd=ROOT,
    )
    bundles = {}
    for package_name in PACKAGES:
        matches = sorted((bundle_dir / package_name).glob("*.tar.zst"))
        if len(matches) != 1:
            raise SystemExit(
                f"expected exactly one {package_name} bundle, found {len(matches)}"
            )
        bundles[package_name] = matches[0]
    return bundles


def start_server(
    directory: Path,
) -> tuple[http.server.ThreadingHTTPServer, str]:
    handler = functools.partial(
        http.server.SimpleHTTPRequestHandler, directory=str(directory)
    )
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    host, port = server.server_address
    return server, f"http://{host}:{port}"


def rewrite_examples(
    source_dir: Path,
    target_dir: Path,
    urls: dict[str, str],
    platform_url: str | None,
) -> None:
    shutil.copytree(source_dir, target_dir)
    examples = discover_examples(target_dir)
    for example_dir in examples:
        main_path = example_dir / "main.roc"
        source = main_path.read_text(encoding="utf-8")
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
                    f"{example_dir.name} does not declare the expected "
                    f"{package_name} dependency"
                )

        if platform_url is not None:
            platform_pattern = re.compile(r'(?m)^(\s*pf:\s*platform\s*)"[^"]+"')
            source, count = platform_pattern.subn(
                lambda match: f'{match.group(1)}"{platform_url}"',
                source,
                count=1,
            )
            if count != 1:
                raise SystemExit(
                    f"{example_dir.name} does not declare the expected "
                    "platform dependency"
                )
        main_path.write_text(source, encoding="utf-8")


def require_equal(actual: bytes, expected: bytes, description: str) -> None:
    if actual != expected:
        raise SystemExit(f"{description} did not match byte-for-byte")


def exercise_examples(
    examples_dir: Path, work_dir: Path, nix_work_dir: Path
) -> None:
    nix = shutil.which("nix")
    if nix is None:
        raise SystemExit("nix is required to validate generated flakes")

    work_dir.mkdir(parents=True, exist_ok=True)
    nix_work_dir.mkdir(parents=True, exist_ok=True)
    for example_dir in discover_examples(examples_dir):
        name = example_dir.name
        print(f"\nTesting example: {name}", flush=True)

        run([ROC, "check", "main.roc", "--no-cache"], cwd=example_dir)
        run([ROC, "test", "main.roc", "--no-cache"], cwd=example_dir)

        first = run(
            [ROC, "main.roc", "--no-cache"],
            cwd=example_dir,
            capture_stdout=True,
        ).stdout
        second = run(
            [ROC, "main.roc", "--no-cache"],
            cwd=example_dir,
            capture_stdout=True,
        ).stdout
        golden = (example_dir / "flake.golden.nix").read_bytes()
        require_equal(first, golden, f"{name} generated output")
        require_equal(second, first, f"{name} repeated generation")

        flake_dir = nix_work_dir / name
        flake_dir.mkdir(parents=True, exist_ok=True)
        (flake_dir / "flake.nix").write_bytes(first)
        source_lock = example_dir / "flake.lock"
        generated_lock = flake_dir / "flake.lock"
        shutil.copy2(source_lock, generated_lock)

        run([nix, "flake", "lock", str(flake_dir)], cwd=ROOT)
        require_equal(
            generated_lock.read_bytes(),
            source_lock.read_bytes(),
            f"{name} lockfile",
        )
        run(
            [nix, "flake", "check", str(flake_dir), "--no-write-lock-file"],
            cwd=ROOT,
        )

        build_dir = work_dir / "build" / name
        build_dir.mkdir(parents=True, exist_ok=True)
        executable = build_dir / ("app.exe" if os.name == "nt" else "app")
        run(
            [ROC, "build", "main.roc", f"--output={executable}", "--no-cache"],
            cwd=example_dir,
        )
        compiled = run(
            [str(executable)], cwd=example_dir, capture_stdout=True
        ).stdout
        require_equal(compiled, golden, f"{name} compiled output")

        if name == "dev-shell":
            run(
                [
                    nix,
                    "develop",
                    f"{flake_dir}#default",
                    "--command",
                    "rustc",
                    "--version",
                ],
                cwd=ROOT,
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--bundle-path", type=Path, help="Use the release bundle supplied by CI"
    )
    args = parser.parse_args()

    tmp_parent = Path(
        os.environ.get("ROC_BLUEPRINT_TMPDIR", ROOT / ".roc-blueprint-tmp")
    )
    nix_tmp_parent = Path(
        os.environ.get(
            "ROC_BLUEPRINT_NIX_TMPDIR",
            f"{tempfile.gettempdir()}/roc-blueprint-nix",
        )
    )
    tmp_parent.mkdir(parents=True, exist_ok=True)
    nix_tmp_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="examples-", dir=tmp_parent
    ) as tmp, tempfile.TemporaryDirectory(
        prefix="flakes-", dir=nix_tmp_parent
    ) as nix_tmp:
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
                    raise SystemExit(
                        f"platform bundle does not exist: {platform_bundle}"
                    )
                served_platform = bundle_dir / platform_bundle.name
                shutil.copy2(platform_bundle, served_platform)
                platform_url = f"{base_url}/{served_platform.name}"

            rewritten_examples = tmp_dir / "examples"
            rewrite_examples(
                ROOT / "examples",
                rewritten_examples,
                urls,
                platform_url,
            )
            exercise_examples(
                rewritten_examples,
                tmp_dir / "example-tests",
                Path(nix_tmp),
            )
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
