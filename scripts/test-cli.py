#!/usr/bin/env python3
"""Real CLI/compiler tests with stubbed Nix/Guix process boundaries."""
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
import json, os, sys
from pathlib import Path
with Path("nix-calls.jsonl").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:] == ["flake", "lock", "path:.blueprint"]:
    Path(".blueprint/flake.lock").write_text("{}")
if sys.argv[1:2] == ["develop"] and os.environ.get("NIX_FAIL"):
    print("native package command failed", file=sys.stderr)
    sys.exit(23)
""")
    guix = bin_dir / "guix"
    guix.write_text(f"#!{sys.executable}\n" + '''
from pathlib import Path
Path("guix-calls.jsonl").write_text("[]\\n")
raise SystemExit(99)
''')
    wire_roc = bin_dir / "roc-wire"
    wire_roc.write_text(f"#!{sys.executable}\n" + '''
from pathlib import Path
print(Path("wire.scm").read_text(), end="")
''')
    for executable in (roc_wrapper, nix, guix, wire_roc):
        executable.chmod(0o755)
    env = dict(os.environ, REAL_ROC=ROC, ROC=str(roc_wrapper),
               PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}")

    def run(*args, status=0, cwd=work, overrides=None):
        result = subprocess.run(
            [str(BLUEPRINT), *args], cwd=cwd, env=env | (overrides or {}),
            capture_output=True, text=True, timeout=60,
        )
        output = result.stdout + result.stderr
        assert result.returncode == status, (args, result.returncode, output)
        return output

    def calls(tool, cwd=work):
        log = cwd / f"{tool}-calls.jsonl"
        return ([json.loads(line) for line in log.read_text().splitlines()]
                if log.exists() else [])

    def untouched(cwd):
        assert calls("nix", cwd) == []
        assert calls("guix", cwd) == []
        assert not (cwd / ".blueprint").exists()
        assert not (cwd / "Blueprint.lock").exists()

    def isolated(name):
        cwd = work / name
        cwd.mkdir()
        return cwd

    # These must work without Blueprint.roc: dropping argv[0] used to lose them.
    assert re.fullmatch(r"\d+\.\d+\.\d+(?:-\S+)?\s*", run("--version"))
    assert "blueprint" in run("--help")
    run("unknown-command", status=2)
    assert "there is no Blueprint.roc" in run("tasks", status=1)

    def settings(body, cwd=work):
        platform = os.path.relpath(ROOT / "blueprint-ir-platform/main.roc", cwd)
        (cwd / "Blueprint.roc").write_text(
            f'app [config] {{ pf: platform "{platform}" }}\n'
            f'config = [{body}]\n'
        )

    valid = '''
        Name("argument-test"),
        Environment("ci", [Tools(["git"])]),
        Shell("default", [Use("ci")]),
        Shell("ci", [Use("ci")]),
        Task("echo-args", [Run(["printf", "%s\\n", "configured argument"]), Use("ci")]),
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
        ["develop", "path:.blueprint#blueprint-env-ci", "-c", "printf", "%s\n",
         "configured argument", "first", "two words", "--literal", ""],
    ]

    # Reusing the initially loaded IR must still reject unsupported features.
    settings(valid + 'Custom("services", "demo", Str("value")),')
    assert "needs features: extensions" in run("check", status=1)
    settings('Environment("ci", [Tools(["git"])]), Shell("default", [Use("ci")])')
    assert "MissingName" in run("check", status=1)
    settings(valid + 'Shell("default", [Use("ci")])')
    assert "DuplicateShell" in run("check", status=1)

    # Raw remains supported as data; Custom must never silently disappear.
    settings(valid + '''Raw("nix", "shell:default",
        Attrs([("TEST_MODE", Str("raw-value"))])),''')
    assert "raw-value" in run("flake")
    settings(valid + 'Raw("nix", "unknown", Attrs([])),')
    assert "unknown raw nix target" in run("check", status=1)

    # The real loader must distrust wire data even if a compiler emits it.
    wire = '''((format ((major 2) (minor 0))) (name "wire")
        (systems ("x86_64-linux"))
        (sources (((name "default") (provider Auto))))
        (environments (((name "ci") (parents ()) (tools ()) (overlays ()))))
        (shells (((name "default") (environment "ci"))))
        (tasks (((name "echo-args") (environment "ci") (run ("true"))))))'''
    environment = '((name "ci") (parents ()) (tools ()) (overlays ()))'
    rejected = [
        ("major-1", wire.replace("(major 2)", "(major 1)"), "IR format 1.0"),
        ("major-3", wire.replace("(major 2)", "(major 3)"), "IR format 3.0"),
        ("requires", wire[:-1] + '(requires ("future-operation")))',
         "needs features: future-operation"),
        ("reference", wire.replace('(environment "ci")',
                                   '(environment "missing")'),
         "unknown environment: missing"),
        ("duplicate", wire.replace(environment, f"{environment} {environment}"),
         "DuplicateEnvironment: ci"),
        ("empty-argv", wire.replace('(run ("true"))', '(run ())'),
         "empty argv: echo-args"),
        ("empty-program", wire.replace('(run ("true"))', '(run (""))'),
         "empty argv: echo-args"),
    ]
    for name, text, diagnostic in rejected:
        cwd = isolated(f"wire-{name}")
        (cwd / "Blueprint.roc").touch()
        (cwd / "wire.scm").write_text(text)
        output = run("run", "echo-args", status=1, cwd=cwd,
                     overrides={"ROC": str(wire_roc)})
        assert diagnostic in output, output
        untouched(cwd)

    # Same-major future minors and optional fields remain forward compatible.
    cwd = isolated("wire-future-minor")
    (cwd / "Blueprint.roc").touch()
    (cwd / "wire.scm").write_text(
        wire.replace("(minor 0)", "(minor 999)")[:-1]
        + '(future-field (Future "ignored")))'
    )
    output = run("ir", cwd=cwd, overrides={"ROC": str(wire_roc)})
    assert "(minor 999)" in output, output
    assert '(name "wire")' in output, output
    untouched(cwd)

    # Request checks precede every Nix, workspace and lock effect. These use
    # the real compiler: Auto grammar is deliberately checked after selection.
    incompatible = [
        ("source", 'Packages("default", From(GuixPackages("current"))),',
         "git", "source default requires Guix, not Nix"),
        ("auto-grammar", 'Packages("default", Auto),',
         "python@3.12:out", "invalid Nix tool: python@3.12:out"),
        ("target", 'Systems(["riscv64-linux"]),',
         "git", "unsupported Nix target riscv64-linux"),
    ]
    for name, declaration, tool, diagnostic in incompatible:
        for command in [("shell", "ci"), ("run", "echo-args")]:
            cwd = isolated(f"{name}-{command[0]}")
            settings(valid.replace('Tools(["git"])', f'Tools(["{tool}"])')
                     + declaration, cwd)
            output = run(*command, status=1, cwd=cwd)
            assert diagnostic in output, output
            untouched(cwd)

    # Unselected Guix environments, including ones with shell aliases, must
    # not contaminate a Nix task/shell's requested dependency closure.
    foreign = '''Packages("foreign", From(GuixPackages("current"))),
        Overlay("foreign-overlay", "github:example/unused-overlay"),
        Environment("foreign", [Tools(["foreign#python@3.12:out"]),
                                Overlays(["foreign-overlay"])]),'''
    for alias in (False, True):
        for command, expected in [
            (("shell", "ci"), ["develop", "path:.blueprint#ci"]),
            (("run", "echo-args"),
             ["develop", "path:.blueprint#blueprint-env-ci", "-c", "printf",
              "%s\n", "configured argument"]),
        ]:
            cwd = isolated(f"closure-{alias}-{command[0]}")
            settings(valid + foreign + (
                'Shell("foreign", [Use("foreign")]),' if alias else ""
            ), cwd)
            run(*command, cwd=cwd)
            assert calls("nix", cwd) == [
                ["flake", "lock", "path:.blueprint"], expected,
            ]
            assert calls("guix", cwd) == []
            rendered = (cwd / ".blueprint/flake.nix").read_text()
            assert "python@3.12:out" not in rendered
            assert "blueprint-env-foreign" not in rendered
            assert "foreign-overlay" not in rendered

    # A failed native command is final: no retries, package translation or
    # switching to the installed Guix stub. Preserve its diagnostic and code.
    for command, diagnostic in [
        (("shell", "ci"), "exited with code 23"),
        (("run", "echo-args"), "task echo-args exited with code 23"),
    ]:
        cwd = isolated(f"no-fallback-{command[0]}")
        settings(valid, cwd)
        output = run(*command, status=1, cwd=cwd, overrides={"NIX_FAIL": "1"})
        assert "native package command failed" in output, output
        assert diagnostic in output, output
        expected = ["develop", "path:.blueprint#ci"]
        if command[0] == "run":
            expected = ["develop", "path:.blueprint#blueprint-env-ci", "-c",
                        "printf", "%s\n", "configured argument"]
        assert calls("nix", cwd) == [
            ["flake", "lock", "path:.blueprint"], expected,
        ]
        assert calls("guix", cwd) == []

print("CLI compiler/loader, validation and stubbed process-boundary tests passed")
