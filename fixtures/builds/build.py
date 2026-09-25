"""Real builds with exact outputs, filtered trees and immutable inputs."""

import errno
import json
import os
from pathlib import Path
import sys


def deny_write(path):
    """Attempt actual writes; inspecting mode bits alone is not proof."""
    original = path.read_bytes()
    try:
        with path.open("ab") as stream:
            stream.write(b"unexpected-write")
    except OSError as error:
        assert error.errno in (errno.EACCES, errno.EROFS), error
    else:
        raise AssertionError(f"input was writable: {path}")
    assert path.read_bytes() == original


def deny_create(directory):
    """Read-only inputs must also reject adding new children."""
    try:
        (directory / "forbidden-write").write_bytes(b"bad")
    except OSError as error:
        assert error.errno in (errno.EACCES, errno.EROFS), error
    else:
        raise AssertionError(f"input directory was writable: {directory}")


def inputs():
    """Sources and dependency outputs stay outside the writable project copy."""
    sources = Path(os.environ["BLUEPRINT_INPUTS"])
    artifacts = Path(os.environ["BLUEPRINT_ARTIFACTS"])
    for root in (sources, artifacts):
        assert not root.resolve().is_relative_to(Path.cwd())
    return sources, artifacts


def main():
    mode = sys.argv[1]
    if mode == "library":
        assert list(Path(os.environ["BLUEPRINT_INPUTS"]).iterdir()) == []
        assert list(Path(os.environ["BLUEPRINT_ARTIFACTS"]).iterdir()) == []
        task = Path("task-produced.txt")
        payload = b"library\x00" + Path("untracked.txt").read_bytes()
        payload += b"|" + (task.read_bytes() if task.exists() else b"<absent>")
        Path("dist").mkdir()
        Path("dist/library").write_bytes(payload)
    elif mode in ("bundle", "app"):
        sources, artifacts = inputs()
        assert sorted(p.name for p in sources.iterdir()) == ["assets"]
        expected = ["library"] if mode == "bundle" else ["bundle", "library"]
        assert sorted(p.name for p in artifacts.iterdir()) == expected
        asset = sources / "assets/message.txt"
        library = artifacts / "library"
        assert library.is_file()  # Exactly Output, not a enclosing directory.
        deny_write(asset)
        deny_create(asset.parent)
        deny_write(library)
        forbidden = {".git", ".hg", ".svn", ".jj", "assets", "packages"}
        forbidden.update({"work", "generated", "authority.lock", "INJECTED"})
        files = sorted(str(p) for p in Path(".").rglob("*") if p.is_file())
        assert not any(set(Path(p).parts) & forbidden for p in files), files
        assert not any(Path(p).name in forbidden for p in Path(".").rglob("*"))
        payload = library.read_bytes() + b"|" + asset.read_bytes()
        Path("dist").mkdir()
        if mode == "bundle":
            Path("dist/bundle").mkdir()
            Path("dist/bundle/payload").write_bytes(payload)
            manifest = {
                name: {
                    "hex": Path(name).read_bytes().hex(),
                    "executable": bool(Path(name).stat().st_mode & 0o111),
                }
                for name in files
            }
            Path("dist/bundle/files.json").write_text(
                json.dumps(manifest, sort_keys=True) + "\n"
            )
            proof = b"source+dependency readonly\n"
            Path("dist/bundle/proof").write_bytes(proof)
        else:
            bundle = artifacts / "bundle"
            assert bundle.is_dir()
            assert sorted(p.name for p in bundle.iterdir()) == [
                "files.json", "payload", "proof",
            ]
            deny_write(bundle / "payload")
            deny_create(bundle)
            assert (bundle / "payload").read_bytes() == payload
            argv = json.dumps(sys.argv[2:], ensure_ascii=False).encode()
            Path("dist/app").write_bytes(b"app\x00" + payload + b"|" + argv)
    elif mode == "missing":
        # A successful child process is not a successful artifact build.
        Path("wrong-output").write_bytes(b"not the declared output")
    elif mode == "symlink":
        Path("dist").mkdir()
        Path("dist/symlink").symlink_to(Path("untracked.txt").resolve())
    elif mode == "nested-link":
        Path("dist/nested-link").mkdir(parents=True)
        Path("dist/nested-link/escape").symlink_to("/etc/passwd")
    else:
        raise AssertionError(f"unknown fixture build: {mode}")


if __name__ == "__main__":
    main()
