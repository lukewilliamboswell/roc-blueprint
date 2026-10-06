#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Bundle

## Bundle roc-blueprint-core or the roc-blueprint platform into `dist/`. Run
## from the repository root; the platform needs the linker inputs installed by
## `scripts/link_inputs.roc fetch`.
##
##   scripts/bundle.roc core
##       Bundle the core package.
##
##   scripts/bundle.roc platform [CORE_URL]
##       Bundle the platform with its `core` dependency pointing at CORE_URL, a
##       published roc-blueprint-core bundle (a release uses
##       blueprint-platform/core-release). With no CORE_URL, the local
##       blueprint-core/ is bundled and served from localhost.
##
## Each archive is written to `dist/<hash>.tar.zst` and listed in
## `dist/bundles.txt`. A platform bundle is smoke-tested before this returns.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		["core"] => Bundle.core!(root!()?)
		["platform"] => Bundle.platform!(root!()?, "")
		["platform", core_url] => Bundle.platform!(root!()?, core_url)
		_ => {
			_ = Stderr.line!("usage: scripts/bundle.roc core | platform [CORE_URL]")
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

root! = || {
	directory = Path.canonicalize!(Env.cwd!().map_err(|_| Exit(1))?).map_err(|_| Exit(1))?
	Path.to_str(directory).map_err(|_| Exit(1))
}
