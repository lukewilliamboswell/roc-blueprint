app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst" }

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr

## Sandboxed artifacts expose exact current-source and dependency bytes.
##
##   roc-stable build.roc -- library
##   roc-stable build.roc -- app ARGS...
##   roc-stable build.roc -- fail
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		["fail"] => {
			_ = Stderr.line!("intentional build failure")
			return Err(Exit(29))
		}
		["library"] => library!()
		["app", .. as rest] => app!(rest)
		_ => Err(Failed("unknown fixture build"))
	}
	match result {
		Ok({}) => Ok({})
		Err(other) => {
			_ = Stderr.line!("fixture build: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

library_bytes! : () => Try(List(U8), _)
library_bytes! = || Ok("library".to_utf8().append(0).concat(Path.read_bytes!("source.bin")?))

library! : () => Try({}, _)
library! = || {
	Path.create_dir!("dist")?
	Path.write_bytes!("dist/library", library_bytes!()?)
}

app! : List(Str) => Try({}, _)
app! = |argv| {
	# The farm entry is a link; its target is the dependency's store path.
	library = Path.canonicalize!(Path.join(Path.from_os_str(Env.var!("BLUEPRINT_ARTIFACTS")?), "library"))?
	asset = Path.join(Path.from_os_str(Env.var!("BLUEPRINT_INPUTS")?), "assets/message.txt")
	dependency = Path.read_bytes!(library)?
	# These must be the dependency rebuilt from THIS operation's snapshot.
	if dependency != library_bytes!()? {
		return Err(Failed("the library was built from other source bytes"))
	}
	generated = if Path.exists!("task-produced.bin")? Path.read_bytes!("task-produced.bin")? else "<absent>".to_utf8()
	Path.create_all!("dist/app")?
	Path.write_bytes!("dist/app/payload", "app".to_utf8().append(0).concat(dependency).append('|').concat(generated).append('|').concat(Path.read_bytes!(asset)?))?
	Path.write_bytes!("dist/app/library-path", Path.to_os_str(library).to_bytes().append('\n'))?
	Path.write_utf8!("dist/app/argv.json", "${Json.to_str(argv)}\n")?
	if Path.exists!("INJECTED")? {
		return Err(Failed("build argv was shell-interpreted"))
	}
	Ok({})
}
