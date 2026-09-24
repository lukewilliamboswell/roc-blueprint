#!/usr/bin/env python3
"""Detached normal-package consumer gate; never invokes the Blueprint executable.

Run in the contributor shell after preparing .basic-cli and the config host.
Only distribution dependency headers are changed in temporary staged copies.
Core/backend code, renderer, tests and fixture data are copied byte-for-byte.
All owned staging, bundles and compiler temporary files live under ~/.cache.
"""

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from threading import Thread


ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def replace_header(path, old, new):
    """Install package URLs in a distribution copy, never rewrite module bodies."""
    text = path.read_text()
    header, body = text.split("\nimport ", 1) if "\nimport " in text else (text, "")
    require(header.count(old) == 1, f"ambiguous dependency header: {path}: {old}")
    path.write_text(header.replace(old, new) + ("\nimport " + body if body else ""))


def identity(path):
    stat = path.stat()
    return path.read_bytes(), stat.st_ino, stat.st_mode, stat.st_mtime_ns


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def gate(work):
    manifest = json.loads((ROOT / "docs/foundation-manifest.json").read_text())
    for name, expected in manifest["dependency_file_sha256"].items():
        actual = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        require(actual == expected, f"handoff dependency manifest drift: {name}")
    for name in ("configuration_platform", "core", "nix_backend"):
        boundary = manifest[name]
        keyword = "exposes" if name == "configuration_platform" else "package"
        match = re.search(rf"\b{keyword}\s*\[([^]]+)\]",
                          (ROOT / boundary["entry"]).read_text())
        require(match is not None, f"missing public header: {name}")
        exports = [item.strip() for item in match[1].split(",") if item.strip()]
        require(exports == boundary["exports"], f"public export manifest drift: {name}")
    env = dict(os.environ, TMPDIR=str(work / "tmp"))
    Path(env["TMPDIR"]).mkdir()
    roc = shutil.which(env.get("ROC", "roc"))
    require(roc, "Roc is required (use the pinned contributor shell)")
    roc = str(Path(roc).resolve())
    require((ROOT / ".basic-cli/main.roc").is_file(),
            "run scripts/prepare-basic-cli.sh first")
    require((ROOT / "blueprint-ir-platform/targets/x64musl/libhost.a").is_file(),
            "build the config platform host with zig build first")

    def run(argv, cwd, *, capture=False, clean_path=False):
        print("==>", " ".join(map(str, argv)), flush=True)
        return subprocess.run(
            list(map(str, argv)), cwd=cwd,
            env=dict(env, PATH="") if clean_path else env,
            check=True, stdout=subprocess.PIPE if capture else None, timeout=300,
        ).stdout

    # Compare against the existing consumer, not a second renderer/plan schema.
    baseline = work / "baseline-consumer"
    run([roc, "build", "fixtures/consumer/main.roc", f"--output={baseline}"], ROOT)
    expected = run([baseline], work, capture=True, clean_path=True)
    example_ir = run([roc, "examples/artifacts/Blueprint.roc"], ROOT, capture=True)
    for field, value in manifest["ir_format"].items():
        require(f"({field} {value})".encode() in example_ir,
                f"emitted IR disagrees with handoff format: {field}")

    publish = work / "publish"
    serve = work / "serve"
    detached = work / "detached"
    for path in (publish, serve, detached):
        path.mkdir()
    core = publish / "core"
    backend = publish / "nix"
    platform = publish / "platform"
    for original, stage in (("blueprint-ir-package", core),
                            ("blueprint-nix-package", backend),
                            ("blueprint-ir-platform", platform)):
        stage.mkdir()
        for source in (ROOT / original).glob("*.roc"):
            shutil.copyfile(source, stage / source.name)
    shutil.copyfile(ROOT / "blueprint-nix-package/build-runner.py",
                    backend / "build-runner.py")
    shutil.copytree(ROOT / "blueprint-nix-package/tests", backend / "tests")
    for target, names in {
        "x64musl": ("crt1.o", "libhost.a", "libc.a", "libzigc.a", "libcompiler_rt.a"),
        "arm64mac": ("libhost.a",),
    }.items():
        destination = platform / "targets" / target
        destination.mkdir(parents=True)
        for name in names:
            shutil.copyfile(ROOT / "blueprint-ir-platform/targets" / target / name,
                            destination / name)

    # The existing consumer's data import layout stays intact inside this tree.
    # No external checkout, source platform symlink, or local package fallback.
    app = detached / "fixtures/consumer"
    shutil.copytree(ROOT / "fixtures/consumer", app)
    data = detached / "blueprint-nix-package/tests"
    data.mkdir(parents=True)
    for name in ("sample.ir.scm", "sample.golden.nix"):
        shutil.copyfile(backend / "tests" / name, data / name)
    shutil.copytree(ROOT / ".basic-cli", detached / ".basic-cli", symlinks=False)
    example = detached / "examples/artifacts"
    shutil.copytree(ROOT / "examples/artifacts", example)
    authority = {path: identity(path) for path in (app / "authority.lock", app / "inputs.lock")}

    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(serve)))
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        origin = f"http://localhost:{server.server_port}"

        def bundle(stage, name):
            # Separate release-like identities; never commit these ephemeral URLs.
            output = serve / f"0.0.1-handoff-{name}"
            output.mkdir()
            files = sorted(str(p.relative_to(stage)) for p in stage.rglob("*") if p.is_file())
            files.remove("main.roc")
            run([roc, "bundle", "main.roc", *files, "--output-dir", output], stage)
            archives = list(output.glob("*.tar.zst"))
            require(len(archives) == 1, f"expected one {name} bundle: {archives}")
            return f"{origin}/{output.name}/{archives[0].name}"

        core_url = bundle(core, "core")
        for stage in (backend, platform):
            replace_header(stage / "main.roc", '"../blueprint-ir-package/main.roc"',
                           json.dumps(core_url))
        backend_url = bundle(backend, "nix")
        platform_url = bundle(platform, "config")
        replace_header(app / "main.roc", '"../../blueprint-ir-package/main.roc"',
                       json.dumps(core_url))
        replace_header(app / "main.roc", '"../../blueprint-nix-package/main.roc"',
                       json.dumps(backend_url))
        replace_header(example / "Blueprint.roc", '"../../blueprint-ir-platform/main.roc"',
                       json.dumps(platform_url))
        # Core has exactly one URL identity in the app, backend and config platform.
        for source in (app / "main.roc", backend / "main.roc", platform / "main.roc"):
            require(source.read_text().count(core_url) == 1, "split core identity")
        # Remove all distribution source copies before checking detached imports.
        shutil.rmtree(publish)
        require(not list(detached.rglob("NixBackend.roc")), "local backend fallback")
        require(not list(detached.rglob("Ir.roc")), "local core fallback")
        require(not any(p.is_symlink() for p in detached.rglob("*")), "external symlink")
        for source in detached.rglob("*.roc"):
            require(str(ROOT) not in source.read_text(), f"checkout path in {source}")

        run([roc, "fmt", "--check", "main.roc"], app)
        run([roc, "check", "main.roc"], app)
        # Runs the consumer's exact argv/lock/workflow assertions. Roc does not
        # recurse into URL-package tests; their source/data are still bundled.
        run([roc, "test", "main.roc"], app)
        binary = detached / "consumer"
        run([roc, "build", "main.roc", f"--output={binary}"], app)
        actual = run([roc, "main.roc"], app, capture=True)
        require(actual == expected, "bundled consumer changed planned files/locks")
        run([roc, "check", "Blueprint.roc"], example)
        bundled_ir = run([roc, "Blueprint.roc"], example, capture=True)
        require(bundled_ir == example_ir, "bundled config changed build/workflow IR")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()

    # Compiled consumer runs without the server, PATH tools, Nix or Blueprint.
    require(run([binary], detached, capture=True, clean_path=True) == expected,
            "detached executable differs from the source consumer")
    flake_header = b"# /consumer/work/generated/flake.nix\n"
    lock_header = b"# /consumer/work/generated/flake.lock\n"
    require(actual.startswith(flake_header), "unexpected consumer file layout")
    flake, lock = actual[len(flake_header):].split(lock_header)
    supplied = json.loads((app / "authority.lock").read_bytes())
    require(supplied["version"] == manifest["nix_authority_version"],
            "authority format differs from handoff manifest")
    require(supplied["nix"]["version"] == manifest["native_nix_lock_version"],
            "native lock format differs from handoff manifest")
    require(json.loads(lock) == supplied["nix"], "planned derivative changed pins")
    generated = detached / "generated"
    generated.mkdir()
    (generated / "flake.nix").write_bytes(flake)
    (generated / "flake.lock").write_bytes(lock)
    before = identity(generated / "flake.lock")
    run(["nix", "flake", "metadata", "--offline", "--no-update-lock-file",
         "--no-write-lock-file", f"path:{generated}"], detached, capture=True)
    require(identity(generated / "flake.lock") == before, "Nix changed derivative lock")
    require(all(identity(path) == saved for path, saved in authority.items()),
            "consumer changed supplied authority/seed")
    require(not list(detached.rglob("Blueprint.lock")), "unexpected second authority")
    print("PASS detached core + Nix package imports, imported tests, exact plans/argv, "
          "immutable supplied locks, bundled config with shared core identity")


def main():
    cache = Path.home() / ".cache/blueprint-tmp"
    cache.mkdir(parents=True, exist_ok=True)
    # Never delete repository files or a caller's preexisting temporary tree.
    with tempfile.TemporaryDirectory(prefix="handoff-", dir=cache) as temporary:
        work = Path(temporary).resolve()
        require(not work.is_relative_to(ROOT), "handoff staging must be outside the checkout")
        gate(work)


if __name__ == "__main__":
    main()
