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
ROC = str(Path(ROC).resolve())

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
import json, os, re, sys
from pathlib import Path
args = sys.argv[1:]
with Path("nix-calls.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:3] == ["flake", "update", "--flake"]:
    assert len(args) == 4 and args[3].startswith("path:/"), args
    generated = Path(args[3].removeprefix("path:"))
    graph = json.loads(Path(os.environ["NIX_FIXTURE_LOCK"]).read_text())
    # Reuse real fixture pins, but map the declared root input names. This
    # remote overlay is deliberately mocked: no Nix evaluation is claimed.
    graph["nodes"]["foreign-overlay"] = {
        "original": {"type": "github", "owner": "example",
                     "repo": "unused-overlay"},
        "locked": {"type": "github", "owner": "example",
                   "repo": "unused-overlay", "rev": "a" * 40,
                   "narHash": graph["nodes"]["nixpkgs"]["locked"]["narHash"]},
    }
    fixtures = {
        "github:NixOS/nixpkgs/nixos-unstable": "nixpkgs",
        "github:example/unused-overlay": "foreign-overlay",
    }
    declared = re.findall(
        r'"([^"\\n]+)" = \\{ url = "([^"\\n]+)"; flake = true; \\};',
        generated.joinpath("flake.nix").read_text(),
    )
    assert declared, "stub expected the fixture's declared flake inputs"
    graph["nodes"]["root"]["inputs"] = {
        name: fixtures[url] for name, url in declared
    }
    generated.joinpath("flake.lock").write_text(json.dumps(graph))
elif args[:1] == ["develop"]:
    if os.environ.get("NIX_FAIL"):
        print("native package command failed", file=sys.stderr)
        sys.exit(23)
else:
    raise SystemExit(f"unexpected Nix invocation: {args}")
""")
    guix = bin_dir / "guix"
    guix.write_text(f"#!{sys.executable}\n" + '''
from pathlib import Path
Path("guix-calls.jsonl").write_text("[]\\n")
raise SystemExit(99)
''')
    wire_roc = bin_dir / "roc-wire"
    wire_roc.write_text(f"#!{sys.executable}\n" + '''
import os, sys
from pathlib import Path
if sys.argv[1:] == ["version"]:
    print(os.environ["ROC_VERSION"], end="")
else:
    print(Path("wire.scm").read_text(), end="")
''')
    for executable in (roc_wrapper, nix, guix, wire_roc):
        executable.chmod(0o755)
    env = dict(os.environ, REAL_ROC=ROC, ROC=str(roc_wrapper),
               ROC_VERSION=subprocess.check_output([ROC, "version"], text=True),
               NIX_FIXTURE_LOCK=str(ROOT / "fixtures/consumer/inputs.lock"),
               PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}")

    def authority(cwd):
        lock = cwd / "Blueprint.lock"
        if not lock.exists():
            return None
        stat = lock.stat()
        return lock.read_bytes(), stat.st_ino, stat.st_mtime_ns

    def run(*args, status=0, cwd=work, overrides=None):
        before = authority(cwd)
        result = subprocess.run(
            [str(BLUEPRINT), *args], cwd=cwd, env=env | (overrides or {}),
            capture_output=True, text=True, timeout=60,
        )
        output = result.stdout + result.stderr
        assert result.returncode == status, (args, result.returncode, output)
        if args != ("update",):
            assert authority(cwd) == before, (args, "authority changed")
        return output

    def calls(tool, cwd=work):
        log = cwd / f"{tool}-calls.jsonl"
        return ([json.loads(line) for line in log.read_text().splitlines()]
                if log.exists() else [])

    def update(cwd=work):
        run("update", cwd=cwd)
        assert calls("nix", cwd) == [
            ["flake", "update", "--flake", f"path:{cwd}/.blueprint"],
        ]
        lock = cwd / "Blueprint.lock"
        envelope = json.loads(lock.read_text())
        native = json.loads((cwd / ".blueprint/flake.lock").read_text())
        assert envelope["version"] == 1 and envelope["nix"] == native
        lock.chmod(0o444)
        (cwd / "nix-calls.jsonl").unlink()

    def develop(cwd, entry, *command):
        argv = ["develop", "--no-update-lock-file", "--no-write-lock-file",
                f"path:{cwd}/.blueprint#devShells.x86_64-linux.{entry}"]
        return argv + (["--command", *command] if command else [])

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
    assert "workflow" in run("--help")
    assert "workflow" in run("workflow", "--help")
    run("workflow", status=2)
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
    compiler_calls = calls("roc")
    assert [call for call in compiler_calls if call != ["version"]] == [
        ["Blueprint.roc"], ["check", "Blueprint.roc"],
    ]
    assert ["version"] in compiler_calls
    untouched(work)

    # A missing/wrong compiler fails before evaluating any configuration.
    pin = (ROOT / ".roc-version").read_text().strip()
    probe = bin_dir / "roc-probe"
    probe.write_text(f"#!{sys.executable}\n" + '''
import json, os, sys
from pathlib import Path
with Path("roc-calls.jsonl").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
assert sys.argv[1:] == ["version"], "config ran with an unverified compiler"
print(os.environ["PROBE_VERSION"])
sys.exit(int(os.environ.get("PROBE_STATUS", "0")))
''')
    probe.chmod(0o755)
    for name, overrides, diagnostic in [
        ("missing", {"ROC": str(bin_dir / "missing")}, "could not probe"),
        ("wrong", {"ROC": str(probe),
                   "PROBE_VERSION": "Roc compiler version other-nightly"},
         "incompatible ROC executable"),
        ("malformed", {"ROC": str(probe), "PROBE_VERSION": pin},
         "incompatible ROC executable"),
        ("failed", {"ROC": str(probe), "PROBE_STATUS": "19",
                    "PROBE_VERSION": env["ROC_VERSION"]}, "could not probe"),
    ]:
        cwd = isolated(f"compiler-{name}")
        settings(valid, cwd)
        output = run("ir", status=1, cwd=cwd, overrides=overrides)
        assert diagnostic in output and pin in output and "set ROC" in output
        assert calls("roc", cwd) == ([] if name == "missing"
                                      else [["version"]])
        untouched(cwd)
        assert "blueprint" in run("--help", cwd=cwd, overrides=overrides)
        assert re.fullmatch(r"\d+\.\d+\.\d+(?:-\S+)?\s*",
                            run("--version", cwd=cwd, overrides=overrides))

    # ROC is invocation-relative even when BLUEPRINT_ROOT selects elsewhere.
    cwd = isolated("compiler-relative-root")
    settings(valid, cwd)
    (work / "roc-calls.jsonl").unlink()
    output = run("check", overrides={"ROC": "./bin/roc-record",
                                    "BLUEPRINT_ROOT": str(cwd)})
    assert "Blueprint.roc is valid" in output
    assert calls("roc") and all(call == ["version"] for call in calls("roc"))
    assert [call for call in calls("roc", cwd) if call != ["version"]] == [
        ["Blueprint.roc"], ["check", "Blueprint.roc"],
    ]
    untouched(cwd)

    # First use cannot initialize pins implicitly, even for plain generation.
    for command in [("gen",), ("shell", "ci"), ("run", "echo-args")]:
        output = run(*command, status=1)
        assert "missing authoritative lock" in output, output
        assert "blueprint update" in output, output
        untouched(work)
    update()
    run("gen")
    assert calls("nix") == []
    run("shell", "ci")
    assert calls("nix") == [develop(work, "ci")]
    (work / "nix-calls.jsonl").unlink()
    run("run", "echo-args", "--", "first", "two words", "--literal", "")
    assert calls("nix") == [
        develop(work, "blueprint-env-ci", "printf", "%s\n",
                "configured argument", "first", "two words", "--literal", ""),
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
    workflow = '((name "ci") (steps ((RunTask "echo-args" ()))))'
    workflow_wire = (wire.replace("(minor 0)", "(minor 2)")[:-1]
                     + f'(requires ("workflows")) (workflows ({workflow})))')
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
        ("workflow-marker", workflow_wire.replace(
            '(requires ("workflows"))', ''),
         "workflows require feature: workflows"),
        ("workflow-tag", workflow_wire.replace('RunTask "echo-args" ()',
                                              'FutureStep "echo-args"'),
         "could not read the IR from Blueprint.roc"),
        ("workflow-cycle", workflow_wire.replace(
            workflow, workflow + ' ((name "unused") '
            '(steps ((RunWorkflow "unused"))))'),
         "workflow cycle: unused -> unused"),
        ("workflow-requires", workflow_wire.replace(
            '(requires ("workflows"))',
            '(requires ("workflows" "workflows-v2"))'),
         "needs features: workflows-v2"),
        ("workflow-major", workflow_wire.replace('(major 2)', '(major 3)'),
         "IR format 3.2"),
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

    # A future minor preserves known workflow steps, rather than ignoring them.
    cwd = isolated("wire-workflow-future-minor")
    (cwd / "Blueprint.roc").touch()
    (cwd / "wire.scm").write_text(
        workflow_wire.replace("(minor 2)", "(minor 999)")
    )
    output = run("ir", cwd=cwd, overrides={"ROC": str(wire_roc)})
    assert "(minor 999)" in output and '(RunTask "echo-args" ())' in output
    assert '(workflows (' in output, output
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
        for command in [("shell", "ci"), ("run", "echo-args")]:
            cwd = isolated(f"closure-{alias}-{command[0]}")
            settings(valid + foreign, cwd)
            update(cwd)
            # Adding an alias does not change input/overlay lock identity.
            # Full update cannot select Guix; this Nix request must not either.
            if alias:
                settings(valid + foreign
                         + 'Shell("foreign", [Use("foreign")]),', cwd)
            run(*command, cwd=cwd)
            expected = develop(cwd, "ci") if command[0] == "shell" else develop(
                cwd, "blueprint-env-ci", "printf", "%s\n",
                "configured argument",
            )
            assert calls("nix", cwd) == [expected]
            assert calls("guix", cwd) == []
            rendered = (cwd / ".blueprint/flake.nix").read_text()
            assert "python@3.12:out" not in rendered
            assert "blueprint-env-foreign" not in rendered
            # Stable declarations may mention an unused overlay, but neither
            # the selected package imports nor their overlay stack may use it.
            outputs = rendered.split("  outputs =", 1)[1]
            assert "foreign-overlay" not in outputs
            assert 'overlays = [  ];' in outputs

    # Pure layout validation must precede even lock reads and source/snapshot
    # effects. The generated directory may contain work, but its files may not.
    for filename in ("flake.nix", "flake.lock", "build-runner.py"):
        for suffix in ("", "/child"):
            for command in [("gen",), ("build", "app"), ("update",)]:
                cwd = isolated(f"collision-{filename}-{bool(suffix)}-{command[0]}")
                settings(valid + '''Build("app", [Use("ci"), Run(["true"]),
                                                     Output("result")]),''', cwd)
                generated = cwd / "generated"
                output = run(*command, status=1, cwd=cwd, overrides={
                    "BLUEPRINT_GENERATED_ROOT": str(generated),
                    "BLUEPRINT_WORKSPACE": str(generated / filename) + suffix,
                })
                assert "must not overlap" in output, output
                assert not generated.exists(), "collision caused staging"
                untouched(cwd)

    # A failed native command is final: no retries, package translation or
    # switching to the installed Guix stub. Preserve its diagnostic and code.
    for command, diagnostic in [
        (("shell", "ci"), "exited with code 23"),
        (("run", "echo-args"), "task echo-args exited with code 23"),
    ]:
        cwd = isolated(f"no-fallback-{command[0]}")
        settings(valid, cwd)
        update(cwd)
        output = run(*command, status=1, cwd=cwd, overrides={"NIX_FAIL": "1"})
        assert "native package command failed" in output, output
        assert diagnostic in output, output
        expected = develop(cwd, "ci")
        if command[0] == "run":
            expected = develop(cwd, "blueprint-env-ci", "printf", "%s\n",
                               "configured argument")
        assert calls("nix", cwd) == [expected]
        assert calls("guix", cwd) == []

    # The workflow executor consumes one complete plan, never reloads per step.
    cwd = isolated("workflow-single-load")
    settings(valid + '''Workflow("ci", [RunTask("echo-args", ["", "--"]),
                                      RunWorkflow("again")]),
        Workflow("again", [RunTask("echo-args", ["line\\nbreak", "a'b\\\"c"])]),''', cwd)
    assert "unknown workflow: absent" in run("workflow", "absent", cwd=cwd, status=1)
    untouched(cwd)
    update(cwd)
    (cwd / "roc-calls.jsonl").unlink()
    run("workflow", "ci", cwd=cwd)
    assert calls("roc", cwd) == [["version"], ["Blueprint.roc"]]
    assert calls("nix", cwd) == [
        develop(cwd, "blueprint-env-ci", "printf", "%s\n", "configured argument",
                "", "--"),
        develop(cwd, "blueprint-env-ci", "printf", "%s\n", "configured argument",
                "line\nbreak", "a'b\"c"),
    ]

print("CLI compiler/loader, validation and stubbed process-boundary tests passed")
