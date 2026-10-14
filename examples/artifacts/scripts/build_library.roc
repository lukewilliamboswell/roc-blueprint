app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst" }

import cli.Path

## Build from the current filtered project snapshot, not a locked Source.
main! = |_args| build!().map_err(|_| Exit(1))

build! = || {
	message = Path.read_utf8!("src/message.txt")?
	Path.create_dir!("dist")?
	Path.write_utf8!("dist/library.txt", message.with_ascii_uppercased())
}
