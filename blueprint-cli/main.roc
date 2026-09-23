## `blueprint`: turns a `Blueprint.roc` into a working Nix environment.
##
## The Roc compiler validates `Blueprint.roc` and prints the blueprint IR;
## this CLI parses that IR and owns everything with effects: `.blueprint/`,
## `Blueprint.lock` and `nix`.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst",
	ir: "../blueprint-ir-package/main.roc",
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
import Backend
import NixBackend

version : Str
version = "0.2.0"

## The backend every command goes through.
backend : Backend
backend = NixBackend.backend

Command : [
	Gen,
	Shell(Str),
	Run({ task : Str, args : List(Str) }),
	Tasks,
	Update,
	Check,
	PrintIr,
	PrintFlake,
]

## The command-line parser. When Blueprint.roc loads, its shells and tasks
## become subcommands, so `--help` and usage errors list what this project
## actually defines. Otherwise the parser is generic and says why.
cli_for : Try(Ir, _) -> Cli.CliParser(Try(Command, [NoSubcommand]))
cli_for = |loaded| {
	generic_shell_cmd = SubCmd.finish(
		Cli.map(Param.maybe_str({ name: "name", help: "The shell to enter (default: \"default\")." }), |name| Shell(name ?? "default")),
		{ name: "shell", description: "Generate, then enter a dev shell", mapper: |c| c },
	)
	generic_run_cmd = SubCmd.finish(
		{
			task: Param.str({ name: "task", help: "The task to run.", default: NoDefault }),
			args: Param.str_list({ name: "args", help: "Extra arguments for the task; put them after --." }),
		}.Cli,
		{ name: "run", description: "Generate, then run a task in its shell", mapper: |r| Run(r) },
	)
	{ shell_cmd, run_cmd, about } =
		match loaded {
			Ok(ir) => {
				# Weaver rejects an empty subcommand list, so fall back to the
				# generic parsers when there are no shells or tasks.
				shell_cmd: if ir.shells.is_empty()
					generic_shell_cmd
				else
					SubCmd.finish(
						Cli.map(SubCmd.optional(ir.shells.map(shell_choice)), |picked| Shell(picked ?? "default")),
						{ name: "shell", description: "Generate, then enter a dev shell (default: \"default\")", mapper: |c| c },
					),
				run_cmd: if ir.tasks.is_empty()
					generic_run_cmd
				else
					SubCmd.finish(
						SubCmd.required(ir.tasks.map(task_choice)),
						{ name: "run", description: "Generate, then run a task in its shell", mapper: |r| Run(r) },
					),
				about: summary(ir),
			}

			Err(err) => {
				shell_cmd: generic_shell_cmd,
				run_cmd: generic_run_cmd,
				about: match err {
					NoBlueprint => "There is no Blueprint.roc in this directory."
					_ => "Blueprint.roc could not be loaded, so its shells and tasks aren't listed; run `blueprint check` for details."
				},
			}
		}

	Cli.assert_valid(
		Cli.finish(
			SubCmd.optional([
				SubCmd.empty({ name: "gen", description: "Generate .blueprint/ and sync Blueprint.lock (the default)", value: Gen }),
				shell_cmd,
				run_cmd,
				SubCmd.empty({ name: "tasks", description: "List the tasks", value: Tasks }),
				SubCmd.empty({ name: "update", description: "Update Blueprint.lock to the latest inputs", value: Update }),
				SubCmd.empty({ name: "check", description: "Validate Blueprint.roc", value: Check }),
				SubCmd.empty({ name: "ir", description: "Print the blueprint IR", value: PrintIr }),
				SubCmd.empty({ name: "flake", description: "Print the generated files", value: PrintFlake }),
			]),
			{
				name: "blueprint",
				version,
				authors: [],
				description: "Turn a Blueprint.roc into a Nix dev shell. Set ROC to choose the roc compiler (default: roc).\n\n${about}",
				text_style: Color,
			},
		),
	)
}

