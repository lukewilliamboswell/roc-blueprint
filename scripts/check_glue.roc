#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Glue

## Regenerate the platform host's Zig bindings with `roc glue` and the product
## compiler, and compare them with the committed file. Run from the
## repository root.
##
##   scripts/check_glue.roc            fail if the committed bindings differ
##   scripts/check_glue.roc --update   write the regenerated bindings
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	how = match Glue.mode(args.map(OsStr.display)) {
		Ok(chosen) => chosen
		Err(BadArguments) => {
			_ = Stderr.line!("usage: scripts/check_glue.roc [--update]")
			return Err(Exit(2))
		}
	}
	match run!(how) {
		Ok({}) => Ok({})
		Err(ScriptFailed) => Err(Exit(1))
		Err(other) => {
			_ = Stderr.line!("error: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

run! = |how| Glue.run!(Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?, how)
