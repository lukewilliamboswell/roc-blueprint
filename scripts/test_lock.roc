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
import src/CliLockTest

## Inspect committed locks without a compiler, Nix, project evaluation or writes.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/test_lock.roc")
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

run! = || CliLockTest.run!(Env.cwd!()?)
