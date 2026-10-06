#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/ReleaseNotes

## Write the notes of a GitHub release. Run from the repository root after
## `scripts/bundle.roc`, with `GITHUB_REPOSITORY` and `GITHUB_REF_NAME` set as
## a workflow sets them: a tag `core-X.Y.Z` is a roc-blueprint-core release,
## any other tag a platform release. When `GITHUB_OUTPUT` is set, the bundle's
## file name, the release title and whether it is a pre-release are added to it.
##
##   scripts/release_notes.roc dist/notes.md
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[output] => run!(output)
		_ => {
			_ = Stderr.line!("usage: scripts/release_notes.roc OUTPUT_FILE")
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

run! = |output| ReleaseNotes.write!(Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?, output)
