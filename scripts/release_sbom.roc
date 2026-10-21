#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	compilers: "../blueprint-cli/compilers.roc",
	core: "../blueprint-core/main.roc",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/ReleaseSbom

## Hash completed binaries and source bundles and write separate SPDX sidecars.
## scripts/release_sbom.roc VERSION CREATED SOURCE_COMMIT DOCUMENT_REVISION
## CREATED is explicit UTC ISO8601; SOURCE_COMMIT is the selected source commit.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[version] => {
			root = Path.to_str(Path.canonicalize!(Env.cwd!().map_err(|_| Exit(1))?).map_err(|_| Exit(1))?).map_err(|_| Exit(1))?
			ReleaseSbom.from_git!(root, version)
		}
		[version, created, commit, revision] => {
			root = Path.to_str(Path.canonicalize!(Env.cwd!().map_err(|_| Exit(1))?).map_err(|_| Exit(1))?).map_err(|_| Exit(1))?
			ReleaseSbom.run!(root, version, created, commit, revision)
		}
		_ => Err(Invalid("usage: scripts/release_sbom.roc VERSION CREATED SOURCE_COMMIT DOCUMENT_REVISION"))
	}
	match result {
		Ok({}) => Ok({})
		Err(error) => {
			_ = Stderr.line!("SBOM: ${Str.inspect(error)}")
			Err(Exit(1))
		}
	}
}
