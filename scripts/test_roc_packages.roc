#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/RocPackagesTest

## Check that `RocPackages` makes locked Roc bundles resolve without a
## download: published into Roc's package cache for a shell or task, and in a
## cache of its own for a sandboxed build. Run from the repository root, with
## `./blueprint` built. Needs Nix and the network, and x86_64 Linux for the
## build. It uses a package cache of its own in a temporary directory.
##
##   scripts/test_roc_packages.roc
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/test_roc_packages.roc")
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

run! = || RocPackagesTest.run!(Env.cwd!()?)
