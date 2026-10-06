#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/BuildGates

## Run the sandboxed-build gates against the real `./blueprint` and real Nix:
## isolation from host files and the host's network, the build runner's
## fail-closed checks, what a build may read and must write, and relocation.
## Run from the repository root, with `./blueprint` built. Needs x86_64 Linux,
## a sandboxing Nix daemon and a writable `/var/tmp`. Only the first step, which
## fetches the pinned inputs, uses the network. `ROC` selects the compiler;
## `BLUEPRINT_TEST_KEEP_TMP=1` keeps a passing run's temporary directory.
## See `fixtures/builds/README.md`.
##
##   scripts/test_builds.roc
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/test_builds.roc")
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

run! = || BuildGates.run!(Env.cwd!()?)