summary : Ir -> Str
summary = |ir| {
	count = |n, one, many| if n == 1 "1 ${one}" else "${n.to_str()} ${many}"
	shells = ir.shells.map(|s| s.name)
	tasks = ir.tasks.map(|t| t.name)
	task_part = if tasks.is_empty() "no tasks" else "${count(tasks.len(), "task", "tasks")} (${Str.join_with(tasks, ", ")})"
	"${ir.name}: ${count(shells.len(), "shell", "shells")} (${Str.join_with(shells, ", ")}), ${task_part}."
}

shell_choice : Ir.Shell -> SubCmd.SubcommandParserConfig(Str)
shell_choice = |shell| {
	tools = shell.packages_.map(|p| Str.join_with(p.path, "."))
	SubCmd.empty({ name: shell.name, description: Str.join_with(tools, ", "), value: shell.name })
}

task_choice : Ir.Task -> SubCmd.SubcommandParserConfig({ task : Str, args : List(Str) })
task_choice = |task|
	SubCmd.finish(
		Param.str_list({ name: "args", help: "Extra arguments appended to the command; put them after --." }),
		{
			name: task.name,
			description: "${Str.join_with(task.run, " ")}  [${task.shell}]",
			mapper: |args| { task: task.name, args },
		},
	)

main! : List(OsStr) => Try({}, [Exit(I32), ..])
main! = |raw_args| {
	loaded = load_ir!()
	match Cli.parse_or_display_message(cli_for(loaded), raw_args.drop_first(1), OsStr.to_raw) {
		Err(Help(message)) | Err(Version(message)) => Stdout.line!(message).map_err(|_| Exit(1))
		Err(InvalidUsage(message)) => {
			_ = Stderr.line!(message)
			Err(Exit(2))
		}
		Ok(command) =>
			match run!(command ?? Gen, loaded) {
				Ok({}) => Ok({})
				Err(err) => {
					_ = Stderr.line!("blueprint: ${describe(err)}")
					Err(Exit(1))
				}
			}
		}
}

run! = |command, loaded|
	match command {
		Check => check!()
		_ => {
			ir = loaded?
			match command {
				Gen => gen!(ir)
				Shell(name) => shell!(ir, name)
				Run({ task, args }) => run_task!(ir, task, args)
				Tasks => list_tasks!(ir)
				Update => update!(ir)
				PrintIr => Stdout.write!(ir.to_str())
				PrintFlake => print_files!(ir)
				Check => check!()
			}
		}
	}

## Type-check Blueprint.roc, then run it so whole-config rules are checked too.
## TODO(compile-time-render): `roc check` alone is enough once the platform
## renders the IR at compile time again (see blueprint-ir-platform/main.roc).
check! : () => Try({}, _)
check! = || {
	Cmd.new_str(roc!()).args_str(["check", "Blueprint.roc"]).exec_cmd!()?
	_ = load_ir!()?
	Stdout.line!("Blueprint.roc is valid")
}

## Compile and run Blueprint.roc, then parse the IR it prints.
load_ir! : () => Try(Ir, _)
load_ir! = || {
	if !(path("Blueprint.roc").exists!() ?? False) {
		return Err(NoBlueprint)
	}
	output = Cmd.new_str(roc!()).args_str(["Blueprint.roc"]).exec_output!()?
	ir = Ir.parse(output.stdout_utf8).map_err(|err| BadIr(err))?
	missing = ir.unsupported_features(backend.features)
	if !missing.is_empty() {
		return Err(NeedsFeatures(missing))
	}
	Ok(ir)
}

render : Ir -> Try(List(Backend.File), _)
render = |ir| (backend.render)(ir).map_err(|msg| RenderFailed(msg))

## Run an argv from the backend.
exec! : List(Str) => Try({}, _)
exec! = |argv|
	match argv {
		[program, .. as args] =>
			Cmd.new_str(program)
				.args_str(args)
				.exec_cmd!()
				.map_err(
					|err|
						match err {
							ExecCmdFailed({ exit_code, .. }) => CommandFailed(argv, exit_code)
							other => other
						},
				)

		[] => Ok({})
	}

print_files! : Ir => Try({}, _)
print_files! = |ir| {
	files = render(ir)?
	match files {
		[only] => Stdout.write!(only.contents)
		_ => {
			for file in files {
				Stdout.write!("# ${file.path}\n${file.contents}")?
			}
			Ok({})
		}
	}
}

