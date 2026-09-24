"""Sandboxed artifacts expose exact current-source and dependency bytes."""

import json
import os
from pathlib import Path
import sys


def main():
    mode = sys.argv[1]
    if mode == "fail":
        print("B3 intentional build failure", file=sys.stderr, flush=True)
        raise SystemExit(29)
    Path("dist").mkdir()
    source = Path("source.bin").read_bytes()
    if mode == "library":
        Path("dist/library").write_bytes(b"library\x00" + source)
    elif mode == "app":
        library = Path(os.environ["BLUEPRINT_ARTIFACTS"]) / "library"
        asset = Path(os.environ["BLUEPRINT_INPUTS"]) / "assets/message.txt"
        # These must be the dependency rebuilt from THIS operation's snapshot.
        assert library.read_bytes() == b"library\x00" + source
        task = Path("task-produced.bin")
        generated = task.read_bytes() if task.exists() else b"<absent>"
        output = Path("dist/app")
        output.mkdir()
        output.joinpath("payload").write_bytes(
            b"app\x00" + library.read_bytes() + b"|" + generated
            + b"|" + asset.read_bytes()
        )
        output.joinpath("library-path").write_text(str(library.resolve()) + "\n")
        output.joinpath("argv.json").write_text(
            json.dumps(sys.argv[2:], ensure_ascii=False) + "\n"
        )
        assert not Path("INJECTED").exists(), "build argv was shell-interpreted"
    else:
        raise AssertionError(f"unknown fixture build: {mode}")


if __name__ == "__main__":
    main()
