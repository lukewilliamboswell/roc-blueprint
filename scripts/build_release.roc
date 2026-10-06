#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
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
## `scripts/link_inputs.roc fetch`. Needs Nix, Zig and tar.
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
