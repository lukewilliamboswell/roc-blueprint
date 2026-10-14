app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst" }

import cli.Path
import cli.Stderr
import cli.Stdout

## An ordinary unsandboxed task: it checks working-tree source, not an artifact.
main! = |_args| {
	message = Path.read_utf8!("src/message.txt") ?? ""
	if message.is_empty() or !message.ends_with("\n") {
		_ = Stderr.line!("src/message.txt must be nonempty and end with a newline")
		Err(Exit(1))
	} else {
		Stdout.line!("source checked").map_err(|_| Exit(1))
	}
}
