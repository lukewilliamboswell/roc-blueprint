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
import src/ReleaseNotes

## Write the notes of the release of VERSION. Run from the repository root
## after `scripts/bundle.roc VERSION`: the notes written by hand in
## `docs/releases/` are rendered with the URLs the two bundles have in that
## release, in the repository `GITHUB_REPOSITORY` names, and what the release
## was built from is added. A release candidate uses the notes of its version.
## With no VERSION this is a dry run, which renders the newest notes there are.
##
##   scripts/release_notes.roc [VERSION] OUTPUT_FILE
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[output] => run!(Bundle.dry_run_version, output)
		[version, output] => run!(version, output)
		_ => {
			_ = Stderr.line!("usage: scripts/release_notes.roc [VERSION] OUTPUT_FILE")
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

run! = |version, output| ReleaseNotes.write!(Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?, version, output)