roc! : () => Str
roc! = || Env.var_str!("ROC") ?? "roc"

dir : Str
dir = ".blueprint"

## Write the backend's files and lock them, keeping Blueprint.lock in sync.
gen! : Ir => Try({}, _)
gen! = |ir| {
	files = render(ir)?
	path(dir).create_all!()?
	for file in files {
		path("${dir}/${file.path}").write_utf8!(file.contents)?
	}
	lock = path("Blueprint.lock")
	backend_lock = path("${dir}/${backend.lock_file}")
	if lock.exists!()? {
		lock.copy!(backend_lock)?
	}
	exec!((backend.lock)(dir))?
	backend_lock.copy!(lock)
}

shell! : Ir, Str => Try({}, _)
shell! = |ir, name| {
	if !ir.shells.any(|s| s.name == name) {
		return Err(UnknownShell(name, ir.shells.map(|s| s.name)))
	}
	gen!(ir)?
	exec!((backend.enter_shell)(dir, name))
}

run_task! : Ir, Str, List(Str) => Try({}, _)
run_task! = |ir, name, extra|
	match ir.tasks.keep_if(|t| t.name == name) {
		[task, ..] => {
			gen!(ir)?
			argv = (backend.run_in_shell)(dir, task.shell, task.run.concat(extra))
			Cmd.new_str(argv.first() ?? "")
				.args_str(argv.drop_first(1))
				.exec_cmd!()
				.map_err(
					|err|
						match err {
							ExecCmdFailed({ exit_code, .. }) => TaskFailed(name, exit_code)
							other => other
						},
				)
		}

		[] => Err(UnknownTask(name, ir.tasks.map(|t| t.name)))
	}

list_tasks! : Ir => Try({}, _)
list_tasks! = |ir| {
	lines = ir.tasks.map(|t| "${t.name}\t(${t.shell})\t${Str.join_with(t.run, " ")}")
	Stdout.line!(Str.join_with(lines, "\n"))
}

update! : Ir => Try({}, _)
update! = |ir| {
	gen!(ir)?
	exec!((backend.update)(dir))?
	path("${dir}/${backend.lock_file}").copy!(path("Blueprint.lock"))
}

path : Str -> Path
path = |p| Path.from_os_str(OsStr.from_str(p))

describe : _ -> Str
describe = |err|
	match err {
		NoBlueprint => "there is no Blueprint.roc in this directory"
		BadIr(InvalidSexpr(msg)) => "could not read the IR from Blueprint.roc: ${msg}"
		BadIr(UnsupportedFormat({ major, minor })) => "IR format ${U64.to_str(major)}.${U64.to_str(minor)} is not supported by this blueprint (understands major ${Ir.current_format.major.to_str()}); upgrade blueprint or change the platform version"
		NeedsFeatures(missing) => "Blueprint.roc needs features: ${Str.join_with(missing, ", ")}; upgrade blueprint"
		RenderFailed(msg) => "cannot generate the ${backend.name} files: ${msg}"
		BadIr(MissingRequiredField("format")) => "Blueprint.roc uses an older roc-blueprint platform that this blueprint can't read; update the platform URL in its app header to a current release"
		BadIr(MissingRequiredField(field)) => "the IR from Blueprint.roc is missing ${field}"
		NonZeroExitCode({ stderr_utf8_lossy, .. }) => "roc Blueprint.roc failed:\n${stderr_utf8_lossy}"
		TaskFailed(name, code) => "task ${name} exited with code ${code.to_str()}"
		UnknownTask(name, known) => "no task named \"${name}\"; Blueprint.roc defines: ${Str.join_with(known, ", ")}"
		UnknownShell(name, known) => "no shell named \"${name}\"; Blueprint.roc defines: ${Str.join_with(known, ", ")}"
		ExecFailed({ command, exit_code }) => "`${command}` exited with code ${I32.to_str(exit_code)}"
		CommandFailed(argv, code) => "`${Str.join_with(argv, " ")}` exited with code ${code.to_str()}"
		ExecCmdFailed({ command, exit_code }) => "`${command}` exited with code ${exit_code.to_str()}"
		other => Str.inspect(other)
	}
