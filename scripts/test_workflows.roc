#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
}

import cli.Env
import cli.OsStr
import cli.Stderr
import src/BuildWorkflowGates

## Run the workflow gates against the real `./blueprint` and real Nix: the
## order of tasks and builds within one workflow, a failure stopping later
## steps, workflows with no effect, and locked sources verified again before
## every build; then a copy of `examples/artifacts`. Run from the repository
## root, with `./blueprint` built. Needs x86_64 Linux and a sandboxing Nix
## daemon. Only the first step, which fetches the pinned inputs, uses the
## network. `ROC` selects the compiler; `BLUEPRINT_TEST_KEEP_TMP=1` keeps a
## passing run's temporary directory. See `fixtures/workflows/README.md`.
##
##   scripts/test_workflows.roc
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	if !args.is_empty() {
		_ = Stderr.line!("usage: scripts/test_workflows.roc")
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

run! = || BuildWorkflowGates.run!(Env.cwd!()?)
