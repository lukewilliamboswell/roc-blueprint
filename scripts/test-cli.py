#!/usr/bin/env python3
"""Exercise real CLI parsing; record Nix argv without entering a dev shell."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BLUEPRINT = ROOT / "blueprint"
ROC = shutil.which(os.environ.get("ROC", "roc"))
if ROC is None:
    raise SystemExit("Roc compiler not found")

with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    bin_dir = work / "bin"
    bin_dir.mkdir()
    # Use the real Roc, recording calls to catch redundant validation runs.
    roc_wrapper = bin_dir / "roc-record"
    roc_wrapper.write_text(f"#!{sys.executable}\n" + """
import json, os, sys
from pathlib import Path
with Path("roc-calls.jsonl").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
os.execv(os.environ["REAL_ROC"], [os.environ["REAL_ROC"], *sys.argv[1:]])
""")
    nix = bin_dir / "nix"
    nix.write_text(f"#!{sys.executable}\n" + """
import json, sys
from pathlib import Path
with Path("nix-calls.jsonl").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:] == ["flake", "lock", "path:.blueprint"]:
    Path(".blueprint/flake.lock").write_text("{}")
""")
    for executable in (roc_wrapper, nix):
        executable.chmod(0o755)
    env = dict(os.environ, REAL_ROC=ROC, ROC=str(roc_wrapper),
               PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}")

    def run(*args, status=0):
        result = subprocess.run([str(BLUEPRINT), *args], cwd=work, env=env,
                                capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        assert result.returncode == status, (args, result.returncode, output)
        return output

    def calls(tool):
        return [json.loads(line) for line in
                (work / f"{tool}-calls.jsonl").read_text().splitlines()]

    # These must work without Blueprint.roc: dropping argv[0] used to lose them.
    assert re.fullmatch(r"\d+\.\d+\.\d+(?:-\S+)?\s*", run("--version"))
    assert "blueprint" in run("--help")
    run("unknown-command", status=2)
    assert "there is no Blueprint.roc" in run("tasks", status=1)

    config = work / "Blueprint.roc"
    platform = os.path.relpath(ROOT / "blueprint-ir-platform/main.roc", work)

    def settings(body):
        config.write_text(
            f'app [config] {{ pf: platform "{platform}" }}\n'
            f'config = [{body}]\n'
        )

    valid = '''
        Name("argument-test"),
        Shell("default", [Tools(["git"])]),
        Shell("ci", [Tools(["git"])]),
        Task("echo-args", [Run(["printf", "%s\\n", "configured argument"]), In("ci")]),
    '''
    settings(valid)
    help_output = run("--help")
    assert "argument-test" in help_output, help_output
    assert "echo-args" in run("run", "--help")
    assert "ci" in run("shell", "--help")
    assert "echo-args\t(ci)" in run("tasks")
    assert '(name "argument-test")' in run("ir")
    assert "devShells" in run("flake")
    (work / "roc-calls.jsonl").unlink()
    assert "Blueprint.roc is valid" in run("check")
    assert calls("roc") == [["Blueprint.roc"], ["check", "Blueprint.roc"]]

    run("shell", "ci")
    assert calls("nix") == [
        ["flake", "lock", "path:.blueprint"],
        ["develop", "path:.blueprint#ci"],
    ]
    (work / "nix-calls.jsonl").unlink()
    run("run", "echo-args", "--", "first", "two words", "--literal", "")
    assert calls("nix") == [
        ["flake", "lock", "path:.blueprint"],
        ["develop", "path:.blueprint#ci", "-c", "printf", "%s\n",
         "configured argument", "first", "two words", "--literal", ""],
    ]

    # Reusing the initially loaded IR must still reject unsupported features.
    settings(valid + 'Custom("services", "demo", Str("value")),')
    assert "needs features: extensions" in run("check", status=1)
    settings('Shell("default", [Tools(["git"])])')
    assert "MissingName" in run("check", status=1)
    settings(valid + 'Shell("default", [Tools(["git"])])')
    assert "DuplicateShell" in run("check", status=1)

print("CLI version/help, validation, shell selection and task arguments passed")
