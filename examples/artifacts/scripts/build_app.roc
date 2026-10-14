app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst" }

import cli.Env
import cli.Path

## Combine a locked source and exactly the declared dependency output.
main! = |_args| build!().map_err(|_| Exit(1))

build! = || {
	# Both inputs are read-only store views, separate from this writable project.
	assets = Path.join(Path.from_os_str(Env.var!("BLUEPRINT_INPUTS")?), "assets")
	library = Path.join(Path.from_os_str(Env.var!("BLUEPRINT_ARTIFACTS")?), "library")
	heading = Path.read_bytes!(Path.join(assets, "heading.txt"))?
	Path.create_dir!("dist")?
	Path.write_bytes!("dist/app.txt", heading.concat(Path.read_bytes!(library)?))
}
