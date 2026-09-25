"""Combine a locked source and exactly the declared dependency output."""

import os
from pathlib import Path

assets = Path(os.environ["BLUEPRINT_INPUTS"]) / "assets"
library = Path(os.environ["BLUEPRINT_ARTIFACTS"]) / "library"
# Both inputs are read-only store views, separate from this writable project.
Path("dist").mkdir()
Path("dist/app.txt").write_bytes(
    (assets / "heading.txt").read_bytes() + library.read_bytes()
)
