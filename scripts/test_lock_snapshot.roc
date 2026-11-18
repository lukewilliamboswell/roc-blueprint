#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	core: "../blueprint-core/main.roc",
	roc: "nightly-2026-11-18-a520eed",
}
import cli.OsStr
import cli.Stderr
import src/LockSnapshotTest

## The lock snapshot contract, `blueprint-core/lock-snapshot-v2.schema.json`
## and its profile, checked in Roc against a built official consumer. All
## expects run via `roc test`.
##
##   scripts/test_lock_snapshot.roc CONSUMER   check a built fixtures/lock-snapshot/main.roc
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| match args.map(OsStr.display) {
	[consumer] => LockSnapshotTest.run!(consumer).map_err(|_| Exit(1))
	_ => {
		_ = Stderr.line!("usage: scripts/test_lock_snapshot.roc CONSUMER")
		Err(Exit(2))
	}
}
