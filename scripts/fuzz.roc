#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Fuzz

## Build and run the roc-fuzz targets in `blueprint-core/fuzz/`. Run from the
## repository root.
##
##   scripts/fuzz.roc           replay each target's committed corpus (seconds)
##   scripts/fuzz.roc 300       fuzz each target for 300 seconds
##
## A crashing input is written under `fuzz-artifacts/`, or the directory named
## by `FUZZ_ARTIFACTS`.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	how = match Fuzz.mode(args.map(OsStr.display)) {
		Ok(chosen) => chosen
		Err(BadArguments) => {
			_ = Stderr.line!("usage: scripts/fuzz.roc [SECONDS]")
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

run! = |how| Fuzz.run!(Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?, how)
