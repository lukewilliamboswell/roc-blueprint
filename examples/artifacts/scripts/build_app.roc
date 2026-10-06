app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst" }

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
