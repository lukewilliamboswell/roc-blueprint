#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/Scenarios

## Run projects through the real `./blueprint` and real Nix: the all-settings
## and extensions examples, scoped overlays, system-scoped tools and renamed
## commands. Run from the repository root, with `./blueprint` built. Needs Nix
## and the network.
##
##   scripts/test_scenarios.roc
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/test_scenarios.roc")
		return Err(Exit(2))
	}
	match run!() {
		Ok({}) => Ok({})
		Err(ScriptFailed) => Err(Exit(1))
		Err(other) => {
			_ = Stderr.line!("error: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

run! = || Scenarios.run!(Env.cwd!()?)
