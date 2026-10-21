## Independent operational-report consumer; all I/O stays in main!.
app [main!] {
	core: "../../blueprint-core/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
}

import core.LockSnapshot
import pf.OsStr
import pf.Path
import pf.File
import pf.Stdout
import Checks

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	text = match args {
		[] => LockSnapshot.to_json(Checks.example).map_err(|_| Exit(1))?
		[file] => {
			input = read_bounded!(Path.from_os_str(file)).map_err(|_| Exit(1))?
			snapshot = LockSnapshot.parse_json(input).map_err(|_| Exit(1))?
			LockSnapshot.to_json(snapshot).map_err(|_| Exit(1))?
		}
		_ => return Err(Exit(2))
	}
	Stdout.write!(text).map_err(|_| Exit(1))
}

## The effect boundary bounds allocation before passing text to the pure codec.
read_bounded! = |path| {
	reader = File.open_reader!(path).map_err(|_| Exit(1))?
	var $bytes = []
	while True {
		match reader.read_up_to!(U64.min(65536, 8388609 - $bytes.len())) {
			Ok(chunk) => {
				$bytes = $bytes.concat(chunk)
				if $bytes.len() > 8388608 {
					return Err(Exit(1))
				}
			}
			Err(EndOfInput) => return Str.from_utf8($bytes).map_err(|_| Exit(1))
			Err(_) => return Err(Exit(1))
		}
	}
}
