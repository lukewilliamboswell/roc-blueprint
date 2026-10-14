#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Release

## Cross-build the blueprint CLI for x86_64 Linux, arm64 Linux and Apple
## Silicon macOS into `dist/blueprint-<system>`, with their SHA-256 sums in
## `dist/blueprint.sha256`, and the smoke-test program for each as
## `dist/smoke-<system>`. Run from the repository root on x86_64 Linux, after
## `scripts/link_inputs.roc fetch`. Needs Nix and Zig; the compiler is the
## flake's `roc-cross` package.
##
##   scripts/build_release.roc
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/build_release.roc")
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

run! = || Release.run!(Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?)
