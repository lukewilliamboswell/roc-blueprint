#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	core: "../blueprint-core/main.roc",
	nix: "../blueprint-nix/main.roc",
	roc: "nightly-2026-11-25-d5a4f1e",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/BuildPlanningTest

## Verify structural build plans and local explanations against stubbed tools.
## The suite removes Nix before inspection and works on any supported host.
## Run from the repository root with ./blueprint built.

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/test_build_planning.roc")
		return Err(Exit(2))
	}
	match run!() {
		Ok({}) => Ok({})
		Err(ScriptFailed) => Err(Exit(1))
		Err(other) => {
			_ = Stderr.line!("error: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

run! = || BuildPlanningTest.run!(Env.cwd!()?)
