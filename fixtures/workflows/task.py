"""Unsandboxed workflow tasks: exact argv events and deliberate source edits."""

import json
from pathlib import Path
import sys


def main():
    log = Path(sys.argv[1])
    mode = sys.argv[2]
    event = {"kind": "task", "argv": sys.argv[2:]}
    # The caller-owned log is outside the project, so logging cannot bust caches.
    with log.open("a") as stream:
        stream.write(json.dumps(event, ensure_ascii=False) + "\n")
    print(json.dumps(event, ensure_ascii=False), flush=True)
    if mode == "prepare":
        Path("task-produced.bin").write_bytes(b"task-generated\x00bytes\n")
    elif mode == "edit":
        Path("source.bin").write_bytes(b"second\x00revision\xff\n")
        Path("task-produced.bin").write_bytes(b"changed by task\x00\xfe\n")
    elif mode == "dirty":
        Path("assets/message.txt").write_bytes(b"dirty locked source\x00\n")
    elif mode == "fail":
        print("B3 intentional task failure", file=sys.stderr)
        raise SystemExit(23)
    elif mode != "record":
        raise AssertionError(f"unknown fixture task: {mode}")
    assert not Path("INJECTED").exists(), "task argv was interpreted by a shell"


if __name__ == "__main__":
    main()
