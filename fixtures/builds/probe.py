"""The same host probes succeed in a task and must fail in a real derivation."""

import errno
import json
from pathlib import Path
import socket
import sys


def main():
    probe = json.loads(Path("probe.json").read_text())
    expected = probe["token"].encode()
    sandbox = sys.argv[1] == "sandbox"
    marker = Path(probe["marker"])
    try:
        observed = marker.read_bytes()
    except FileNotFoundError:
        assert sandbox, "host positive control could not read its marker"
    else:
        assert not sandbox, "SANDBOX FAILURE: undeclared host file is readable"
        assert observed == expected
    try:
        address = ("127.0.0.1", probe["port"])
        stream = socket.create_connection(address, timeout=2)
    except OSError as error:
        assert sandbox, "host positive control could not reach its listener"
        assert error.errno in (
            errno.ECONNREFUSED, errno.ENETUNREACH, errno.EHOSTUNREACH,
            errno.EACCES, errno.EPERM,
        ) or isinstance(error, TimeoutError), error
    else:
        with stream:
            assert not sandbox, "SANDBOX FAILURE: host TCP listener reachable"
            stream.sendall(expected)
            observed = b""
            while len(observed) < len(expected):
                part = stream.recv(len(expected) - len(observed))
                assert part, "host listener closed before returning its token"
                observed += part
            assert observed == expected
    if sandbox:
        Path("dist").mkdir()
        proof = b"host-file denied\nhost-TCP denied\n"
        Path("dist/isolation").write_bytes(proof)
    else:
        print("host-file readable; host-TCP reachable")


if __name__ == "__main__":
    main()
