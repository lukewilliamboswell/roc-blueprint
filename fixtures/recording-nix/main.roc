app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst" }

import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Random
import cli.Stderr
import cli.Utc

## The build and workflow suites install this program as `nix`, first on
## `PATH`. It is not a fake: it records its arguments, then runs the real Nix
## with `--offline` and the same input and output, and exits as Nix did.
##
## `NIX_RECORDER_EVENTS` names the directory that receives one file per
## invocation and `NIX_RECORDER_REAL` the real Nix. A record holds each
## argument followed by a NUL byte. Its name starts with the time, so sorting
## the names gives the order of invocation; basic-cli cannot append to a file.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args|
	match record_and_run!(args) {
		Ok(0) => Ok({})
		Ok(code) => Err(Exit(code))
		Err(_) => {
			_ = Stderr.line!("recording nix: NIX_RECORDER_EVENTS and NIX_RECORDER_REAL must name a writable directory and the real nix")
			Err(Exit(125))
		}
	}

record_and_run! : List(OsStr) => Try(I32, _)
record_and_run! = |args| {
	events = Path.from_os_str(Env.var!("NIX_RECORDER_EVENTS")?)
	real = Env.var!("NIX_RECORDER_REAL")?
	name = "${stamp(Utc.now!())}-${Random.seed_u64!()?.to_str()}.nix"
	Path.write_bytes!(Path.join(events, name), args.fold([], |bytes, arg| bytes.concat(arg.to_bytes()).append(0)))?
	ran = Cmd.new(real).arg("--offline").args(args)
		.stdin(Inherit)
		.stdout(Inherit)
		.stderr(Inherit)
		.run!()?
	match ran.status {
		Exited(code) => Ok(code)
		Signaled(signal) => Ok(128 + signal)
	}
}

## Nanoseconds since the epoch, padded so that names sort as numbers do.
stamp : U128 -> Str
stamp = |nanos| {
	digits = nanos.to_str()
	"${Str.repeat("0", 24 - digits.to_utf8().len())}${digits}"
}

expect stamp(7) == "000000000000000000000007"
expect stamp(1791278446036535640) == "000001791278446036535640"
