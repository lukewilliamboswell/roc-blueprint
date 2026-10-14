#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Fuzz

## Build and run the roc-fuzz targets in `blueprint-core/fuzz/`. Run from the
## repository root.
##
##   scripts/fuzz.roc                  replay each target's committed corpus (seconds)
##   scripts/fuzz.roc 300              fuzz each target for 300 seconds
##   scripts/fuzz.roc 300 spec-parse   fuzz only the targets named
##
## A crashing input is written under `fuzz-artifacts/`, or the directory named
## by `FUZZ_ARTIFACTS`. When `FUZZ_CORPUS` names a directory, a timed run keeps
## the inputs each target finds in `<FUZZ_CORPUS>/<target>` and starts from
## those the next time.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	how = match Fuzz.request(args.map(OsStr.display)) {
		Ok(chosen) => chosen
		Err(BadArguments) => {
			_ = Stderr.line!("usage: scripts/fuzz.roc [SECONDS [TARGET...]]")
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
