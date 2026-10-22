#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	core: "../blueprint-core/main.roc",
	roc: "nightly-2026-10-13-b17d287",
}
import cli.OsStr
import cli.Path
import cli.Stderr
import src/SbomBindingTest
import src/SbomTest

## Native offline SBOM fixtures and binding checks. All expects run via
## `roc test`.
##
##   scripts/test_sbom.roc fixtures DIRECTORY       write every SPDX 3.0.1, 2.3 and CycloneDX fixture
##   scripts/test_sbom.roc inputs DIRECTORY         write the binding tool's native inputs
##   scripts/test_sbom.roc source-import DIRECTORY  write the source supplier import's inputs and refusals
##   scripts/test_sbom.roc contract FILE            write the case contract
##   scripts/test_sbom.roc binding TOOL INPUTS SOURCE_IMPORT  check a built scripts/sbom.roc
##   scripts/test_sbom.roc OUTPUT                   write the native-linux SPDX 3.0.1 fixture
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| match args.map(OsStr.display) {
	["fixtures", directory] => write_all!(directory, SbomTest.outputs)
	["inputs", directory] => write_all!(directory, SbomTest.input_files)
	["source-import", directory] => write_all!(directory, SbomTest.source_import_files)
	["contract", file] => Path.write_utf8!(Path.utf8(file), SbomTest.contract).map_err(|_| Exit(1))
	["binding", tool, inputs, source_import] => SbomBindingTest.run!(tool, inputs, source_import).map_err(|_| Exit(1))
	[output] => {
		text = SbomTest.output.map_err(|_| Exit(1))?
		Path.write_utf8!(Path.utf8(output), text).map_err(|_| Exit(1))
	}
	_ => {
		_ = Stderr.line!("usage: scripts/test_sbom.roc fixtures DIRECTORY | inputs DIRECTORY | source-import DIRECTORY | contract FILE | binding TOOL INPUTS SOURCE_IMPORT | OUTPUT")
		Err(Exit(2))
	}
}

write_all! : Str, List({ name : Str, text : Str }) => Try({}, [Exit(I32)])
write_all! = |directory, files| {
	Path.create_all!(Path.utf8(directory)).map_err(|_| Exit(1))?
	for file in files {
		Path.write_utf8!(Path.utf8("${directory}/${file.name}"), file.text).map_err(|_| Exit(1))?
	}
	Ok({})
}
