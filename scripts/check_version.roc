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
import src/Version

## Check the version of a release. Run from the repository root; both forms
## ask GitHub what is published, so they need `GH_TOKEN` or a logged-in `gh`.
## With no VERSION each checks a dry run, which releases nothing.
##
##   scripts/check_version.roc request [VERSION]
##       Before anything is built: VERSION is well formed, its notes exist in
##       docs/releases/, no tag or release of it exists, and it is the version
##       blueprint-cli/main.roc and flake.nix report. A real release also
##       requires the product compiler pin to be the latest official nightly.
##       When `GITHUB_OUTPUT` is
##       set, the version, the release title and whether it is a pre-release
##       and the product compiler tag are added to it.
##
##   scripts/check_version.roc bump [VERSION]
##       After `scripts/bundle.roc VERSION`: `roc bump` compares the core
##       package and the bundled platform with the latest release, and fails
##       unless VERSION bumps at least as far as their public API changed.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		["request"] => Version.request!(root!()?, Bundle.dry_run_version)
		["request", version] => Version.request!(root!()?, version)
		["bump"] => Version.bump!(root!()?, Bundle.dry_run_version)
		["bump", version] => Version.bump!(root!()?, version)
		_ => {
			_ = Stderr.line!("usage: scripts/check_version.roc request|bump [VERSION]")
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
