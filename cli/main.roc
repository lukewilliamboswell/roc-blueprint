## `blueprint`: turns a `Blueprint.roc` into a working Nix environment.
##
## The Roc compiler validates `Blueprint.roc` and prints the blueprint IR;
## this CLI parses that IR and owns everything with effects: `.blueprint/`,
## `Blueprint.lock` and `nix`.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	ir: "../ir/main.roc",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import pf.Stderr
import ir.Ir
import Flake

version : Str
version = "0.1.0"

usage : Str
usage =
	\\Usage: blueprint [COMMAND]
	\\
	\\Commands:
	\\  gen            Write .blueprint/flake.nix and sync Blueprint.lock (default)
	\\  shell [NAME]   Generate, then enter a dev shell (default: "default")
	\\  run TASK [ARGS...]
	\\                 Generate, then run a task in its shell, with extra ARGS
	\\  tasks          List the tasks
	\\  update         Update Blueprint.lock to the latest inputs
	\\  check          Validate Blueprint.roc
	\\  ir             Print the blueprint IR
	\\  flake          Print the generated flake.nix
	\\  version        Print the blueprint version
	\\  help           Print this message
	\\
	\\Environment:
	\\  ROC            Path to the roc compiler (default: roc)

main! : List(OsStr) => Try({}, [Exit(I32), ..])
main! = |raw_args| {
	args = raw_args.drop_first(1).map(OsStr.display)
	match run!(args) {
		Ok({}) => Ok({})
		Err(err) => {
			_ = Stderr.line!("blueprint: ${describe(err)}")
			Err(Exit(1))
		}
	}
}

run! = |args|
	match args {
		[] | ["gen"] => gen!().map_ok(|_| {})
		["shell"] => shell!("default")
		["shell", name] => shell!(name)
		["run", task, .. as extra] => run_task!(task, extra)
		["tasks"] => list_tasks!()
		["update"] => update!()
		["check"] => check!()
		["ir"] => Stdout.write!(load_ir!()?.to_str())
		["flake"] => Stdout.write!(Flake.render(load_ir!()?))
		["version"] => Stdout.line!(version)
		["help"] | ["--help"] | ["-h"] => Stdout.line!(usage)
		_ => Err(Usage(Str.join_with(args, " ")))
	}

## Type-check Blueprint.roc, then run it so whole-config rules are checked too.
## TODO(compile-time-render): `roc check` alone is enough once the platform
## renders the IR at compile time again (see platform/main.roc).
check! : () => Try({}, _)
check! = || {
	Cmd.new_str(roc!()).args_str(["check", "Blueprint.roc"]).exec_cmd!()?
	_ = load_ir!()?
	Stdout.line!("Blueprint.roc is valid")
}

## Compile and run Blueprint.roc, then parse the IR it prints.
load_ir! : () => Try(Ir, _)
load_ir! = || {
	output = Cmd.new_str(roc!()).args_str(["Blueprint.roc"]).exec_output!()?
	Ir.parse(output.stdout_utf8).map_err(|err| BadIr(err))
}

roc! : () => Str
roc! = || Env.var_str!("ROC") ?? "roc"

dir : Str
dir = ".blueprint"

## Write the flake and lock it, keeping Blueprint.lock in sync.
gen! : () => Try(Ir, _)
gen! = || {
	ir = load_ir!()?
	path(dir).create_all!()?
	path("${dir}/flake.nix").write_utf8!(Flake.render(ir))?
	lock = path("Blueprint.lock")
	if lock.exists!()? {
		lock.copy!(path("${dir}/flake.lock"))?
	}
	Cmd.exec!("nix", ["flake", "lock", "path:${dir}"])?
	path("${dir}/flake.lock").copy!(lock)?
	Ok(ir)
}

shell! : Str => Try({}, _)
shell! = |name| {
	ir = gen!()?
	if !ir.shells.any(|s| s.name == name) {
		return Err(UnknownShell(name, ir.shells.map(|s| s.name)))
	}
	Cmd.exec!("nix", ["develop", "path:${dir}#${name}"])
}

run_task! : Str, List(Str) => Try({}, _)
run_task! = |name, extra| {
	ir = gen!()?
	match ir.tasks.keep_if(|t| t.name == name) {
		[task, ..] =>
			Cmd.new_str("nix")
				.args_str(["develop", "path:${dir}#${task.shell}", "-c"].concat(task.run).concat(extra))
				.exec_cmd!()
				.map_err(
					|err|
						match err {
							ExecCmdFailed({ exit_code, .. }) => TaskFailed(name, exit_code)
							other => other
						},
				)
		[] => Err(UnknownTask(name, ir.tasks.map(|t| t.name)))
	}
}

list_tasks! : () => Try({}, _)
list_tasks! = || {
	ir = load_ir!()?
	lines = ir.tasks.map(|t| "${t.name}\t(${t.shell})\t${Str.join_with(t.run, " ")}")
	Stdout.line!(Str.join_with(lines, "\n"))
}

update! : () => Try({}, _)
update! = || {
	_ = gen!()?
	Cmd.exec!("nix", ["flake", "update", "--flake", "path:${dir}"])?
	path("${dir}/flake.lock").copy!(path("Blueprint.lock"))
}

path : Str -> Path
path = |p| Path.from_os_str(OsStr.from_str(p))

describe : _ -> Str
describe = |err|
	match err {
		Usage(given) => "unknown command \"${given}\"\n\n${usage}"
		BadIr(InvalidSexpr(msg)) => "could not read the IR from Blueprint.roc: ${msg}"
		BadIr(UnsupportedVersion(v)) => "Blueprint.roc uses IR version ${v.to_str()}, but this blueprint understands version ${Ir.current_version.to_str()}; update blueprint or the platform"
		BadIr(MissingRequiredField(field)) => "the IR from Blueprint.roc is missing ${field}"
		NonZeroExitCode({ stderr_utf8_lossy, .. }) => "roc Blueprint.roc failed:\n${stderr_utf8_lossy}"
		TaskFailed(name, code) => "task ${name} exited with code ${code.to_str()}"
		UnknownTask(name, known) => "no task named \"${name}\"; Blueprint.roc defines: ${Str.join_with(known, ", ")}"
		UnknownShell(name, known) => "no shell named \"${name}\"; Blueprint.roc defines: ${Str.join_with(known, ", ")}"
		ExecFailed({ command, exit_code }) => "`${command}` exited with code ${exit_code.to_str()}"
		ExecCmdFailed({ command, exit_code }) => "`${command}` exited with code ${exit_code.to_str()}"
		other => Str.inspect(other)
	}
