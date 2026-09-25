"""Filesystem effects only; no config, lock format or build interpretation.

The CLI embeds this source. Snapshot calls supply root, destination and
exclusions; authority commands hash arbitrary bytes or compare-and-swap a
prepared file. All symlinks and special files are rejected. Callers must not
mutate path components or source trees concurrently with these effects.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile


def checked_path(text):
    """Reject symbolic-link components, including dangling destinations."""
    path = Path(text)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError(
            f"runtime path must be absolute and normalized: {path}"
        )
    for component in reversed((path, *path.parents)):
        if component.is_symlink():
            raise ValueError(f"snapshot refuses symlink: {component}")
    return path


def snapshot(root, destination, exclusions):
    """Stage project bytes and a separate namespace witness before publish.

    Callers serialize workspace use and stop on failure. The two outputs cannot
    be renamed together; removing the old witness before replacing the tree
    ensures interrupted publication cannot authorize it with stale observations.
    """
    root = checked_path(root)
    destination = checked_path(destination)
    isolation_path = checked_path(str(destination) + ".isolation.json")
    isolation = {}
    for name in ("mnt", "net"):
        try:
            identity = os.readlink(f"/proc/self/ns/{name}")
        except OSError as error:
            raise ValueError(
                "cannot observe caller build isolation; use Linux with "
                f"readable /proc/self/ns/{name}: {error}"
            ) from error
        if not re.fullmatch(rf"{name}:\[[0-9]+\]", identity):
            raise ValueError(f"invalid caller {name} namespace identity")
        isolation[name] = identity
    names = frozenset(item for item in exclusions if not item.startswith("/"))
    if any("/" in item or item in ("", ".", "..") for item in names):
        raise ValueError("snapshot exclusions must be absolute paths or names")
    exclusions = tuple(checked_path(item) for item in exclusions
                       if item.startswith("/"))
    if root == destination or root.is_relative_to(destination):
        raise ValueError("snapshot destination must not contain the project")
    if not root.is_dir():
        raise ValueError(f"snapshot root is not a directory: {root}")
    if destination.is_relative_to(root) and not any(
        destination.parent.is_relative_to(item) for item in exclusions
    ):
        raise ValueError("in-tree snapshot parent must be excluded")

    def copy_tree(source, target):
        for entry in source.iterdir():
            if entry.name in names or any(
                entry == item or entry.is_relative_to(item)
                for item in exclusions
            ):
                continue
            mode = entry.lstat().st_mode
            copied = target / entry.name
            if stat.S_ISLNK(mode):
                raise ValueError(f"snapshot refuses symlink: {entry}")
            if stat.S_ISDIR(mode):
                copied.mkdir()
                copy_tree(entry, copied)
            elif stat.S_ISREG(mode):
                # O_NOFOLLOW closes the file-symlink race between lstat/open.
                descriptor = os.open(entry, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(descriptor, "rb") as content:
                    if not stat.S_ISREG(os.fstat(content.fileno()).st_mode):
                        raise ValueError(
                            f"snapshot refuses special file: {entry}"
                        )
                    with copied.open("xb") as output:
                        shutil.copyfileobj(content, output)
                copied.chmod(0o755 if mode & 0o111 else 0o644)
            else:
                raise ValueError(f"snapshot refuses special file: {entry}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(
        prefix=".snapshot-", dir=destination.parent
    ))
    try:
        staged_tree = temporary / "project"
        staged_tree.mkdir()
        copy_tree(root, staged_tree)
        staged_isolation = temporary / "isolation.json"
        staged_isolation.write_text(
            json.dumps(isolation, sort_keys=True) + "\n"
        )
        checked_path(str(destination))
        checked_path(str(isolation_path))
        if destination.exists() and not destination.is_dir():
            raise ValueError(
                f"snapshot destination is not a directory: {destination}"
            )
        if isolation_path.exists():
            if not stat.S_ISREG(isolation_path.lstat().st_mode):
                raise ValueError(
                    f"isolation witness is not a file: {isolation_path}"
                )
            isolation_path.unlink()
        if destination.exists():
            shutil.rmtree(destination)
        staged_tree.rename(destination)
        os.replace(staged_isolation, isolation_path)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def authority_token(text):
    """Observe bytes without decoding them, including an absent authority."""
    path = checked_path(text)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return "absent"
    with os.fdopen(descriptor, "rb") as content:
        if not stat.S_ISREG(os.fstat(content.fileno()).st_mode):
            raise ValueError(f"authority is not a regular file: {path}")
        digest = hashlib.sha256()
        for chunk in iter(lambda: content.read(65536), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def publish_authority(text, expected, staged):
    """Serialize the comparison and rename, not the potentially long fetch.

    Lock the parent directory, whose inode survives authority replacement.
    This needs no lockfile cleanup and a crashed publisher cannot leave a
    stale lock: the kernel releases flock when its descriptor closes. Other
    publications in the same directory serialize too. Normal execution never
    calls this command or writes the authority.
    """
    destination = checked_path(text)
    staged = checked_path(staged)
    descriptor = os.open(destination.parent,
                         os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        if authority_token(text) != expected:
            raise ValueError(
                "authority changed during update; retry blueprint update"
            )
        checked_path(str(staged))
        if not stat.S_ISREG(staged.lstat().st_mode):
            raise ValueError(
                f"staged authority is not a regular file: {staged}"
            )
        os.replace(staged, checked_path(text))
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["authority-token"] and len(sys.argv) == 3:
            print(authority_token(sys.argv[2]))
        elif sys.argv[1:2] == ["authority-publish"] and len(sys.argv) == 5:
            publish_authority(*sys.argv[2:])
        elif len(sys.argv) >= 3 and sys.argv[1].startswith("/"):
            snapshot(sys.argv[1], sys.argv[2], sys.argv[3:])
        else:
            raise ValueError(
                "expected snapshot paths, authority-token or authority-publish"
            )
    except (OSError, ValueError) as error:
        sys.exit(f"blueprint runtime: {error}")
