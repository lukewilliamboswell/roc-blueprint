app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst" }

import cli.IOErr
import cli.Duration
import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout
import cli.Tcp

## The same host probes succeed in a task and must fail in a real derivation.
## `probe.json` names a marker file outside the project, a listening TCP port
## on the host's loopback address and the token both hold.
##
##   roc-stable probe.roc -- host      a task: both must be reachable
##   roc-stable probe.roc -- sandbox   a build: neither may be
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		["host"] => probe!(Bool.False)
		["sandbox"] => probe!(Bool.True)
		_ => Err(Failed("usage: probe.roc host | sandbox"))
	}
	match result {
		Ok({}) => Ok({})
		Err(Failed(message)) => {
			_ = Stderr.line!("isolation probe: ${message}")
			Err(Exit(1))
		}
		Err(other) => {
			_ = Stderr.line!("isolation probe: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

require : Bool, Str -> Try({}, [Failed(Str)])
require = |holds, message| if holds Ok({}) else Err(Failed(message))

probe! : Bool => Try({}, _)
probe! = |sandbox| {
	settings : { marker : Str, port : U16, token : Str }
	settings = Json.parse(Path.read_utf8!("probe.json")?)?
	expected = settings.token.to_utf8()

	# In a build the marker must be absent, not merely unreadable: it lies in
	# a directory anyone may enter, so "not found" is the sandbox's doing.
	match Path.read_bytes!(Path.utf8(settings.marker)) {
		Ok(observed) => {
			require(!sandbox, "SANDBOX FAILURE: undeclared host file is readable")?
			require(observed == expected, "the host marker holds other bytes")?
		}
		Err(PathErr(NotFound, _)) => require(sandbox, "host positive control could not read its marker")?
		Err(other) => return Err(Failed("reading the host marker failed for another reason: ${Str.inspect(other)}"))
	}

	match Tcp.connect!("127.0.0.1", settings.port, { connect_timeout: Duration.seconds(2), io_timeout: Duration.seconds(5) }) {
		Ok(stream) => {
			require(!sandbox, "SANDBOX FAILURE: host TCP listener reachable")?
			stream.write_bytes!(expected)?
			echoed = stream.read_exactly!(expected.len()).map_err(|_| Failed("the host listener accepted a connection and did not return its token"))?
			require(echoed == expected, "the host listener returned other bytes")?
		}
		Err(refusal) => {
			require(sandbox, "host positive control could not reach its listener")?
			require(unreachable(refusal), "connecting to the host failed for another reason: ${Str.inspect(refusal)}")?
		}
	}

	if sandbox {
		Path.create_dir!("dist")?
		Path.write_utf8!("dist/isolation", "host-file denied\nhost-TCP denied\n")?
		Ok({})
	} else {
		Stdout.line!("host-file readable; host-TCP reachable")
	}
}

## The ways a connection fails when the host's listener cannot be reached:
## refused (an isolated loopback has no such listener), denied, timed out, or
## no route. basic-cli has no tag for "network unreachable" and "host
## unreachable", so those arrive as the text of the operating system's error.
unreachable : [TcpErr(IOErr)] -> Bool
unreachable = |refusal|
	match refusal {
		TcpErr(ConnectionRefused) => Bool.True
		TcpErr(PermissionDenied) => Bool.True
		TcpErr(TimedOut) => Bool.True
		TcpErr(Other(text)) => text.ends_with("NetworkUnreachable") or text.ends_with("HostUnreachable")
		_ => Bool.False
	}

expect unreachable(TcpErr(ConnectionRefused)) and unreachable(TcpErr(TimedOut)) and unreachable(TcpErr(PermissionDenied))
expect unreachable(TcpErr(Other("ErrorKind::NetworkUnreachable"))) and unreachable(TcpErr(Other("ErrorKind::HostUnreachable")))
expect !unreachable(TcpErr(AddrNotAvailable)) and !unreachable(TcpErr(Unsupported)) and !unreachable(TcpErr(Other("ErrorKind::InvalidInput")))
