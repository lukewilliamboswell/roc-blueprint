#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
	roc: "nightly-2026-10-04-130536d",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Bundle
import src/Examples

## Archive the example projects for a release. Run from the repository root
## after `scripts/bundle.roc` with the same VERSION, with the platform host
## built.
##
##   scripts/package_examples.roc [VERSION]
##
## `dist/roc-blueprint-examples-<version>.zip` holds every tracked file of
## each project under `examples/`, the platform line of each `Blueprint.roc`
## set to the bundle's URL in the release of VERSION, with the Spec each
## project prints and a README. With no VERSION this is a dry run.
## `scripts/test_release.roc` tests the archive.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[] => run!(Bundle.dry_run_version)
		[version] => run!(version)
		_ => {
			_ = Stderr.line!("usage: scripts/package_examples.roc [VERSION]")
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

run! = |version| Examples.package!(Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?, version)
