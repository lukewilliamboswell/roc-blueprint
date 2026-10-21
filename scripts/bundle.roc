#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Bundle

## Bundle core, the platform and the supported standalone SBOM app into `dist/`.
## Run from the repository root; the platform needs the linker inputs
## installed by `scripts/link_inputs.roc fetch`.
##
##   scripts/bundle.roc [VERSION]
##       Bundle the core package, then the platform with its `core`
##       dependency pointing at the URL that bundle will have in the release
##       of VERSION, in the repository `GITHUB_REPOSITORY` names. With no
##       VERSION this is a dry run of a version that is never released.
##
## The platform's archive is `dist/<hash>.tar.zst` and the core package's
## `dist/roc-blueprint-core-<hash>.tar.zst`; both are listed in
## `dist/bundles.txt`, alongside `roc-blueprint-sbom-<hash>.tar.zst`. The app
## uses the selected release compiler pin and immutable core URL. All are smoke-tested from localhost before this
## returns.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[] => Bundle.run!(root!()?, Bundle.dry_run_version)
		[version] => Bundle.run!(root!()?, version)
		_ => {
			_ = Stderr.line!("usage: scripts/bundle.roc [VERSION]")
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
