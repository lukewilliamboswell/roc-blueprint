#!/usr/bin/env python3
"""Real CLI update safety and CAS tests with recorded Nix/Roc stubs."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lockfile  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
BLUEPRINT = ROOT / "blueprint"
ROC = shutil.which(os.environ.get("ROC", "roc"))
if ROC is None:
    raise SystemExit("Roc compiler not found")
ROC = str(Path(ROC).resolve())
ROC_VERSION = subprocess.check_output([ROC, "version"], text=True)
WIRE = '''((format ((major 2) (minor 0))) (name "wire")
(systems ("x86_64-linux"))
(sources (((name "default") (provider Auto))))
(environments (((name "ci") (parents ()) (tools ()) (overlays ()))))
(shells (((name "default") (environment "ci")))))'''


def wait(path):
    until = time.monotonic() + 20
    while not path.exists():
        assert time.monotonic() < until, path
        time.sleep(0.01)


with tempfile.TemporaryDirectory(prefix="blueprint-update-") as temp:
    work = Path(temp)
    tools = work / "bin"
    tools.mkdir()
    roc = tools / "roc"
    roc.write_text(f"#!{sys.executable}\n" + '''import os, sys
from pathlib import Path
if sys.argv[1:] == ["version"]:
    print(os.environ["ROC_VERSION"], end="")
else:
    assert sys.argv[1:] == ["Blueprint.roc"], sys.argv
    print(Path("wire.scm").read_text())
''')
    nix = tools / "nix"
    nix.write_text(f"#!{sys.executable} -I\n" + '''import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
with Path("nix-calls").open("a") as out:
    out.write(json.dumps(args) + "\\n")
assert args[:3] == ["flake", "update", "--flake"], args
assert len(args) == 4 and args[3].startswith("path:/"), args
if os.environ.get("PAUSE"):
    Path(os.environ["PAUSE"] + ".ready").touch()
    until = time.monotonic() + 30
    while not Path(os.environ["PAUSE"] + ".release").exists():
        assert time.monotonic() < until
        time.sleep(0.01)
graph = json.loads(Path(os.environ["FIXTURE"]).read_text())
del graph["nodes"]["assets"]
del graph["nodes"]["root"]["inputs"]["assets"]
graph["nodes"]["default"]["locked"]["rev"] = os.environ.get("REV", "c") * 40
generated = Path(args[3].removeprefix("path:"))
generated.joinpath("flake.lock").write_text(json.dumps(graph))
''')
    # Any use of a host Python by the CLI is recorded, then fails.
    used_python = work / "python3-was-used"
    python = tools / "python3"
    python.write_text(f"#!/bin/sh\necho \"$@\" >>{used_python}\nexit 97\n")
    for executable in (roc, nix, python):
        executable.chmod(0o755)
    env = os.environ | {
        "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}", "ROC": str(roc),
        "ROC_VERSION": ROC_VERSION,
        "FIXTURE": str(ROOT / "blueprint-nix/tests"
                       / "local.nix-lock.json"),
    }

    def project(name, wire=WIRE):
        root = work / name
        root.mkdir()
        (root / "Blueprint.roc").touch()
        (root / "wire.scm").write_text(wire)
        return root

    def run(root, args=("update",), extra=None):
        return subprocess.run([str(BLUEPRINT), *args], cwd=root,
                              env=env | (extra or {}), capture_output=True,
                              text=True, timeout=30)

    # Preflight must inspect ancestor links for every provider input category.
    forms = {
        "build-source": WIRE[:-1] + '(build_sources (((name "assets") '
                        '(ref "path:./outer/assets")))) '
                        '(requires ("sources")))',
        "package-source": WIRE.replace('(provider Auto)',
                          '(provider (NixPackages "path:./outer/assets"))'),
        "overlay": WIRE[:-1] + '(inputs (((name "assets") '
                   '(url "path:./outer/assets") (kind Overlay)))))',
    }
    outside = work / "outside"
    (outside / "assets").mkdir(parents=True)
    for kind, wire in forms.items():
        root = project(f"ancestor-{kind}", wire)
        (root / "outer").symlink_to(outside, target_is_directory=True)
        lock = root / "Blueprint.lock"
        lock.write_bytes(b"old authority\xff\x00")
        before = (lock.read_bytes(), lock.stat())
        result = run(root)
        assert result.returncode != 0 and "unsafe" in result.stderr, result
        assert not (root / ".blueprint").exists()
        assert not (root / "nix-calls").exists()
        assert lock.read_bytes() == before[0]
        assert lock.stat().st_ino == before[1].st_ino
        assert lock.stat().st_mtime_ns == before[1].st_mtime_ns

    # Nested links, missing source roots and special files fail before effects.
    for kind in ("nested", "missing", "fifo"):
        root = project(kind, forms["build-source"])
        source = root / "outer/assets"
        if kind != "missing":
            source.mkdir(parents=True)
            if kind == "nested":
                (source / "escape").symlink_to(outside)
            else:
                os.mkfifo(source / "fifo")
        result = run(root)
        assert result.returncode != 0, result
        assert not (root / ".blueprint").exists()
        assert not (root / "nix-calls").exists()
        assert not (root / "Blueprint.lock").exists()

    # Older, paused resolution cannot overwrite a newer completed update.
    for initial in (None, b"invalid old authority\xff\x00"):
        suffix = "missing" if initial is None else "existing"
        root = project(f"race-{suffix}")
        lock = root / "Blueprint.lock"
        if initial is not None:
            lock.write_bytes(initial)
        pause = work / (root.name + "-barrier")
        common = {"BLUEPRINT_GENERATED_ROOT": str(work / (root.name + "-a")),
                  "REV": "a", "PAUSE": str(pause)}
        older = subprocess.Popen([str(BLUEPRINT), "update"], cwd=root,
                                 env=env | common, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        try:
            wait(Path(str(pause) + ".ready"))
            newer = run(root, extra={
                "BLUEPRINT_GENERATED_ROOT": str(work / (root.name + "-b")),
                "REV": "b",
            })
            assert newer.returncode == 0, newer.stderr
            winner = lock.read_bytes()
            node = lockfile.nix_graph(winner.decode())["nodes"]["default"]
            assert node["locked"]["rev"] == "b" * 40
            Path(str(pause) + ".release").touch()
            out, err = older.communicate(timeout=30)
            assert older.returncode != 0, (out, err)
            assert "authority changed during update" in err, (out, err)
            assert lock.read_bytes() == winner
            assert not list(root.glob(".blueprint-write-*"))
            assert not list(root.glob("*writer*"))
            stat = lock.stat()
            normal = run(root, ("gen",))
            assert normal.returncode == 0, normal.stderr
            assert lock.read_bytes() == winner
            assert lock.stat().st_ino == stat.st_ino
            assert lock.stat().st_mtime_ns == stat.st_mtime_ns
            # Conflict did not poison a subsequent explicit update.
            subsequent = run(root)
            assert subsequent.returncode == 0, subsequent.stderr
        finally:
            if older.poll() is None:
                older.kill()
                older.communicate()

    # The authority is observed by its raw bytes, in bounded chunks: while an
    # update is paused, any change to them is a conflict, including one past
    # the first chunk, removal and creation. Identical bytes are no change.
    large = os.urandom(200_000)
    cases = {
        "last-byte": (large, large[:-1] + bytes([large[-1] ^ 1]), False),
        "truncated": (large, large[:-1], False),
        "removed": (b"old authority\xff\x00", None, False),
        "created": (None, b"", False),
        "emptied": (b"\n", b"", False),
        "same-bytes": (large, large, True),
        "still-absent": (None, None, True),
    }
    for name, (initial, replacement, publishes) in cases.items():
        root = project(f"observed-{name}")
        lock = root / "Blueprint.lock"
        if initial is not None:
            lock.write_bytes(initial)
        pause = work / (root.name + "-barrier")
        update = subprocess.Popen([str(BLUEPRINT), "update"], cwd=root,
                                  env=env | {"PAUSE": str(pause)},
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        try:
            wait(Path(str(pause) + ".ready"))
            # Replace by rename, as a competing publisher would: a new inode.
            lock.unlink(missing_ok=True)
            if replacement is not None:
                other = root / "competing-authority"
                other.write_bytes(replacement)
                other.rename(lock)
            Path(str(pause) + ".release").touch()
            out, err = update.communicate(timeout=30)
            if publishes:
                assert update.returncode == 0, (name, out, err)
                node = lockfile.nix_graph(lock.read_text())["nodes"]["default"]
                assert node["locked"]["rev"] == "c" * 40
            else:
                assert update.returncode == 1, (name, out, err)
                assert "authority changed during update" in err, (name, err)
                if replacement is None:
                    assert not lock.exists()
                else:
                    assert lock.read_bytes() == replacement
            assert not list(root.glob(".blueprint-write-*"))
        finally:
            if update.poll() is None:
                update.kill()
                update.communicate()

    # A symlinked authority, or one below a symlinked directory, is refused
    # before it is read: nothing is fetched and the link target is untouched.
    for kind in ("file", "dangling", "parent"):
        root = project(f"linked-authority-{kind}")
        target = work / f"linked-authority-{kind}-target"
        target.mkdir()
        (target / "Blueprint.lock").write_bytes(b"elsewhere\xff\x00")
        extra = {}
        if kind == "parent":
            (root / "locks").symlink_to(target, target_is_directory=True)
            extra = {"BLUEPRINT_LOCK": "locks/Blueprint.lock"}
        else:
            name = "Blueprint.lock" if kind == "file" else "absent"
            (root / "Blueprint.lock").symlink_to(target / name)
        for command in (("update",), ("gen",)):
            result = run(root, command, extra)
            assert result.returncode != 0 and "unsafe" in result.stderr, result
        assert (target / "Blueprint.lock").read_bytes() == b"elsewhere\xff\x00"
        assert [entry.name for entry in target.iterdir()] == ["Blueprint.lock"]
        assert not (root / ".blueprint").exists()
        assert not (root / "nix-calls").exists()

    # The CLI runs no Python of its own, so project modules named like the
    # standard library cannot affect an update.
    root = project("python-collision")
    for module in ("json", "hashlib", "tempfile", "shutil", "fcntl"):
        (root / f"{module}.py").write_text(
            "raise RuntimeError('project import must not reach helper')\n"
        )
    result = run(root)
    assert result.returncode == 0, result.stderr
    assert run(root, ("gen",)).returncode == 0

    # A special-file authority must fail, not block inside a file read.
    root = project("fifo-authority")
    os.mkfifo(root / "Blueprint.lock")
    for command in (("gen",), ("shell", "default")):
        result = run(root, command)
        assert result.returncode != 0 and "unsafe" in result.stderr, result
    result = run(root)
    assert result.returncode != 0, result
    assert "authority is not a regular file" in result.stderr, result
    assert not (root / ".blueprint").exists()
    assert not (root / "nix-calls").exists()
    assert not list(root.glob(".blueprint-write-*"))

    assert not used_python.exists(), used_python.read_text()

print("Update preflight, concurrent authority CAS and immutable gen tests "
      "passed without a host Python (stubbed Nix/compiler)")
