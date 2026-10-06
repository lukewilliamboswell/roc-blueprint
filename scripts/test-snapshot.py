#!/usr/bin/env python3
"""Real CLI build snapshots and isolation witness with recorded Nix/Roc stubs.

The stubbed Nix never builds: these cases observe only what `blueprint build`
materializes before it runs the provider. B2/B3 build the same snapshots with
real Nix. PATH holds the stubs, `chmod`, `readlink` and a `python3` that
records any use, so the CLI is shown to need no Python of its own.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BLUEPRINT = ROOT / "blueprint"
ROC = shutil.which(os.environ.get("ROC", "roc"))
if ROC is None:
    raise SystemExit("Roc compiler not found")
ROC_VERSION = subprocess.check_output([str(Path(ROC).resolve()), "version"],
                                      text=True)
WIRE = '''((format ((major 2) (minor 1))) (name "wire")
(requires ("builds"))
(systems ("x86_64-linux"))
(sources (((name "default") (provider Auto))))
(environments (((name "ci") (parents ()) (tools ()) (overlays ()))))
(shells (((name "default") (environment "ci"))))
(builds (((name "app") (environment "ci") (inputs ()) (needs ())
          (run ("true")) (output "result")))))'''
STORE = "/nix/store/00000000000000000000000000000000-blueprint-app"


def tree(path):
    """Every entry below path, by raw relative name: bytes and exact modes."""
    entries = {}
    for directory, names, files in os.walk(os.fsencode(path)):
        for name in names + files:
            full = os.path.join(directory, name)
            status = os.lstat(full)
            relative = os.path.relpath(full, os.fsencode(path))
            assert not os.path.islink(full), full
            entries[relative] = (
                "dir" if os.path.isdir(full) else
                (oct(status.st_mode & 0o7777), Path(os.fsdecode(full)).read_bytes())
            )
    return entries


with tempfile.TemporaryDirectory(prefix="blueprint-snapshot-") as temp:
    work = Path(temp)
    tools = work / "bin"
    tools.mkdir()
    (tools / "roc").write_text(f"#!{sys.executable}\n" + '''import os, sys
from pathlib import Path
if sys.argv[1:] == ["version"]:
    print(os.environ["ROC_VERSION"], end="")
else:
    assert sys.argv[1:] == ["Blueprint.roc"], sys.argv
    print(os.environ["WIRE"])
''')
    (tools / "nix").write_text(f"#!{sys.executable} -I\n" + '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["CALLS"]).open("a") as out:
    out.write(json.dumps(args) + "\\n")
if args[:3] == ["flake", "update", "--flake"]:
    graph = json.loads(Path(os.environ["FIXTURE"]).read_text())
    del graph["nodes"]["assets"]
    del graph["nodes"]["root"]["inputs"]["assets"]
    Path(args[3].removeprefix("path:")).joinpath("flake.lock").write_text(
        json.dumps(graph))
elif args[:1] == ["build"]:
    print(os.environ["STORE"])
else:
    raise SystemExit(f"unexpected Nix invocation: {args}")
''')
    # Any use of a host Python by the CLI is recorded, then fails.
    used_python = work / "python3-was-used"
    (tools / "python3").write_text(
        f"#!/bin/sh\necho \"$@\" >>{used_python}\nexit 97\n")
    for name in ("roc", "nix", "python3"):
        (tools / name).chmod(0o755)
    for name in ("chmod", "readlink"):
        (tools / name).symlink_to(shutil.which(name))
    calls = work / "nix-calls"
    env = {
        "PATH": str(tools), "HOME": str(work), "ROC": str(tools / "roc"),
        "ROC_VERSION": ROC_VERSION, "WIRE": WIRE, "CALLS": str(calls),
        "STORE": STORE, "NO_COLOR": "1",
        "FIXTURE": str(ROOT / "blueprint-nix/tests/local.nix-lock.json"),
    }

    def run(root, *args, extra=None):
        return subprocess.run([str(BLUEPRINT), *args], cwd=root,
                              env=env | (extra or {}), capture_output=True,
                              text=True, timeout=60)

    def builds():
        if not calls.exists():
            return 0
        lines = calls.read_text().splitlines()
        return sum(json.loads(line)[:1] == ["build"] for line in lines)

    def project(name):
        root = work / name
        root.mkdir()
        (root / "Blueprint.roc").write_text("stub\n")
        result = run(root, "update")
        assert result.returncode == 0, result.stderr
        return root

    def refused(root, message, extra=None):
        """A refused snapshot never reaches the provider or leaves staging."""
        before = builds()
        result = run(root, "build", "app", extra=extra)
        assert result.returncode == 1 and message in result.stderr, result
        assert builds() == before, "provider ran after a refused snapshot"
        leftovers = [p for p in root.rglob(".snapshot-*")]
        assert not leftovers, leftovers
        return result

    # Bytes, modes, exclusions and the witness of an ordinary project.
    root = project("ordinary")
    snapshot = root / ".blueprint/snapshot"
    sidecar = root / ".blueprint/snapshot.isolation.json"
    sources = {
        "plain": (0o644, 0o644), "tool": (0o755, 0o755),
        "odd": (0o654, 0o755), "world-only": (0o604 | 0o001, 0o755),
        "read-only": (0o444, 0o644), "private": (0o600, 0o644),
        "private-tool": (0o700, 0o755), "sticky-bits": (0o4755, 0o755),
        "nested/deep/file": (0o640, 0o644),
    }
    for relative, (mode, _) in sources.items():
        file = root / relative
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(relative.encode() + b"\xff\x00\n")
        file.chmod(mode)
    (root / "empty").mkdir()
    (root / "big").write_bytes(os.urandom(300_000))
    raw = os.fsencode(root) + b"/not-utf8-\xff"
    Path(os.fsdecode(raw)).write_bytes(b"raw name\n")
    # Bare names apply at every depth; absolute paths only where they point.
    for hidden in (".git", ".hg", ".svn", ".jj", "nested/.git", "nested/deep/.jj"):
        (root / hidden).mkdir(parents=True)
        (root / hidden / "secret").write_bytes(b"VCS excluded\n")
    (root / "nested/.blueprint").mkdir()
    (root / "nested/.blueprint/kept").write_bytes(b"not the workspace\n")
    (root / "nested/Blueprint.lock").write_bytes(b"not the authority\n")
    (root / ".blueprint/excluded-secret").write_bytes(b"workspace excluded\n")
    before = builds()
    result = run(root, "build", "app")
    assert result.returncode == 0, result.stderr
    assert result.stdout == STORE + "\n", result.stdout
    assert builds() == before + 1
    expected = {
        os.fsencode(relative): (oct(mode), relative.encode() + b"\xff\x00\n")
        for relative, (_, mode) in sources.items()
    } | {
        b"Blueprint.roc": ("0o644", b"stub\n"),
        b"big": ("0o644", (root / "big").read_bytes()),
        b"not-utf8-\xff": ("0o644", b"raw name\n"),
        b"nested/.blueprint/kept": ("0o644", b"not the workspace\n"),
        b"nested/Blueprint.lock": ("0o644", b"not the authority\n"),
    } | {name: "dir" for name in (
        b"empty", b"nested", b"nested/deep", b"nested/.blueprint")}
    assert tree(snapshot) == expected, tree(snapshot)
    # Exactly what Python's json.dumps(..., sort_keys=True) + "\n" wrote.
    namespaces = {name: os.readlink(f"/proc/self/ns/{name}")
                  for name in ("net", "mnt")}
    witness = sidecar.read_bytes()
    assert witness == (json.dumps(namespaces, sort_keys=True) + "\n").encode()
    assert witness == b'{"mnt": "%s", "net": "%s"}\n' % (
        namespaces["mnt"].encode(), namespaces["net"].encode()), witness
    # The witness and directories take ordinary umask-derived modes.
    for made, ordinary in ((sidecar, calls), (snapshot, root / "empty"),
                           (snapshot / "nested", root / "empty")):
        assert made.stat().st_mode == ordinary.stat().st_mode, made
    assert not list(root.rglob(".snapshot-*"))
    # Sources are copied, never moved, linked or re-moded.
    for relative, (mode, _) in sources.items():
        assert (root / relative).stat().st_mode & 0o7777 == mode, relative
        assert (root / relative).stat().st_nlink == 1, relative

    # Each build replaces the whole tree; an unchanged caller keeps its witness.
    (root / "plain").unlink()
    (root / "tool").chmod(0o644)
    (snapshot / "stale").write_bytes(b"left by an earlier build\n")
    assert run(root, "build", "app").returncode == 0
    del expected[b"plain"]
    expected[b"tool"] = ("0o644", expected[b"tool"][1])
    assert tree(snapshot) == expected, tree(snapshot)
    assert sidecar.read_bytes() == witness, "witness defeats build caching"

    # Symlinks and special files are refused wherever they are; a failed
    # snapshot leaves the published tree and witness exactly as they were.
    published = tree(snapshot), sidecar.read_bytes(), sidecar.stat().st_ino
    for kind in ("file-link", "dir-link", "dangling", "fifo"):
        for where in ("", "nested/deep/"):
            bad = root / f"{where}bad"
            if kind == "fifo":
                os.mkfifo(bad)
                message = f"snapshot refuses special file: {bad}"
            else:
                target = {"file-link": root / "odd", "dir-link": root / "empty",
                          "dangling": root / "absent"}[kind]
                bad.symlink_to(target)
                message = f"snapshot refuses symlink: {bad}"
            refused(root, message)
            bad.unlink()
            assert (tree(snapshot), sidecar.read_bytes(),
                    sidecar.stat().st_ino) == published, (kind, where)
    # An excluded name is never inspected, so a link there is not refused.
    (root / ".git/link").symlink_to(root / "odd")
    assert run(root, "build", "app").returncode == 0
    assert tree(snapshot) == expected

    # Isolation that cannot be observed or is malformed stops before staging.
    for script, message in [
        ("exit 1", "cannot observe caller build isolation; use Linux with "
                   "readable /proc/self/ns/mnt"),
        ("echo 'mnt:[]'", "invalid caller mnt namespace identity"),
        ("echo 'mnt:[1] '", "invalid caller mnt namespace identity"),
        ('case "$1" in */mnt) echo "mnt:[1]";; *) echo "mnt:[1]";; esac',
         "invalid caller net namespace identity"),
    ]:
        shadow = work / "shadow"
        shadow.mkdir()
        (shadow / "readlink").write_text(f"#!/bin/sh\n{script}\n")
        (shadow / "readlink").chmod(0o755)
        refused(root, message, extra={"PATH": f"{shadow}{os.pathsep}{tools}"})
        shutil.rmtree(shadow)
        assert (tree(snapshot), sidecar.read_bytes()) == published[:2]
    empty = work / "no-readlink"
    empty.mkdir()
    for name in ("roc", "nix", "python3", "chmod"):
        (empty / name).symlink_to(tools / name)
    refused(root, "cannot observe caller build isolation",
            extra={"PATH": str(empty)})

    # Occupied destinations are refused, not replaced or followed.
    root = project("occupied-tree")
    (root / ".blueprint/snapshot").write_bytes(b"a file\n")
    refused(root, "snapshot destination is not a directory: "
                  f"{root}/.blueprint/snapshot")
    assert (root / ".blueprint/snapshot").read_bytes() == b"a file\n"
    root = project("occupied-witness")
    (root / ".blueprint/snapshot.isolation.json").mkdir()
    refused(root, "isolation witness is not a file: "
                  f"{root}/.blueprint/snapshot.isolation.json")
    assert not (root / ".blueprint/snapshot").exists()
    outside = work / "outside"
    outside.mkdir()
    for name in ("snapshot", "snapshot.isolation.json"):
        root = project(f"linked-{name}")
        (root / ".blueprint" / name).symlink_to(outside)
        refused(root, "unsafe")
        assert not list(outside.iterdir())
    root = project("linked-workspace")
    real = work / "real-workspace"
    real.mkdir()
    (root / "work").symlink_to(real, target_is_directory=True)
    refused(root, "unsafe", extra={"BLUEPRINT_WORKSPACE": "work"})
    assert not list(real.iterdir())

    assert not used_python.exists(), used_python.read_text()

print("Build snapshot bytes, modes, exclusions, refusals and isolation witness "
      "tests passed without a host Python (stubbed Nix/compiler)")
