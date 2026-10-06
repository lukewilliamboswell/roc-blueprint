#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/LinkInputs

## Install or verify the platform's linker inputs, as pinned by
## `link-inputs.lock.json`. Run from the repository root.
##
##   scripts/link_inputs.roc fetch   download if not cached, verify, install
##   scripts/link_inputs.roc check   verify the installed files, offline
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		["fetch"] => run!(LinkInputs.fetch!)
		["check"] => run!(LinkInputs.check!)
		_ => {
			_ = Stderr.line!("usage: scripts/link_inputs.roc fetch | check")
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

run! = |operation!| operation!(Env.cwd!()?)
