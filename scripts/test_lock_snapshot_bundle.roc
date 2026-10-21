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
