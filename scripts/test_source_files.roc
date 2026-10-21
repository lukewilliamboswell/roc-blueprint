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
import src/SourceFilesTest

## Flat source pinning and raw-file use, tested against a local HTTP server.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	real_build = args.map(OsStr.display) == ["--build"]
	if !args.is_empty() and !real_build {
		_ = Stderr.line!("usage: scripts/test_source_files.roc [--build]")
		return Err(Exit(2))
	}
	match SourceFilesTest.run!(Env.cwd!().map_err(|_| Exit(1))?, real_build) {
		Ok({}) => Ok({})
		Err(ScriptFailed) => Err(Exit(1))
		Err(other) => {
			_ = Stderr.line!("error: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}
