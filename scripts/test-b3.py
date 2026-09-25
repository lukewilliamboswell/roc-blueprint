#!/usr/bin/env python3
"""Real offline Nix workflows. Build ./blueprint and the platform host first.

Requires x86_64 Linux and cached consumer nixpkgs/tool closures. Every CLI,
compiler, task and build is real; the Nix wrapper only records then execs Nix.
Failures retain the project and numbered command logs under caller TMPDIR.
"""

import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "fixtures/workflows"
ARGS = [
    "", "two words", "--", "--literal", "$HOME", "$(touch INJECTED)",
    "; touch INJECTED", "a'b\"c", "line\nbreak", "*", "$",
]
FIRST = b"first\x00revision\n"
SECOND = b"second\x00revision\xff\n"
PREPARED = b"task-generated\x00bytes\n"
EDITED = b"changed by task\x00\xfe\n"
ASSET = b"locked workflow asset\n"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def tree(path):
    """Observe bytes and metadata, including empty directories and the root."""
    if not path.exists():
        return {}
    result = {}
    for entry in [path, *path.rglob("*")]:
        stat = entry.lstat()
        contents = entry.read_bytes() if entry.is_file() else None
        result[str(entry.relative_to(path))] = (
            contents, stat.st_ino, stat.st_mtime_ns, stat.st_mode,
        )
    return result


def task(mode, *args):
    return ("task", [mode, *args])


def record(*args):
    return task("record", "configured argument", *args)


