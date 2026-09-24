"""Host tasks expose exact argv and alter later, fresh build inputs."""

import json
from pathlib import Path
import sys


if sys.argv[1] == "args":
    assert not Path("INJECTED").exists()
    print(json.dumps(sys.argv[2:], ensure_ascii=False))
elif sys.argv[1] == "edit":
    Path("task-produced.txt").write_bytes(b"task-generated\x00bytes\n")
else:
    raise AssertionError("unknown fixture task")
