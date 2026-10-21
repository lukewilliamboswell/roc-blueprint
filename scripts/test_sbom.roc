#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	core: "../blueprint-core/main.roc",
	roc: "nightly-2026-10-13-b17d287",
}
import cli.OsStr
import cli.Path
import cli.Stderr
import src/SbomTest
import core.Spec
import core.Lock

## Native offline SBOM fixture generator
## All tests also run via roc test.
## `scripts/test_sbom.roc OUTPUT` writes the stable interoperable fixture.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| match args.map(OsStr.display) {
	["inputs", directory] => {
		Path.create_all!(Path.utf8(directory)).map_err(|_| Exit(1))?
		for (name, text) in [
			("Spec", SbomTest.spec.to_str()),
			("Lock", SbomTest.lock.to_str()),
			("composition.json", Json.to_str(SbomTest.composition)),
			("inventory.json", Json.to_str(SbomTest.inventory ?? crash "fixture invalid")),
			("subject.json", Json.to_str(SbomTest.subject)),
			("context.json", Json.to_str(SbomTest.context)),
			("sample-artifact", "fixture subject\n"),
		] {
			Path.write_utf8!(Path.utf8("${directory}/${name}"), text).map_err(|_| Exit(1))?
		}
		Ok({})
	}
	[output] => {
		text = SbomTest.output.map_err(|_| Exit(1))?
		Path.write_utf8!(Path.utf8(output), text).map_err(|_| Exit(1))
	}
	_ => {
		_ = Stderr.line!("usage: scripts/test_sbom.roc OUTPUT")
		Err(Exit(2))
	}
}
