#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
	core: "../blueprint-core/main.roc",
	nix: "../blueprint-nix/main.roc",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/CliTest

## Run the real `./blueprint` with the real compiler against stubbed Nix and
## Guix: commands with and without a configuration, compiler selection, the
## order of checks before any effect, and the exact argv providers are given.
## Run from the repository root, with `./blueprint` built. `ROC` names the
## compiler (default `roc`). It needs no network and no Nix.
##
##   scripts/test_cli.roc
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/test_cli.roc")
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

run! = || CliTest.run!(Env.cwd!()?)
