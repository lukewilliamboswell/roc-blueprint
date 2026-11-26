#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-25-d5a4f1e",
}
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/Bundle
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |_args| {
	root = Path.to_str(Path.canonicalize!(Env.cwd!().map_err(|_| Exit(1))?).map_err(|_| Exit(1))?).map_err(|_| Exit(1))?
	match Bundle.check_snapshot_bundle!(root, Bundle.dry_run_version) {
		Ok({}) => Ok({})
		Err(error) => {
			_ = Stderr.line!(Str.inspect(error))
			Err(Exit(1))
		}
	}
}
