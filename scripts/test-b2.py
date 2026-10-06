#!/usr/bin/env python3
"""Real, offline Nix B2 gates. Run after building ./blueprint and platform host.

Needs x86_64 Linux, Roc, Python, Nix and cached consumer nixpkgs/tool closures.
No mocked builds or sandbox-option-only assertions. Failure retains all logs.
"""

from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import socketserver
import subprocess
import sys
import tarfile
import tempfile
import threading


ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "fixtures/builds"
ARGS = [
    "", "two words", "--literal", "$HOME", "$(touch INJECTED)",
    "; touch INJECTED", "a'b\"c", "line\nbreak", "*", "$",
]
FILES = ["build.py", "probe.py", "task.py", "assets/message.txt"]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def tree(path):
    """Capture bytes, not mtimes, so negative cases detect staging mutations."""
    return {
        str(p.relative_to(path)): p.read_bytes()
        for p in path.rglob("*") if p.is_file()
    } if path.exists() else {}


@contextmanager
def listener(token):
    """Keep a real loopback listener alive through both positive controls."""
    class Echo(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(5)
            observed = b""
            while len(observed) < len(token):
                part = self.request.recv(len(token) - len(observed))
                if not part:
                    return
                observed += part
            if observed == token:
                self.request.sendall(token)

    with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server.server_address[1]
        finally:
            server.shutdown()
            thread.join()


class Suite:
    def __init__(self, work):
        self.work = work
        self.project = work / "project"
        self.project.mkdir()
        self.caller = work / "unrelated-cwd"
        self.caller.mkdir()
        self.logs = work / "logs"
        self.logs.mkdir()
        self.trace = work / "nix-argv.jsonl"
        self.count = 0
        self.env = os.environ.copy()
        for name in list(self.env):
            if name.startswith("BLUEPRINT_"):
                del self.env[name]
        self.env.update(BLUEPRINT_ROOT=str(self.project), NO_COLOR="1")
        # Remote builders would invalidate a host-local isolation proof.
        config = self.env.get("NIX_CONFIG", "")
        self.env["NIX_CONFIG"] = config + "\nbuilders =\n"
        compiler = shutil.which(self.env.get("ROC", "roc"))
        require(compiler, "Roc compiler is required (use contributor shell)")
        self.env["ROC"] = str(Path(compiler).resolve())
        real_nix = shutil.which("nix")
        require(real_nix, "real Nix is required")
        wrappers = work / "bin"
        wrappers.mkdir()
        # Transparent exec logger, never a fake backend: every call runs Nix.
        wrapper = wrappers / "nix"
        wrapper.write_text(
            f"#!{sys.executable}\nimport json, os, sys\n"
            f"with open({str(self.trace)!r}, 'a') as stream:\n"
            "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"os.execv({real_nix!r}, ['nix', '--offline', *sys.argv[1:]])\n"
        )
        wrapper.chmod(0o755)
        self.env["PATH"] = str(wrappers) + os.pathsep + self.env["PATH"]
        self.layout(self.project)

    def layout(self, project, outside=False):
        self.project = project
        self.env["BLUEPRINT_ROOT"] = str(project)
        self.workspace = (
            self.work / "outside-work" if outside else project / "work"
        )
        self.generated = (
            self.work / "outside-nix" if outside else project / "generated"
        )
        self.lock = project / "authority.lock"
        self.env.update(
            BLUEPRINT_WORKSPACE=str(self.workspace),
            BLUEPRINT_GENERATED_ROOT=str(self.generated),
            BLUEPRINT_LOCK="authority.lock",
        )

    def command(self, argv, *, good=True, stdin=None, cwd=None, extra=None,
                code=None):
        self.count += 1
        result = subprocess.run(
            list(map(str, argv)), cwd=cwd or self.caller,
            env=self.env | (extra or {}),
            input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=300,
        )
        stem = self.logs / f"{self.count:03d}"
        stem.with_suffix(".argv").write_text(repr(argv) + "\n")
        stem.with_suffix(".out").write_bytes(result.stdout)
        stem.with_suffix(".err").write_bytes(result.stderr)
        require(
            result.returncode == (code if code is not None else int(not good)),
            f"{argv}: exit {result.returncode}; logs {stem}.*\n"
            + result.stderr.decode(errors="replace"),
        )
        return result

    def cli(self, *args, good=True, contains=None, stdin=None):
        before = self.authority_state()
        previous = self.calls()
        result = self.command(
            [ROOT / "blueprint", *args], good=good, stdin=stdin,
        )
        if args[0] != "update":
            require(before == self.authority_state(),
                    f"{args} changed the authoritative lock")
            for call in self.calls()[len(previous):]:
                mutation = call[:2] in (["flake", "update"], ["flake", "lock"])
                require(not mutation, f"implicit locking: {call}")
        if contains:
            require(contains.encode() in result.stderr, result.stderr)
        return result

    def authority_state(self):
        if not self.lock.exists():
            return None
        stat = self.lock.stat()
        return (
            self.lock.read_bytes(), stat.st_ino, stat.st_mtime_ns, stat.st_mode,
        )

    def calls(self):
        if not self.trace.exists():
            return []
        lines = self.trace.read_text().splitlines()
        return [json.loads(line) for line in lines]

    def build(self, name):
        result = self.cli("build", name)
        lines = result.stdout.decode().splitlines()
        require(len(lines) == 1 and lines[0].startswith("/nix/store/"), lines)
        output = Path(lines[0])
        require(output.exists(), f"reported output does not exist: {output}")
        require(f"built {name}:".encode() in result.stderr, result.stderr)
        require(b" -> " + str(output).encode() in result.stderr, result.stderr)
        return output, result

    def prepare(self):
        seed = json.loads((ROOT / "fixtures/consumer/inputs.lock").read_text())
        pinned = seed["nodes"]["nixpkgs"]["locked"]
        ref = f'github:{pinned["owner"]}/{pinned["repo"]}/{pinned["rev"]}'
        self.packages_ref = ref
        # Independent expected source ledger, never populated from a build.
        self.snapshot_files = {}
        self.executables = {"nested/unused-executable"}
        # Reuse the existing immutable fixture pin, never a floating branch.
        self.command(["nix", "flake", "metadata", "--json", ref])
        packages = self.project / "packages"
        packages.mkdir()
        (packages / "unused-source").write_bytes(b"unselected local input\n")
        for relative in FILES:
            source = FIXTURE / relative
            require(source.is_file() and not source.is_symlink(), source)
            destination = self.project / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            destination.chmod(0o644)
            if not relative.startswith("assets/"):
                self.snapshot_files[relative] = source.read_bytes()
        source = (FIXTURE / "Blueprint.roc.in").read_text()
        relative = os.path.relpath(
            ROOT / "blueprint-platform/main.roc", self.project,
        )
        self.config = source.replace("@PLATFORM@", relative)
        self.config = self.config.replace("@PACKAGES@", ref)
        (self.project / "Blueprint.roc").write_text(self.config)
        (self.project / "untracked.txt").write_bytes(b"first\n")
        self.snapshot_files.update({
            "Blueprint.roc": self.config.encode(),
            "untracked.txt": b"first\n",
            "nested/unused-executable": b"#!/bin/sh\n# unused nested bytes\n",
        })
        nested = self.project / "nested/unused-executable"
        nested.parent.mkdir()
        nested.write_bytes(self.snapshot_files["nested/unused-executable"])
        nested.chmod(0o755)
        # Nix records only whether the owner may execute a file, and a name
        # need not be UTF-8.
        raw = os.fsdecode(b"not-utf8-\xff")
        for name, mode, executable in [
            ("group-only-tool", 0o654, False), ("private-tool", 0o700, True),
            ("setuid-tool", 0o4755, True), ("read-only", 0o444, False),
            (raw, 0o600, False),
        ]:
            data = os.fsencode(name) + b"\xff\x00\n"
            (self.project / name).write_bytes(data)
            (self.project / name).chmod(mode)
            self.snapshot_files[name] = data
            if executable:
                self.executables.add(name)
        for name in (".git", ".hg", ".svn", ".jj", "nested/.git"):
            directory = self.project / name
            directory.mkdir(parents=True)
            (directory / "excluded-secret").write_bytes(b"VCS excluded")
        # An excluded entry is never inspected, so a link there is not refused.
        (self.project / ".git/link").symlink_to(self.project / "untracked.txt")
        self.cli("check")

    def expected(self):
        task = self.project / "task-produced.txt"
        data = b"library\x00" + (self.project / "untracked.txt").read_bytes()
        data += b"|" + (task.read_bytes() if task.exists() else b"<absent>")
        asset = (self.project / "assets/message.txt").read_bytes()
        payload = data + b"|" + asset
        argv = json.dumps(ARGS, ensure_ascii=False).encode()
        return data, payload, b"app\x00" + payload + b"|" + argv

    def graph(self):
        library, bundle, expected = self.expected()
        output, result = self.build("app")
        require(output.is_file() and output.read_bytes() == expected, output)
        labels = [b"building library:", b"building bundle:", b"building app:"]
        indexes = [result.stderr.index(label) for label in labels]
        require(indexes == sorted(indexes), "metadata is not dependency-first")
        require(all(result.stderr.count(label) == 1 for label in labels),
                "shared dependency was duplicated")
        lib, _ = self.build("library")
        require(lib.is_file() and lib.read_bytes() == library, lib)
        directory, _ = self.build("bundle")
        require(directory.is_dir(), directory)
        contents = tree(directory)
        require(set(contents) == {"payload", "files.json", "proof"}, contents)
        require(contents["payload"] == bundle, contents)
        require(contents["proof"] == b"source+dependency readonly\n", contents)
        manifest = {
            name: {"hex": data.hex(), "executable": name in self.executables}
            for name, data in self.snapshot_files.items()
        }
        expected_manifest = (json.dumps(manifest, sort_keys=True) + "\n").encode()
        require(contents["files.json"] == expected_manifest,
                "in-derivation source bytes/modes differ from fixture ledger")
        require(not (self.project / "INJECTED").exists(), "argv injection")
        return output

    def runner(self, spec, *, good=True, code=None):
        """Run the production build runner on the host, as a derivation does.

        Each run gets its own build directory, specification and `$out`.
        """
        top = Path(tempfile.mkdtemp(prefix="runner-", dir=self.work))
        (top / "build").mkdir()
        (top / "spec.json").write_text(json.dumps(spec))
        result = self.command(
            [ROOT / "blueprint", "__build-runner", top / "spec.json"],
            good=good, code=code, cwd=top / "build",
            extra={"out": str(top / "out")},
        )
        return result, top

    def host_spec(self, **fields):
        """A specification whose witness names namespaces this host lacks.

        The runner compares a build's namespaces with the caller's witness.
        A hand-written witness that differs from this process therefore lets
        the remaining checks run here without a sandbox; the production
        witness is the one the CLI observes for itself.
        """
        empty = self.work / "runner-empty"
        empty.mkdir(exist_ok=True)
        return {
            "project": str(empty), "inputs": str(empty),
            "artifacts": str(empty), "path": os.environ["PATH"],
            "output": "output", "isolation": {"mnt": "mnt:[0]", "net": "net:[0]"},
            "argv": [sys.executable, "-c",
                     "open('output', 'w').write('host control')"],
            "readlink": shutil.which("readlink"),
            "chmod": shutil.which("chmod"),
        } | fields

    def runner_mechanics(self):
        """Exit codes, the declared PATH and output checks, without Nix."""
        python = [sys.executable, "-c"]
        _, top = self.runner(self.host_spec())
        require((top / "out").read_text() == "host control", top)
        self.runner(self.host_spec(argv=python + ["raise SystemExit(7)"]),
                    code=7)
        self.runner(self.host_spec(argv=python + [
            "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"]),
            code=143)
        for spec, diagnostic in [
            # Only the declared path is searched, not this process's own.
            (self.host_spec(path=str(self.work / "runner-empty"),
                            argv=["env"]), "build command not found: env"),
            (self.host_spec(argv=python + [
                "import os; open(os.environ['out'], 'w').write('direct'); "
                "open('output', 'w').write('declared')"]),
             "build wrote directly to $out instead of declared Output"),
            (self.host_spec(argv=python + [
                "import os; os.rename(os.getcwd(), '../moved'); "
                "os.symlink('moved', '../blueprint-work'); "
                "open('../moved/output', 'w').write('moved')"]),
             "build replaced the project workspace"),
            (self.host_spec(output="../escape"),
             "invalid declared relative output"),
            (self.host_spec(argv=python + ["import os; os.mkfifo('output')"]),
             "special file is not allowed in build output/source"),
        ]:
            result, top = self.runner(spec, good=False)
            require(diagnostic.encode() in result.stderr, result.stderr)
            require(result.stderr.startswith(b"blueprint build: "),
                    result.stderr)
            if "$out" not in diagnostic:
                require(not os.path.lexists(top / "out"), "failure published")
        print("PASS runner exit codes, declared PATH and output checks "
              "(host, hand-written witness)")

    def reject_unsafe_project_entries(self):
        """Symlinks and special files are refused wherever the build reads."""
        for kind in ("file-link", "dir-link", "dangling", "fifo"):
            for where in ("", "nested/"):
                bad = self.project / f"{where}bad"
                if kind == "fifo":
                    os.mkfifo(bad)
                    message = f"snapshot refuses special file: {bad}"
                else:
                    bad.symlink_to({
                        "file-link": self.project / "untracked.txt",
                        "dir-link": self.project / "nested",
                        "dangling": self.project / "absent",
                    }[kind])
                    message = f"snapshot refuses symlink: {bad}"
                result = self.cli("build", "library", good=False,
                                  contains=message)
                require(not result.stdout and b"built " not in result.stderr,
                        "refused project entry published success")
                bad.unlink()
        # Excluded entries are never inspected, whatever they are.
        os.mkfifo(self.project / ".git/fifo")
        self.build("library")
        (self.project / ".git/fifo").unlink()
        print("PASS project symlinks and special files refused at any depth; "
              "excluded entries never inspected")

    def reject_unsandboxed_runner(self):
        """Execute the real runner on the host; never reach user Run.

        Uses the namespace identities the CLI staged for a real build.
        """
        source = self.work / "runner-source"
        source.mkdir()
        (source / "input").write_bytes(b"project bytes only\n")
        observed = {
            name: os.readlink(f"/proc/self/ns/{name}")
            for name in ("mnt", "net")
        }
        flake = self.generated / "flake.nix"
        self.build("library")
        literal = 'isolation = {{ mnt = "{mnt}"; net = "{net}"; }};'.format(
            **observed)
        require(literal in flake.read_text(),
                "staged build did not capture caller namespaces")
        require("@blueprint-caller" not in flake.read_text(),
                "staged build kept an unobserved placeholder")
        before = flake.read_bytes()
        self.build("library")
        require(flake.read_bytes() == before, "witness defeats build caching")
        marker = self.work / "unsandboxed-run-was-executed"
        spec = self.host_spec(
            project=str(source), inputs=str(source), artifacts=str(source),
            argv=[sys.executable, "-c",
                  f"from pathlib import Path; Path({str(marker)!r})"
                  ".write_text('unsafe')"],
        )
        cases = [
            (observed, "Build shares caller mnt namespace."),
            ({**observed, "net": "net:[0]"},
             "Build shares caller mnt namespace."),
            ({**observed, "mnt": "mnt:[0]"},
             "Build shares caller net namespace."),
            ({"mnt": "invalid", "net": observed["net"]},
             "Invalid caller mnt namespace."),
            ({"mnt": "mnt:[0]", "net": "net:[0] "},
             "Invalid caller net namespace."),
            (None, "Missing caller namespace observations."),
            ({"mnt": "mnt:[0]"}, "Missing caller namespace observations."),
        ]
        specs = [({**spec, "isolation": isolation}, reason)
                 for isolation, reason in cases]
        # A witness that differs still fails closed when the build's own
        # namespaces cannot be read.
        unreadable = {**spec, "readlink": str(self.work / "no-readlink")}
        specs.append((unreadable, "Cannot read build mnt namespace"))
        absent = dict(spec)
        del absent["isolation"]
        specs.append((absent, "Missing caller namespace observations."))
        for candidate, reason in specs:
            result, top = self.runner(candidate, good=False)
            require(b"blueprint build: cannot verify build isolation; "
                    b"user Run was not executed" in result.stderr,
                    result.stderr)
            require(b"daemon configuration" in result.stderr, result.stderr)
            require(reason.encode() in result.stderr, result.stderr)
            require(not marker.exists(), "unsandboxed user Run executed")
            require(sorted(top.iterdir()) == [top / "build", top / "spec.json"],
                    "isolation check happened after an effect")
            require(not list((top / "build").iterdir()),
                    "isolation check happened after workspace setup")
        print("PASS unsandboxed runner fails closed before user Run")

    def reject_unsafe_fetched_sources(self):
        """Filesystem unit gate for the runner's local/remote source boundary.

        The production runner checks a source farm on the host; see host_spec.
        """
        source = self.work / "fetched-source"
        source.mkdir()
        (source / "data").write_bytes(b"locked bytes\n")
        farm = self.work / "source-farm"
        farm.mkdir()
        entry = farm / "assets"
        entry.symlink_to(source)
        sentinel = self.work / "fetched-source-run-was-executed"
        spec = self.host_spec(inputs=str(farm), argv=[
            sys.executable, "-c",
            f"open({str(sentinel)!r}, 'w').write('run'); "
            "open('output', 'w').write('safe source')"])
        _, top = self.runner(spec)
        require((top / "out").read_text() == "safe source", top)
        sentinel.unlink()
        for target in (source / "data", self.work / "outside-source"):
            (source / "link").symlink_to(target)
            result, _ = self.runner(spec, good=False)
            require(b"symlink is not allowed" in result.stderr, result.stderr)
            (source / "link").unlink()
        os.mkfifo(source / "pipe")
        result, _ = self.runner(spec, good=False)
        require(b"special file is not allowed" in result.stderr, result.stderr)
        (source / "pipe").unlink()
        # A fetched root link is not confused with the allowed farm link.
        alias = self.work / "fetched-root-link"
        alias.symlink_to(source)
        entry.unlink()
        entry.symlink_to(alias)
        result, _ = self.runner(spec, good=False)
        require(b"symlink is not allowed" in result.stderr, result.stderr)
        # Only generated links belong in a farm.
        entry.unlink()
        (farm / "plain").write_bytes(b"not a link\n")
        result, _ = self.runner(spec, good=False)
        require(b"expected generated source link" in result.stderr,
                result.stderr)
        require(not sentinel.exists(), "user Run reached past an unsafe source")
        print("PASS fetched source filesystem policy (runner unit gate)")

    def reject_remote_symlink_build(self):
        """Actual HTTP fetch and sandboxed production runner, not helper calls."""
        project = self.work / "remote-project"
        project.mkdir()
        self.layout(project)
        served = self.work / "http-sources"
        served.mkdir()
        source = self.work / "archive-source"
        source.mkdir()
        nonce = secrets.token_hex(24)
        (source / "data").write_text(nonce)
        (source / "link").symlink_to("data")
        for name in ("unsafe", "safe"):
            with tarfile.open(served / f"{name}.tar.gz", "w:gz") as archive:
                archive.add(source, arcname="source")
            if name == "unsafe":
                (source / "link").unlink()
        requests = []

        class Handler(SimpleHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                super().do_GET()

            def log_message(self, *_args):
                pass

        handler = partial(Handler, directory=str(served))
        with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}"
                relative = os.path.relpath(
                    ROOT / "blueprint-platform/main.roc", project,
                )
                config = (
                    f'app [config] {{ pf: platform "{relative}" }}\n'
                    'config = [Name("remote-source-policy"), '
                    f'Packages("default", From(NixPackages("{self.packages_ref}"))), '
                    'Environment("builder", [Tools(["python3"])]), '
                    f'Source("remote", "{url}/unsafe.tar.gz"), '
                    'Build("remote", [Use("builder"), Inputs(["remote"]), '
                    'Run(["python3", "run.py"]), Output("output")])]\n'
                )
                sentinel = f"USER_RUN_REACHED_{nonce}"
                (project / "run.py").write_text(
                    "from pathlib import Path\nimport sys\n"
                    f"print({sentinel!r}, file=sys.stderr, flush=True)\n"
                    f"Path('output').write_text({nonce!r})\n"
                )
                (project / "Blueprint.roc").write_text(config)
                self.cli("update")
                require("/unsafe.tar.gz" in requests, "unsafe HTTP source not fetched")
                result = self.cli("build", "remote", good=False,
                                  contains="symlink is not allowed")
                require(b"/link" in result.stderr, result.stderr)
                require(sentinel.encode() not in result.stdout + result.stderr,
                        "user Run reached despite unsafe fetched source")
                require(not result.stdout and b"built " not in result.stderr,
                        "unsafe fetched source published success")
                # Same production Run succeeds with the symlink-free archive.
                # Its nonce prevents a cached result from faking this control.
                (project / "Blueprint.roc").write_text(
                    config.replace("/unsafe.tar.gz", "/safe.tar.gz")
                )
                self.cli("update")
                output, _ = self.build("remote")
                require("/safe.tar.gz" in requests, "safe HTTP source not fetched")
                require(output.read_text() == nonce, "safe-source Run not reached")
            finally:
                server.shutdown()
                thread.join()
        print("PASS HTTP-fetched symlink rejected by sandboxed production runner; "
              "same Run succeeds with safe source")

    def run(self):
        self.reject_unsafe_fetched_sources()
        self.runner_mechanics()
        self.prepare()
        # Ordinary operations must neither initialize authority nor stage files.
        for args in [("gen",), ("shell",), ("run", "args"), ("build", "app")]:
            self.cli(*args, good=False, contains="blueprint update")
            require(not self.workspace.exists() and not self.generated.exists(),
                    "missing lock caused staging")
        self.cli("update")
        require(self.lock.is_file(), "explicit update did not create authority")
        authority = self.lock.read_bytes()
        require(str(self.project).encode() not in authority,
                "authority contains absolute checkout paths")
        self.lock.chmod(0o444)
        for directory in (self.workspace, self.generated):
            directory.mkdir(exist_ok=True)
            (directory / "excluded-secret").write_bytes(b"generated excluded")
        self.cli("gen")
        result = self.cli("run", "args", "--", *ARGS)
        require(result.stdout == (json.dumps(ARGS) + "\n").encode(),
                result.stdout)
        shell_script = b"printf 'B2 shell control\\n'\nexit\n"
        result = self.cli("shell", stdin=shell_script)
        require(result.stdout == b"B2 shell control\n", result.stdout)
        first = self.graph()
        print("PASS file/directory/diamond graph, argv, readonly, exclusions")
        self.reject_unsandboxed_runner()
        self.reject_unsafe_project_entries()

        # A unique nonce prevents a cached derivation from faking isolation.
        token = secrets.token_hex(24).encode()
        # The project remains under TMPDIR in the caller's cache.
        # A tiny external probe needs traversable parents: HOME may be 0700,
        # which would make denial a permissions result rather than isolation.
        with tempfile.TemporaryDirectory(
            prefix="blueprint-host-probe-", dir="/var/tmp",
        ) as host, listener(token) as port:
            Path(host).chmod(0o755)
            marker = Path(host) / "undeclared-host-marker"
            marker.write_bytes(token)
            marker.chmod(0o644)
            probe = json.dumps({
                "marker": str(marker), "port": port, "token": token.decode(),
            }).encode()
            (self.project / "probe.json").write_bytes(probe)
            self.snapshot_files["probe.json"] = probe
            control = b"host-file readable; host-TCP reachable\n"
            result = self.cli("run", "control")
            require(result.stdout == control, "host control before build")
            output, _ = self.build("isolation")
            proof = b"host-file denied\nhost-TCP denied\n"
            require(output.read_bytes() == proof, "sandbox proof bytes differ")
            result = self.cli("run", "control")
            require(result.stdout == control, "host control after build")
            require(marker.read_bytes() == token, "host marker changed")
        print("PASS host-file/TCP isolation; same probes pass as host tasks")

        (self.project / "untracked.txt").write_bytes(b"second\x00revision\n")
        self.snapshot_files["untracked.txt"] = b"second\x00revision\n"
        second = self.graph()
        require(first != second, "untracked edit reused an obsolete artifact")
        self.cli("run", "edit")
        self.snapshot_files["task-produced.txt"] = b"task-generated\x00bytes\n"
        third = self.graph()
        require(second != third, "task-generated file did not change artifact")
        (self.project / "task-produced.txt").unlink()
        del self.snapshot_files["task-produced.txt"]
        fourth = self.graph()
        require(third != fourth, "deleted file survived a fresh build")
        print("PASS fresh project copies after untracked edits, tasks and deletions")

        for name, diagnostic in [
            ("missing", "declared output is missing"),
            ("symlink", "symlink in declared output path"),
            ("nested-link", "symlink is not allowed"),
        ]:
            result = self.cli("build", name, good=False, contains=diagnostic)
            require(not result.stdout and b"built " not in result.stderr,
                    "failed build published success metadata")
        print("PASS missing/symlink outputs fail without publishing success")

        # A build sees its environment's tools and nothing else: neither an
        # undeclared interpreter nor the shell earlier versions supplied.
        for name, tool in [("undeclared", "python3"),
                           ("undeclared-shell", "sh")]:
            result = self.cli("build", name, good=False,
                              contains=f"build command not found: {tool}")
            require(not result.stdout and b"built " not in result.stderr,
                    "undeclared tool published success")
        print("PASS undeclared build tools are not found")

        before = tree(self.generated), tree(self.workspace)
        asset = self.project / "assets/message.txt"
        asset.write_bytes(b"explicitly updated\n")
        for args in [("gen",), ("shell",), ("run", "args"), ("build", "app")]:
            self.cli(*args, good=False, contains="blueprint update")
            require(before == (tree(self.generated), tree(self.workspace)),
                    "dirty locked source caused staging")
        require(self.lock.read_bytes() == authority, "dirty input rewrote pins")
        self.cli("update")
        require(self.lock.read_bytes() != authority, "update kept old hash")
        authority = self.lock.read_bytes()
        original = self.graph()
        print("PASS dirty local source rejected until explicit update")

        # Unsupported dependency closure must fail before any Nix or staging.
        config = self.project / "Blueprint.roc"
        foreign = self.config.replace(
            '"library",\n\t\t[\n\t\t\tUse("builder")',
            '"library",\n\t\t[\n\t\t\tUse("foreign")',
        )
        require(foreign != self.config, "closure replacement was vacuous")
        config.write_text(foreign)
        before = tree(self.generated), tree(self.workspace), self.calls()
        self.cli("build", "app", good=False, contains="Guix")
        after = tree(self.generated), tree(self.workspace), self.calls()
        require(before == after, "unsupported closure had provider effects")
        config.write_text(self.config.replace(
            'Tools(["python3"])',
            'Tools(["python3", "blueprintMissingNativePackage"])',
        ))
        self.cli("build", "app", good=False,
                 contains="attribute 'blueprintMissingNativePackage' missing")
        config.write_text(self.config)
        print("PASS unsupported closure before effects; native package failure")

        # Relocation changes all caller roots but retains the exact authority.
        relocated = self.work / "relocated"
        shutil.copytree(self.project, relocated)
        shutil.rmtree(relocated / "work")
        shutil.rmtree(relocated / "generated")
        self.layout(relocated, outside=True)
        self.cli("gen")
        derived = (self.generated / "flake.lock").read_bytes()
        require(str(relocated / "assets").encode() in derived, derived)
        require(str(self.work / "project").encode() not in derived, derived)
        moved = self.graph()
        require(moved == original, "relocation changed the actual artifact")
        self.cli("run", "args", "--", "")
        self.cli("shell", stdin=b"exit\n")
        require(self.lock.read_bytes() == authority, "relocation changed pins")
        require(not (relocated / "Blueprint.lock").exists(), "second authority")
        print("PASS relocation, rebased native lock, out-of-tree caller paths")
        self.reject_remote_symlink_build()
        print(f"B2 real Nix: all gates passed ({self.count} process checks)")
        print(f"Final artifact: {moved}")


def main():
    require(sys.flags.optimize == 0, "run without -O: assertions matter")
    require(sys.platform == "linux" and platform.machine() == "x86_64",
            "B2 requires x86_64 Linux; unsupported is not a pass")
    require((ROOT / "blueprint").is_file(), "build ./blueprint first")
    # Respect caller TMPDIR; potentially large projects must not use /tmp.
    work = Path(tempfile.mkdtemp(prefix="blueprint-b2-"))
    try:
        Suite(work).run()
    except BaseException:
        print(f"B2 FAILED; retained fixture and logs: {work}", file=sys.stderr)
        raise
    else:
        if os.environ.get("B2_KEEP_TMP") == "1":
            print(f"B2 fixture and logs retained: {work}")
        else:
            shutil.rmtree(work)


if __name__ == "__main__":
    main()
