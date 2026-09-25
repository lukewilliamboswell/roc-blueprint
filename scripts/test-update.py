#!/usr/bin/env python3
"""Real CLI/helper update safety and CAS tests with recorded Nix/Roc stubs."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
BLUEPRINT = ROOT / "blueprint"
HELPER = ROOT / "scripts/blueprint-runtime.py"
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
    for executable in (roc, nix):
        executable.chmod(0o755)
    env = os.environ | {
        "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}", "ROC": str(roc),
        "ROC_VERSION": ROC_VERSION,
        "FIXTURE": str(ROOT / "blueprint-nix-package/tests"
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

    # Preflight must inspect ancestor links for every backend input category.
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
            node = json.loads(winner)["nix"]["nodes"]["default"]
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

    # Project modules cannot shadow embedded helper dependencies.
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
    assert not (root / ".blueprint").exists()
    assert not (root / "nix-calls").exists()

    # Directory flock is released even if its owner dies before publication.
    root = work / "lock-crash"
    root.mkdir()
    lock = root / "authority"
    lock.write_bytes(b"\xfforiginal\x00")
    token = subprocess.check_output(
        [sys.executable, str(HELPER), "authority-token", str(lock)],
        text=True).strip()
    assert token == "sha256:" + hashlib.sha256(lock.read_bytes()).hexdigest()
    staged = root / "staged"
    staged.write_bytes(b"new\xff\x00")
    holder = subprocess.Popen([sys.executable, "-c", '''
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
fcntl.flock(fd, fcntl.LOCK_EX)
print("locked", flush=True)
time.sleep(60)
''', str(root)], stdout=subprocess.PIPE, text=True)
    publisher = None
    try:
        assert holder.stdout.readline() == "locked\n"
        publisher = subprocess.Popen(
            [sys.executable, str(HELPER), "authority-publish", str(lock),
             token, str(staged)], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        time.sleep(0.1)
        assert publisher.poll() is None
        holder.kill()
        holder.wait(timeout=10)
        out, err = publisher.communicate(timeout=10)
        assert publisher.returncode == 0, (out, err)
        assert lock.read_bytes() == b"new\xff\x00"
        assert not staged.exists()
    finally:
        for process in (holder, publisher):
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()

print("Update preflight, concurrent authority CAS, immutable gen and crash "
      "lock release tests passed (stubbed Nix/compiler)")
