#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	core: "../blueprint-core/main.roc",
	nix: "../blueprint-nix/main.roc",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/ReproducibleProbe

## A small real-Nix producer probe for two independent CI hosts. The synthetic
## variant compiles a native CLI whose only source change is its version literal.
## The comparison reads JSON only; it performs no builds or network operations.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		["run", variant, output] => ReproducibleProbe.run!(Env.cwd!().map_err(|_| Exit(1))?, variant, output)
		["compare", first, second] => ReproducibleProbe.compare!(first, second)
		_ => {
			_ = Stderr.line!("usage: scripts/reproducible_probe.roc run release|synthetic OUTPUT | compare FIRST SECOND")
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
