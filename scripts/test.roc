#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/TestSuite

## Everything CI checks. Run from the repository root, inside `nix develop`
## or with the same tools on `PATH`: roc, zig 0.16, nix, git, tar and curl.
##
##   scripts/test.roc                  every group, in order
##   scripts/test.roc unit package     only those groups
##
## Groups: static, unit, cli, nix, package, fuzz. CI runs them as parallel
## jobs. The cli and nix groups use ./blueprint; they build it unless
## BLUEPRINT_PREBUILT=1 says the caller already put a tested binary there.
## With it, platform hosts that are all present are not rebuilt either: set it
## only when both were built from the commit under test.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	names = match TestSuite.requested(args.map(OsStr.display)) {
		Ok(chosen) => chosen
		Err(UnknownGroup(name)) => {
			_ = Stderr.line!("unknown test group: ${name}")
			return Err(Exit(2))
		}
	}
	match run!(names) {
		Ok({}) => Ok({})
		Err(ScriptFailed) => Err(Exit(1))
		Err(other) => {
			_ = Stderr.line!("error: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

run! = |names| TestSuite.run!(Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?, names)
