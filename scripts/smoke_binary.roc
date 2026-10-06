#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/SmokeBinary

## Run a built `blueprint` binary with no Roc and no Python of its own. Run
## from the repository root, where the platform's hosts and linker inputs are.
##
##   scripts/smoke_binary.roc dist/blueprint-x86_64-linux
##
## `scripts/build_release.roc` cross-builds this program as
## `dist/smoke-<system>`, for machines that have Nix and no Roc:
##
##   dist/smoke-aarch64-darwin dist/blueprint-aarch64-darwin
##
## `SMOKE_PACKAGES` names the default package source when the built-in one
## does not support this machine, as on Intel macOS.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	arguments = args.map(OsStr.display)
	program = Env.program_name!().map_ok(OsStr.display) ?? ""
	if SmokeBinary.is_python(program) {
		return SmokeBinary.python!(arguments)
	}
	result = match arguments {
		[binary] => SmokeBinary.run!(binary)
		_ => {
			_ = Stderr.line!("usage: scripts/smoke_binary.roc BLUEPRINT_BINARY")
			return Err(Exit(2))
		}
	}
	match result {
		Ok({}) => Ok({})
		Err(ScriptFailed) => Err(Exit(1))
		Err(other) => {
			_ = Stderr.line!("error: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}
