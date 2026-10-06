app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst" }

import cli.OsStr
import cli.Path
import cli.Random
import cli.Stderr
import cli.Stdout
import cli.Utc

## Unsandboxed workflow tasks: exact argv events and deliberate source edits.
##
##   roc-stable task.roc -- EVENTS MODE ARGS...
##
## Every run adds a record of `MODE ARGS...` to the directory EVENTS, in the
## form the suite's recording `nix` uses: each argument followed by a NUL
## byte, in a file whose name starts with the time. It also prints `task` and
## the same bytes in hexadecimal. MODE is `record`, `prepare`, `edit`, `dirty`
## or `fail`.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args|
	match run!(args) {
		Ok({}) => Ok({})
		Err(Exit(code)) => Err(Exit(code))
		Err(other) => {
			_ = Stderr.line!("fixture task: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}

run! : List(OsStr) => Try({}, _)
run! = |args| {
	(events, argv) = match args {
		[first, .. as rest] => (Path.from_os_str(first), rest)
		[] => return Err(Failed("usage: task.roc EVENTS MODE ARGS..."))
	}
	event = argv.fold([], |bytes, arg| bytes.concat(arg.to_bytes()).append(0))
	# The caller-owned log is outside the project, so logging cannot bust caches.
	Path.write_bytes!(Path.join(events, "${stamp(Utc.now!())}-${Random.seed_u64!()?.to_str()}.task"), event)?
	Stdout.line!("task ${hex(event)}")?
	match argv.map(OsStr.display) {
		["record", ..] => {}
		["prepare"] => Path.write_bytes!("task-produced.bin", "task-generated".to_utf8().append(0).concat("bytes\n".to_utf8()))?
		["edit"] => {
			Path.write_bytes!("source.bin", "second".to_utf8().append(0).concat("revision".to_utf8()).append(255).append('\n'))?
			Path.write_bytes!("task-produced.bin", "changed by task".to_utf8().append(0).append(254).append('\n'))?
		}
		["dirty"] => Path.write_bytes!("assets/message.txt", "dirty locked source".to_utf8().append(0).append('\n'))?
		["fail"] => {
			_ = Stderr.line!("intentional task failure")
			return Err(Exit(23))
		}
		_ => return Err(Failed("unknown fixture task"))
	}
	if Path.exists!("INJECTED")? {
		return Err(Failed("task argv was interpreted by a shell"))
	}
	Ok({})
}

## Nanoseconds since the epoch, padded so that names sort as numbers do.
stamp : U128 -> Str
stamp = |nanos| {
	digits = nanos.to_str()
	"${Str.repeat("0", 24 - digits.to_utf8().len())}${digits}"
}

hex : List(U8) -> Str
hex = |bytes| Str.from_utf8_lossy(bytes.fold([], |out, byte| out.append(digit(byte // 16)).append(digit(byte % 16))))

digit : U8 -> U8
digit = |nibble| if nibble < 10 '0' + nibble else 'a' + (nibble - 10)

expect stamp(7) == "000000000000000000000007"
expect hex([0, 255, 16, 'a']) == "00ff1061"
