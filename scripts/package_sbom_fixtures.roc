#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-24-ff5e544",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Bundle
import src/SbomFixtures

## Archive the SBOM fixture set for a release. Run from the repository root.
##
##   scripts/package_sbom_fixtures.roc [VERSION]
##
## `dist/roc-blueprint-sbom-fixtures-<version>.zip` holds every tracked file
## of `tests/sbom/fixtures/`: the rendered cases, the standalone tool's
## inputs, the source supplier import with its refusals, the upstream
## documents and `CONTRACT.md`, which states what each case proves. With no
## VERSION this is a dry run.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[] => run!(Bundle.dry_run_version)
		[version] => run!(version)
		_ => {
			_ = Stderr.line!("usage: scripts/package_sbom_fixtures.roc [VERSION]")
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

run! = |version| SbomFixtures.package!(Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?, version)
