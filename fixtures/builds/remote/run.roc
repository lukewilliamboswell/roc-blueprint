app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst" }

import cli.OsStr
import cli.Path
import cli.Stderr

## The command of a build whose fetched source the runner must check first.
## It says on stderr that it ran and writes the nonce it was given, so that
## neither a cached result nor silence can stand in for a real run.
##
##   roc-stable run.roc NONCE
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args|
	match args.map(OsStr.display) {
		[nonce] => {
			_ = Stderr.line!("USER_RUN_REACHED_${nonce}")
			Path.write_utf8!("output", nonce).map_err(|_| Exit(1))
		}
		_ => Err(Exit(2))
	}
