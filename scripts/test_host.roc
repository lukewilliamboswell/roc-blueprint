#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
	core: "../blueprint-core/main.roc",
	nix: "../blueprint-nix/main.roc",
	roc: "nightly-2026-10-04-130536d",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/CliHostTest

## Run the real `./blueprint` with the host provider, the one Windows uses,
## selected on this machine by `BLUEPRINT_PROVIDER=host`: what it refuses, and
## the tasks it runs from a lock the Nix provider wrote. Every program it would
## fetch with or look for is a stub. Run from the repository root, with
## `./blueprint` built. `ROC` names the compiler (default `roc`). It needs no
## network, no Nix and no Windows, and so shows nothing about Windows itself.
##
##   scripts/test_host.roc
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/test_host.roc")
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

run! = || CliHostTest.run!(Env.cwd!()?)
