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

## Gather what a release publishes. Run from the repository root once
## everything is built for VERSION: the binaries (`scripts/build_release.roc`),
## the bundles (`scripts/bundle.roc`), the examples archive
## (`scripts/package_examples.roc`) and the documentation archive
## (`scripts/package_docs.roc`). MANUAL_PDF is the rendered manual.
##
##   scripts/release_assets.roc VERSION MANUAL_PDF
##
## The assets are copied into `dist/release/` under the names they are
## published with, and those names are listed in `dist/release-assets.txt`.
## This fails if any is missing, and if the binaries and `blueprint.sha256`
## are not exactly the ones roc-automation's `setup-blueprint` action expects.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[version, pdf] => run!(version, pdf)
		_ => {
			_ = Stderr.line!("usage: scripts/release_assets.roc VERSION MANUAL_PDF")
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

run! = |version, pdf| {
	root = Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?
	Assets.collect!(root, version, Path.to_str(Path.canonicalize!(Path.utf8(pdf))?)?)
}
