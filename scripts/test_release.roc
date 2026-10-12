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

## Test what a release ships, as a user will get it. Run from the repository
## root after `scripts/bundle.roc` and `scripts/package_examples.roc` with the
## same VERSION.
##
##   scripts/test_release.roc [VERSION [BLUEPRINT_BINARY]]
##
## The examples archive in `dist/` is unpacked and compared with `examples/`:
## only each platform line may differ. Then, with an empty package cache and
## the two bundles of `dist/` served from localhost at the paths the release
## will give them, the compiler checks each archived example and must print
## the Spec the archive records for it. Given a `blueprint` binary, that
## binary must print the same Specs. With no VERSION this tests a dry run.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[] => run!(Bundle.dry_run_version, "")
		[version] => run!(version, "")
		[version, binary] => run!(version, binary)
		_ => {
			_ = Stderr.line!("usage: scripts/test_release.roc [VERSION [BLUEPRINT_BINARY]]")
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

run! = |version, given| {
	root = Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?
	# The binary runs in each example's directory.
	binary = if given.is_empty() "" else Path.to_str(Path.canonicalize!(Path.utf8(given))?)?
	Examples.test!(root, version, binary)
}