class Suite:
    def __init__(self, work):
        self.work = work
        self.project = work / "project"
        self.caller = work / "unrelated-cwd"
        self.logs = work / "logs"
        self.events = work / "events.jsonl"
        self.workspace = self.project / "work"
        self.generated = self.project / "generated"
        self.lock = self.project / "authority.lock"
        for path in (self.project, self.caller, self.logs, work / "bin"):
            path.mkdir()
        self.count = 0
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("BLUEPRINT_")
        }
        self.env.update(
            BLUEPRINT_ROOT=str(self.project),
            BLUEPRINT_WORKSPACE=str(self.workspace),
            BLUEPRINT_GENERATED_ROOT=str(self.generated),
            BLUEPRINT_LOCK="authority.lock", NO_COLOR="1",
        )
        self.env["NIX_CONFIG"] = self.env.get("NIX_CONFIG", "") + "\nbuilders =\n"
        compiler = shutil.which(self.env.get("ROC", "roc"))
        require(compiler, "Roc is required (use the contributor shell)")
        self.env["ROC"] = str(Path(compiler).resolve())
        nix = shutil.which("nix")
        require(nix, "real Nix is required")
        wrapper = work / "bin/nix"
        wrapper.write_text(
            f"#!{sys.executable}\nimport json, os, sys\n"
            f"with open({str(self.events)!r}, 'a') as log:\n"
            "    log.write(json.dumps({'kind': 'nix', 'argv': sys.argv[1:]}) + '\\n')\n"
            f"os.execv({nix!r}, ['nix', '--offline', *sys.argv[1:]])\n"
        )
        wrapper.chmod(0o755)
        self.env["PATH"] = str(wrapper.parent) + os.pathsep + self.env["PATH"]

    def entries(self):
        if not self.events.exists():
            return []
        return [json.loads(line) for line in self.events.read_text().splitlines()]

    def authority(self):
        if not self.lock.exists():
            return None
        stat = self.lock.stat()
        return self.lock.read_bytes(), stat.st_ino, stat.st_mtime_ns, stat.st_mode

    def command(self, argv, *, good=True):
        self.count += 1
        stem = self.logs / f"{self.count:03d}"
        stem.with_suffix(".argv").write_text(repr(list(map(str, argv))) + "\n")
        result = subprocess.run(
            list(map(str, argv)), cwd=self.caller, env=self.env,
            capture_output=True, timeout=300,
        )
        stem.with_suffix(".out").write_bytes(result.stdout)
        stem.with_suffix(".err").write_bytes(result.stderr)
        require(result.returncode == (0 if good else 1),
                f"{argv}: exit {result.returncode}; logs {stem}.*\n"
                + result.stderr.decode(errors="replace"))
        return result

    def cli(self, *args, good=True, contains=None):
        before = self.authority()
        start = len(self.entries())
        result = self.command([ROOT / "blueprint", *args], good=good)
        if args[0] != "update":
            require(self.authority() == before, f"{args} changed authority")
            for entry in self.entries()[start:]:
                if entry["kind"] != "nix":
                    continue
                argv = entry["argv"]
                require(argv[:2] not in (["flake", "update"], ["flake", "lock"]),
                        f"implicit lock operation: {argv}")
                if argv[0] in ("develop", "build"):
                    require("--no-update-lock-file" in argv
                            and "--no-write-lock-file" in argv, argv)
        if contains:
            require(contains.encode() in result.stderr, result.stderr)
        require(not (self.project / "Blueprint.lock").exists(), "second authority")
        require(not (self.project / "INJECTED").exists(), "argv injection")
        return result

    def workflow(self, name, expected, *, good=True, contains=None):
        start = len(self.entries())
        result = self.cli("workflow", name, good=good, contains=contains)
        observed = []
        commands = []
        for entry in self.entries()[start:]:
            argv = entry["argv"]
            if entry["kind"] == "task":
                observed.append(("task", argv))
            elif argv[0] == "build":
                installables = [arg for arg in argv if "#packages." in arg]
                require(len(installables) == 1, argv)
                observed.append(("build", installables[0].rsplit(".", 1)[1]))
            elif argv[0] == "develop":
                commands.append(argv[argv.index("--command") + 1:])
        require(observed == expected, (name, "effect order", observed, expected))
        task_args = [argv for kind, argv in expected if kind == "task"]
        require(commands == [
            ["python3", "task.py", str(self.events), *argv] for argv in task_args
        ], (name, "task process argv", commands))
        outputs = []
        stdout_events = []
        for line in result.stdout.splitlines():
            if line.startswith(b"/nix/store/"):
                path = Path(os.fsdecode(line))
                require(path.exists(), f"reported artifact missing: {path}")
                outputs.append(path)
                stdout_events.append("build")
            else:
                event = json.loads(line)
                require(event["kind"] == "task", event)
                stdout_events.append(("task", event["argv"]))
        # Failed builds have an invocation but must not publish a store path.
        successful = expected if good or expected[-1][0] != "build" else expected[:-1]
        require(stdout_events == [
            "build" if kind == "build" else (kind, argv)
            for kind, argv in successful
        ], (name, "stdout order", stdout_events))
        return outputs, result

    def artifact(self, output, source, generated):
        require(output.is_dir(), output)
        require(sorted(p.name for p in output.iterdir()) == [
            "argv.json", "library-path", "payload",
        ], output)
        expected_library = b"library\x00" + source
        expected = b"app\x00" + expected_library + b"|" + generated + b"|" + ASSET
        require((output / "payload").read_bytes() == expected,
                f"stale or incorrect artifact bytes: {output}")
        require((output / "argv.json").read_bytes()
                == (json.dumps(ARGS, ensure_ascii=False) + "\n").encode(),
                "build argv changed")
        library = Path((output / "library-path").read_text().strip())
        require(str(library).startswith("/nix/store/") and library.is_file(), library)
        require(library.read_bytes() == expected_library, "stale dependency bytes")
        return library

    def prepare(self):
        seed = json.loads((ROOT / "fixtures/consumer/inputs.lock").read_text())
        pin = seed["nodes"]["nixpkgs"]["locked"]
        ref = f'github:{pin["owner"]}/{pin["repo"]}/{pin["rev"]}'
        self.command(["nix", "flake", "metadata", "--json", ref])
        for relative in ("task.py", "build.py", "assets/message.txt"):
            destination = self.project / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(FIXTURE / relative, destination)
        require((self.project / "assets/message.txt").read_bytes() == ASSET,
                "fixture asset differs from independent expected bytes")
        relative = os.path.relpath(ROOT / "blueprint-platform/main.roc", self.project)
        self.config = (FIXTURE / "Blueprint.roc.in").read_text().replace(
            "@PLATFORM@", relative,
        ).replace("@PACKAGES@", ref).replace("@EVENTS@", str(self.events))
        (self.project / "Blueprint.roc").write_text(self.config)
        (self.project / "source.bin").write_bytes(FIRST)
        self.cli("check")
        for name in ("ci", "empty", "nested-empty"):
            before = self.entries()
            result = self.cli(
                "workflow", name, good=False, contains="blueprint update",
            )
            require(not result.stdout,
                    f"{name}: missing authority produced stdout")
            require(self.entries() == before,
                    f"{name}: missing authority executed an operation")
            require(not self.workspace.exists() and not self.generated.exists(),
                    f"{name}: missing authority staged files")
        print("PASS missing authority rejects productive and no-op workflows "
              "without effects")
        self.cli("update")
        require(self.lock.is_file(), "update did not initialize authority")
        self.lock.chmod(0o444)

    def noops(self):
        # Existing nonempty generated/snapshot trees must not even be restaged.
        require(tree(self.workspace) and tree(self.generated),
                "no-op test needs prior state")
        for name in ("empty", "nested-empty"):
            before = self.entries(), tree(self.workspace), tree(self.generated)
            result = self.cli("workflow", name)
            require(result.stdout == b"", f"{name}: no-op produced stdout")
            after = self.entries(), tree(self.workspace), tree(self.generated)
            require(before == after,
                    f"{name}: no-op invoked Nix or changed generated state")
        print("PASS empty and nested-empty workflows preserve all state "
              "with zero Nix calls")

    def reject_capabilities(self):
        config = self.project / "Blueprint.roc"
        for name, old, new in [
            ("unsupported-task", 'Task("later", [Use("builder")',
             'Task("later", [Use("foreign")'),
            ("unsupported-build", 'Build("later-library", [Use("builder")',
             'Build("later-library", [Use("foreign")'),
        ]:
            require(self.config.count(old) == 1, "vacuous negative fixture edit")
            config.write_text(self.config.replace(old, new))
            before = self.entries(), tree(self.workspace), tree(self.generated)
            result = self.cli("workflow", name, good=False, contains="Guix")
            require(before == (self.entries(), tree(self.workspace), tree(self.generated)),
                    f"{name} performed effects before whole-closure preflight")
            require(not result.stdout, "unsupported closure produced a marker")
        config.write_text(self.config)
        print("PASS nested later-task and transitive build capability errors before effects")

    def run(self):
        self.prepare()
        outputs, _ = self.workflow("ci", [
            task("prepare"), ("build", "app"), record("after build"),
        ])
        self.artifact(outputs[0], FIRST, PREPARED)
        require((self.project / "task-produced.bin").read_bytes() == PREPARED,
                "task-generated project source missing")
        print("PASS real task -> build -> task, exact artifact/build argv")
        self.noops()

        self.workflow("nested", [
            record("first"), record(*ARGS), record("middle"),
            record(*ARGS), record(*ARGS), record("last"),
        ])
        print("PASS nested and repeated workflows preserve exact order and argv")

        _, failed_task = self.workflow(
            "task-failure", [record("before failure"), task("fail")],
            good=False, contains="B3 intentional task failure",
        )
        require(b"task fail exited with code 23" in failed_task.stderr,
                "task failure lost its real exit status")
        _, failed_build = self.workflow(
            "build-failure", [record("before failure"), ("build", "fail")],
            good=False, contains="B3 intentional build failure",
        )
        require(b"builder failed with exit code 29" in failed_build.stderr,
                "build failure lost its real exit status")
        print("PASS failing task/build prevents all later task and build effects")

        outputs, _ = self.workflow("fresh", [
            ("build", "app"), task("edit"), ("build", "app"), record("after refresh"),
        ])
        first_library = self.artifact(outputs[0], FIRST, PREPARED)
        second_library = self.artifact(outputs[1], SECOND, EDITED)
        require(outputs[0] != outputs[1], "edited source reused stale app")
        require(first_library != second_library, "edited source reused stale dependency")
        require((self.project / "source.bin").read_bytes() == SECOND,
                "edit task did not change project source")
        require((self.project / "task-produced.bin").read_bytes() == EDITED,
                "edit task did not change generated source")
        print("PASS build -> source-editing task -> same build refreshes dependency bytes")

        outputs, _ = self.workflow("repeat", [
            ("build", "app"), record("unchanged"), ("build", "app"),
        ])
        require(outputs[0] == outputs[1], "unchanged repeat changed store identity")
        for output in outputs:
            self.artifact(output, SECOND, EDITED)
        cached = outputs[0]
        print("PASS repeated explicit builds retain unchanged store identity")

        self.reject_capabilities()
        # Remove only disposable old roots so they cannot become ordinary inputs.
        shutil.rmtree(self.workspace)
        shutil.rmtree(self.generated)
        self.workspace = self.work / "outside-work"
        self.generated = self.work / "outside-generated"
        self.env.update(BLUEPRINT_WORKSPACE=str(self.workspace),
                        BLUEPRINT_GENERATED_ROOT=str(self.generated))
        outputs, _ = self.workflow("repeat", [
            ("build", "app"), record("unchanged"), ("build", "app"),
        ])
        require(outputs == [cached, cached], "out-of-tree layout changed artifact")
        self.artifact(outputs[0], SECOND, EDITED)
        require(self.workspace.is_dir() and self.generated.is_dir(),
                "caller-selected out-of-tree roots not used")
        require(not (self.caller / "Blueprint.lock").exists()
                and not (self.caller / ".blueprint").exists(), "invocation cwd was used")
        print("PASS out-of-tree workspace/generated roots from unrelated cwd")

        # Preflight succeeds initially; the intervening task dirties locked bytes.
        # The second build must verify again rather than return its earlier output.
        outputs, result = self.workflow("dirty-source", [
            ("build", "app"), task("dirty"),
        ], good=False, contains="blueprint update")
        require(outputs == [cached], "dirty second build published a stale output")
        require(result.stderr.count(b"built app:") == 1, result.stderr)
        self.artifact(outputs[0], SECOND, EDITED)
        require((self.project / "assets/message.txt").read_bytes()
                == b"dirty locked source\x00\n", "dirty task did not execute")
        before = self.entries(), tree(self.workspace), tree(self.generated)
        self.cli("workflow", "ci", good=False, contains="blueprint update")
        recent = self.entries()[len(before[0]):]
        require(all(entry["kind"] == "nix" and entry["argv"][:2] == ["hash", "path"]
                    for entry in recent), "dirty authority allowed user effects")
        require((tree(self.workspace), tree(self.generated)) == before[1:],
                "dirty initial source staged files")
        print("PASS dirty locked source aborts later build without stale publication")
        print(f"B3 real Nix: all gates passed ({self.count} process checks)")


