#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Assets

## Archive the documentation of a release. Run from the repository root after
## the manual is rendered; SITE_DIRECTORY is the site, with the manual's PDF
## and the platform's API reference in it.
##
##   scripts/package_docs.roc VERSION SITE_DIRECTORY
##
## The archive is `dist/roc-blueprint-docs-<version>.zip`.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[version, site] => run!(version, site)
		_ => {
			_ = Stderr.line!("usage: scripts/package_docs.roc VERSION SITE_DIRECTORY")
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

run! = |version, site| {
	root = Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?
	Assets.package_docs!(root, version, Path.to_str(Path.canonicalize!(Path.utf8(site))?)?)
}
