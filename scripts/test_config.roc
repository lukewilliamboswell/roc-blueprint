#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import src/ConfigTest
import src/Process

## Check that whole-config validation happens in `roc check`, against the
## local platform. Run from the repository root, after
## `scripts/link_inputs.roc fetch` and `zig build` in `blueprint-platform`.
## `scripts/bundle.roc` runs a few of the same fixtures against a served bundle.
##
##   scripts/test_config.roc
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/test_config.roc")
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

run! = || {
	root = Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?
	work = Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-config-")?)?
	directory = Path.to_str(work)?
	result = ConfigTest.run!(
		{
			roc: Process.roc!(),
			# `roc check` accepts an absolute platform path; running an app does not.
			platform_ref: Process.relative(directory, "${root}/blueprint-platform/main.roc"),
			work: directory,
			subset: Full,
			environment: [],
		},
		in_batches!,
	)
	_ = Path.delete_all!(work)
	result
}

## Eight compilers at a time.
in_batches! = |cmds| {
	var $outcomes = []
	for batch in Process.batches(cmds, 8) {
		$outcomes = $outcomes.concat(Process.together!(batch)?)
	}
	Ok($outcomes)
}