def example_smoke(work):
    """Exercise the complete public example, changing only temporary setup inputs."""
    work.mkdir()
    suite = Suite(work)
    source = ROOT / "examples/artifacts"
    original = tree(source)
    # A user may already have run update/build in the documented example.
    # Carry authored fixture files only, never its ignored authority/workspace.
    for relative in (
        "Blueprint.roc", "README.md", "assets/heading.txt", "src/message.txt",
        "scripts/check.py", "scripts/build_library.py", "scripts/build_app.py",
    ):
        destination = suite.project / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, destination)
    config = suite.project / "Blueprint.roc"
    text = config.read_text()
    local_platform = '"../../blueprint-platform/main.roc"'
    require(text.count(local_platform) == 1, "example platform header changed")
    relative = os.path.relpath(ROOT / "blueprint-platform/main.roc", suite.project)
    pin = json.loads((ROOT / "fixtures/consumer/inputs.lock").read_text())["nodes"]["nixpkgs"]["locked"]
    ref = f'github:{pin["owner"]}/{pin["repo"]}/{pin["rev"]}'
    require(text.count('Name("artifacts"),') == 1, "example name changed")
    config.write_text(text.replace(local_platform, json.dumps(relative)).replace(
        'Name("artifacts"),',
        f'Name("artifacts"),\n\tPackages("default", From(NixPackages("{ref}"))),',
    ))
    suite.command([suite.env["ROC"], "check", config])
    suite.cli("build", "app", good=False, contains="blueprint update")
    suite.cli("update")
    require(suite.lock.is_file(), "example update did not publish authority")
    suite.lock.chmod(0o444)
    built = suite.cli("build", "app")
    output = Path(os.fsdecode(built.stdout.strip()))
    require(str(output).startswith("/nix/store/") and output.is_file(),
            "example must report its resolved file artifact")
    expected = b"Artifact example\nHELLO FROM THE WORKING TREE\n"
    require(output.read_bytes() == expected, "example artifact bytes differ")
    workflow = suite.cli("workflow", "ci")
    require(workflow.stdout == b"source checked\n" + built.stdout,
            "example task/build workflow order or artifact identity differs")
    require(output.read_bytes() == expected, "workflow changed artifact bytes")
    require(not (suite.project / "dist").exists(), "build wrote into project checkout")
    require(tree(source) == original, "example smoke mutated checked-in files")
    print(f"PASS artifacts example copy: compiler, explicit update, real build/workflow, "
          f"exact bytes and immutable authority ({suite.count} process checks)")


def main():
    require(sys.flags.optimize == 0, "run without -O")
    require(sys.platform == "linux" and platform.machine() == "x86_64",
            "B3 requires x86_64 Linux; unsupported is not a pass")
    require((ROOT / "blueprint").is_file(), "build ./blueprint first")
    work = Path(tempfile.mkdtemp(prefix="blueprint-b3-"))
    try:
        Suite(work).run()
        example_smoke(work / "example-smoke")
    except BaseException:
        print(f"B3 FAILED; retained fixture and logs: {work}", file=sys.stderr)
        raise
    else:
        if os.environ.get("B3_KEEP_TMP") == "1":
            print(f"B3 fixture and logs retained: {work}")
        else:
            shutil.rmtree(work)


if __name__ == "__main__":
    main()
