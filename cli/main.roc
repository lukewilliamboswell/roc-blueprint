## `blueprint`: turns a `Blueprint.roc` into a working Nix environment.
##
## The Roc compiler validates `Blueprint.roc` and prints the blueprint IR;
## this CLI parses that IR and owns everything with effects: `.blueprint/`,
## `Blueprint.lock` and `nix`.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	ir: "../ir/main.roc",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import pf.Stderr
import weaver.Cli
import weaver.Param
import weaver.SubCmd
import ir.Ir
import Flake

version : Str
version = "0.1.0"

Command : [
	Gen,
	Shell(Try(Str, [NoValue])),
	Run({ task : Str, args : List(Str) }),
	Tasks,
	Update,
	Check,
	PrintIr,
	PrintFlake,
]

cli : Cli.CliParser(Try(Command, [NoSubcommand]))
cli =
	Cli.assert_valid(
		Cli.finish(
			SubCmd.optional([
				SubCmd.empty({ name: "gen", description: "Write .blueprint/flake.nix and sync Blueprint.lock (the default)", value: Gen }),
				SubCmd.finish(
					Cli.map(Param.maybe_str({ name: "name", help: "The shell to enter (default: \"default\")." }), |name| Shell(name)),
					{ name: "shell", description: "Generate, then enter a dev shell", mapper: |c| c },
				),
				SubCmd.finish(
					{
						task: Param.str({ name: "task", help: "The task to run.", default: NoDefault }),
						args: Param.str_list({ name: "args", help: "Extra arguments for the task; put them after --." }),
					}.Cli,
					{ name: "run", description: "Generate, then run a task in its shell", mapper: |r| Run(r) },
				),
				SubCmd.empty({ name: "tasks", description: "List the tasks", value: Tasks }),
				SubCmd.empty({ name: "update", description: "Update Blueprint.lock to the latest inputs", value: Update }),
				SubCmd.empty({ name: "check", description: "Validate Blueprint.roc", value: Check }),
				SubCmd.empty({ name: "ir", description: "Print the blueprint IR", value: PrintIr }),
				SubCmd.empty({ name: "flake", description: "Print the generated flake.nix", value: PrintFlake }),
			]),
			{
				name: "blueprint",
				version,
				authors: [],
				description: "Turn a Blueprint.roc into a Nix dev shell. Set ROC to choose the roc compiler (default: roc).",
				text_style: Color,
			},
		),
	)

main! : List(OsStr) => Try({}, [Exit(I32), ..])
main! = |raw_args|
	match Cli.parse_or_display_message(cli, raw_args.drop_first(1), OsStr.to_raw) {
		Err(Help(message)) | Err(Version(message)) => Stdout.line!(message).map_err(|_| Exit(1))
		Err(InvalidUsage(message)) => {
			_ = Stderr.line!(message)
			Err(Exit(2))
		}
		Ok(command) =>
			match run!(command ?? Gen) {
				Ok({}) => Ok({})
				Err(err) => {
					_ = Stderr.line!("blueprint: ${describe(err)}")
					Err(Exit(1))
				}
			}
		}

run! = |command|
	match command {
		Gen => gen!().map_ok(|_| {})
		Shell(name) => shell!(name ?? "default")
		Run({ task, args }) => run_task!(task, args)
		Tasks => list_tasks!()
		Update => update!()
		Check => check!()
		PrintIr => Stdout.write!(load_ir!()?.to_str())
		PrintFlake => Stdout.write!(Flake.render(load_ir!()?))
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
