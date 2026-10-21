#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	compilers: "../blueprint-cli/compilers.roc",
	roc: "nightly-2026-10-13-b17d287",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import compilers.Bootstrap
import src/Integrity
import src/Process
import src/Script
import "../blueprint-cli/compiler-version" as compiler_version : Str

## Stage one target's compiler archive before compiling blueprint. The
## archive is cached by digest and checked on every use, including cache hits.
## `nix develop` stages the local host automatically; release cross-builds
## call this once per target, then restore the local archive.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		[system] => stage!(system)
		_ => Script.fail!("usage: scripts/embed_compiler.roc <system>")
	}
	match result {
		Ok({}) => Ok({})
		Err(other) => {
			_ = Stderr.line!("error: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

stage! = |system| {
	root = Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?
	program = Bootstrap.compiler(compiler_version.trim(), system)?
	cache = "${root}/.cache/compilers"
	Path.create_all!(Path.utf8(cache))?
	archive = "${cache}/${program.sha256}"
	if !(Path.is_file!(Path.utf8(archive)) ?? False) {
		url = program.urls.first()?
		Process.passthrough!(Process.command("curl", ["--fail", "--location", "--retry", "3", "--proto", "=https", "--proto-redir", "=https", "--output", "${archive}.part", url], root))?
		bytes = Path.read_bytes!(Path.utf8("${archive}.part"))?
		Integrity.verify(bytes, { sha256: program.sha256, size: program.size })?
		Path.rename!(Path.utf8("${archive}.part"), Path.utf8(archive))?
	}
	bytes = Path.read_bytes!(Path.utf8(archive))?
	Integrity.verify(bytes, { sha256: program.sha256, size: program.size })?
	Path.write_bytes!(Path.utf8("${root}/blueprint-cli/compiler-archive"), bytes)?
	Script.pass!("staged ${compiler_version.trim()} for ${system}")
}
