#!/usr/bin/env python3
"""What `blueprint build` stages about its caller, with recorded Nix/Roc stubs.

The stubbed Nix never builds: these cases observe only what `blueprint build`
stages before it runs the provider, namely the caller's namespace identities
and the CLI's own executable as the build runner. B2/B3 run the staged builds
with real Nix, including the project filter. PATH holds the stubs, `readlink`
and a `python3` that records any use, so the CLI is shown to need no Python
or `chmod` of its own.
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


with tempfile.TemporaryDirectory(prefix="blueprint-isolation-") as temp:
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
    (tools / "readlink").symlink_to(shutil.which("readlink"))
    calls = work / "nix-calls"
    env = {
        "PATH": str(tools), "HOME": str(work), "ROC": str(tools / "roc"),
        "ROC_VERSION": ROC_VERSION, "WIRE": WIRE, "CALLS": str(calls),
        "STORE": STORE, "NO_COLOR": "1",
        "FIXTURE": str(ROOT / "blueprint-nix/tests/local.nix-lock.json"),
    }

    def run(root, *args, extra=None, binary=BLUEPRINT):
        return subprocess.run([str(binary), *args], cwd=root,
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

    def state(root):
        """Everything under the generated root, by bytes and inode."""
        return {
            str(file.relative_to(root)): (file.read_bytes(), file.stat().st_ino)
            for file in (root / ".blueprint").rglob("*") if file.is_file()
        }

    def refused(root, message, extra=None, binary=BLUEPRINT):
        """A refused build never reaches the provider or restages anything."""
        before = builds(), state(root)
        result = run(root, "build", "app", extra=extra, binary=binary)
        assert result.returncode == 1 and message in result.stderr, result
        assert (builds(), state(root)) == before, "refused build had effects"
        return result

    # An ordinary build stages its caller's namespaces and its own executable.
    root = project("ordinary")
    sources = {"plain": 0o644, "tool": 0o755, "odd": 0o654, "setuid": 0o4755,
               "nested/deep/file": 0o640}
    for relative, mode in sources.items():
        file = root / relative
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(relative.encode() + b"\xff\x00\n")
        file.chmod(mode)
    (root / ".blueprint/excluded-secret").write_bytes(b"workspace excluded\n")
    before = builds()
    result = run(root, "build", "app")
    assert result.returncode == 0, result.stderr
    assert result.stdout == STORE + "\n", result.stdout
    assert builds() == before + 1
    flake = (root / ".blueprint/flake.nix").read_text()
    namespaces = {name: os.readlink(f"/proc/self/ns/{name}")
                  for name in ("net", "mnt")}
    assert 'isolation = {{ mnt = "{mnt}"; net = "{net}"; }};'.format(
        **namespaces) in flake, flake
    assert ('runner = builtins.path { path = /. + "%s"; '
            'name = "blueprint-runner"; };' % BLUEPRINT) in flake, flake
    assert "@blueprint-caller" not in flake, flake
    # Nix reads the project where it is, minus caller-generated state.
    assert f'path = /. + "{root}";' in flake, flake
    assert (f'|| builtins.elem path [ "{root}/.blueprint" '
            f'"{root}/Blueprint.lock" ])') in flake, flake
    assert 'throw "snapshot refuses symlink: ${path}"' in flake, flake
    assert 'throw "snapshot refuses special file: ${path}"' in flake, flake
    # The CLI copies nothing: no snapshot, witness file or runner in its state.
    assert sorted(p.name for p in (root / ".blueprint").iterdir()) == [
        "excluded-secret", "flake.lock", "flake.nix"]
    for relative, mode in sources.items():
        assert (root / relative).stat().st_mode & 0o7777 == mode, relative
        assert (root / relative).stat().st_nlink == 1, relative
    # An unchanged caller stages identical bytes, so Nix can reuse the build.
    assert run(root, "build", "app").returncode == 0
    assert (root / ".blueprint/flake.nix").read_text() == flake

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
    empty = work / "no-readlink"
    empty.mkdir()
    for name in ("roc", "nix", "python3"):
        (empty / name).symlink_to(tools / name)
    refused(root, "cannot observe caller build isolation",
            extra={"PATH": str(empty)})

    # The runner's path is placed in generated text, so an executable whose
    # path could be read as anything but a path is refused, not escaped.
    for name in ('quo"te', "dol$lar", "back\\slash"):
        odd = work / name
        odd.mkdir()
        shutil.copy2(BLUEPRINT, odd / "blueprint")
        refused(root, f"blueprint cannot run builds from {odd}/blueprint",
                binary=odd / "blueprint")

    # A symlinked generated root is refused, not followed.
    root = project("linked-workspace")
    real = work / "real-workspace"
    real.mkdir()
    (root / "work").symlink_to(real, target_is_directory=True)
    before = builds()
    result = run(root, "build", "app", extra={"BLUEPRINT_WORKSPACE": "work"})
    assert result.returncode == 1 and "unsafe" in result.stderr, result
    assert builds() == before and not list(real.iterdir())

    # The runner is internal: absent from help, and usable with no project,
    # compiler or provider at hand.
    assert "__build-runner" not in run(root, "--help").stdout
    bare = work / "bare"
    bare.mkdir()
    result = run(bare, "__build-runner", extra={"PATH": str(bare)})
    assert result.returncode == 1, result
    assert result.stderr == "blueprint build: missing build specification\n"
    result = run(bare, "__build-runner", "a", "b", extra={"PATH": str(bare)})
    assert result.returncode == 1, result
    assert result.stderr == "blueprint build: expected one build specification\n"

    assert not used_python.exists(), used_python.read_text()

print("Build isolation witness, runner path and refusal tests passed without "
      "a host Python or chmod (stubbed Nix/compiler)")
