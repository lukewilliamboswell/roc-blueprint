app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst" }

import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr

## Build commands for `blueprint __build-runner` when the suite runs it on the
## host, where no environment supplies `roc-stable`. The suite builds this
## program once and names it by absolute path.
##
##   runner_payload exit CODE          exit with that code
##   runner_payload terminate          die of SIGTERM
##   runner_payload direct-out         write `$out` as well as the declared output
##   runner_payload replace-workspace  move the project copy and leave a link
##   runner_payload mark FILE          write FILE, then the declared output
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		["exit", code] => Err(Exit(I32.from_str(code) ?? 1))
		["terminate"] => terminate!()
		["direct-out"] => direct_out!()
		["replace-workspace"] => replace_workspace!()
		["mark", file] => mark!(file)
		_ => Err(Failed("unknown runner payload"))
	}
	match result {
		Ok({}) => Ok({})
		Err(Exit(code)) => Err(Exit(code))
		Err(other) => {
			_ = Stderr.line!("runner payload: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

## basic-cli cannot send a signal, so `kill` sends it to this process, whose
## identifier is the first field of `/proc/self/stat`.
terminate! : () => Try({}, _)
terminate! = || {
	own = Path.read_utf8!("/proc/self/stat")?.split_on(" ").first() ?? ""
	Cmd.new("kill").args(["-TERM", OsStr.from_str(own)]).exec_cmd!()?
	Err(Failed("SIGTERM did not end this process"))
}

direct_out! : () => Try({}, _)
direct_out! = || {
	Path.write_utf8!(Path.from_os_str(Env.var!("out")?), "direct")?
	Path.write_utf8!("output", "declared")
}

replace_workspace! : () => Try({}, _)
replace_workspace! = || {
	Path.rename!(Env.cwd!()?, "../moved")?
	Cmd.new("ln").args(["-s", "moved", "../blueprint-work"]).exec_cmd!()?
	Path.write_utf8!("../moved/output", "moved")
}

mark! : Str => Try({}, _)
mark! = |file| {
	Path.write_utf8!(Path.utf8(file), "run")?
	Path.write_utf8!("output", "safe source")
}
