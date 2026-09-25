"""Build from the current filtered project snapshot, not a locked Source."""

from pathlib import Path

Path("dist").mkdir()
Path("dist/library.txt").write_bytes(Path("src/message.txt").read_bytes().upper())
