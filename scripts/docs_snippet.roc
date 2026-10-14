#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Published

## Write the part of the manual that depends on what is released: the first
## `Blueprint.roc` of the Get started chapter, which names a release's
## platform bundle. Run from the repository root before rendering `docs/`.
##
##   scripts/docs_snippet.roc
##       For the latest published release, which `gh` reports; it needs
##       `GH_TOKEN` or a logged-in `gh`.
##
##   scripts/docs_snippet.roc VERSION
##       For the release of VERSION being built, after `scripts/bundle.roc
##       VERSION`.
##
## The file is `docs/generated/latest-release.adoc`, which is not committed.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[] => Published.latest!(root!()?)
		[version] => Published.built!(root!()?, version)
		_ => {
			_ = Stderr.line!("usage: scripts/docs_snippet.roc [VERSION]")
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
