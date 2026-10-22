#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	compilers: "../blueprint-cli/compilers.roc",
	core: "../blueprint-core/main.roc",
	nix: "../blueprint-nix/main.roc",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/CliProgramsTest

## Run the real `./blueprint` on projects whose environments fetch programs
## and expect tools of the machine: what is downloaded, verified, kept and put
## on PATH, what is refused, and that Nix starts only for an environment with
## a Nix tool. Downloads come from a server this script runs on the loopback
## address, and `nix` is a stub that records being started. Run from the
## repository root, with `./blueprint` built. `ROC` names the compiler
## (default `roc`). It needs no network and no Nix.
##
##   scripts/test_programs.roc
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/test_programs.roc")
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

run! = || CliProgramsTest.run!(Env.cwd!()?)
