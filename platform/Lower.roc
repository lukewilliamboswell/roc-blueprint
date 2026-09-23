import Config
import ir.Ir

## Turns a `Blueprint.roc` config into the IR, checking rules that span
## more than one setting.
Lower :: [].{

	Error : [
		DuplicateName(Str),
		DuplicateShell(Str),
		DuplicateTask(Str),
		TaskWithoutRun(Str),
		TaskWithSeveral(Str, [Run, In]),
		TaskInUnknownShell(Str, Str),
		EmptyShell(Str),
		MissingName,
		NoShells,
		NoSystems,
	]

	Acc : {
		names : List(Str),
		systems : Try(List(Ir.System), [NotGiven]),
		overlays : List(Str),
		shells : List(Ir.Shell),
		tasks : List(Draft),
	}

	## A task before validation: every Run and In it was given.
	Draft : { name : Str, runs : List(List(Str)), shells : List(Str) }

	lower : List(Config.Setting) -> Try(Ir, List(Error))
	lower = |settings| {
		acc = settings.fold({ names: [], systems: Err(NotGiven), overlays: [], shells: [], tasks: [] }, add)
		errors = check(acc)
		if errors.is_empty() {
			Ok(
				Ir.{
					version: Ir.current_version,
					name: acc.names.first() ?? "",
					systems: acc.systems ?? [X86_64Linux, Aarch64Linux, X86_64Darwin, Aarch64Darwin],
					overlays: unique(acc.overlays),
					shells: acc.shells,
					tasks: acc.tasks.map(finish_task),
				},
			)
		} else {
			Err(errors)
		}
	}

	add : Acc, Config.Setting -> Acc
	add = |acc, setting|
		match setting {
			Name(name) => { ..acc, names: acc.names.append(name) }
			Systems(systems) => { ..acc, systems: Ok(unique((acc.systems ?? []).concat(systems))) }
			Overlay(ref) => { ..acc, overlays: acc.overlays.append(ref.to_str()) }
			Shell(env, inner) => { ..acc, shells: acc.shells.append(shell(env.to_str(), inner)) }
			Task(name, inner) => { ..acc, tasks: acc.tasks.append(draft(name.to_str(), inner)) }
		}

	check : Acc -> List(Error)
	check = |acc| {
		name_errors =
			if acc.names.is_empty() {
				[MissingName]
			} else {
				acc.names.drop_first(1).map(|n| DuplicateName(n))
			}
		shell_errors = acc.shells.fold(
			{ seen: [], errors: [] },
			|state, s| {
				errors =
					if state.seen.contains(s.name) {
						state.errors.append(DuplicateShell(s.name))
					} else if s.tools.is_empty() {
						state.errors.append(EmptyShell(s.name))
					} else {
						state.errors
					}
				{ seen: state.seen.append(s.name), errors }
			},
		).errors
		no_shells = if acc.shells.is_empty() [NoShells] else []
		no_systems =
			match acc.systems {
				Ok([]) => [NoSystems]
				_ => []
			}
		shell_names = acc.shells.map(|s| s.name)
		task_errors = acc.tasks.fold(
			{ seen: [], errors: [] },
			|state, t| {
				errors =
					if state.seen.contains(t.name) {
						state.errors.append(DuplicateTask(t.name))
					} else {
						state.errors.concat(check_task(t, shell_names))
					}
				{ seen: state.seen.append(t.name), errors }
			},
		).errors
		name_errors.concat(shell_errors).concat(no_shells).concat(no_systems).concat(task_errors)
	}

	check_task : Draft, List(Str) -> List(Error)
	check_task = |t, shell_names| {
		run_errors =
			match t.runs.len() {
				0 => [TaskWithoutRun(t.name)]
				1 => []
				_ => [TaskWithSeveral(t.name, Run)]
			}
		in_errors =
			match t.shells {
				[] => if shell_names.contains("default") [] else [TaskInUnknownShell(t.name, "default")]
				[one] => if shell_names.contains(one) [] else [TaskInUnknownShell(t.name, one)]
				_ => [TaskWithSeveral(t.name, In)]
			}
		run_errors.concat(in_errors)
	}

	draft : Str, List(Config.TaskSetting) -> Draft
	draft = |name, inner|
		inner.fold(
			{ name, runs: [], shells: [] },
			|d, setting|
				match setting {
					Run(command) => { ..d, runs: d.runs.append(command) }
					In(env) => { ..d, shells: d.shells.append(env.to_str()) }
				},
		)

	finish_task : Draft -> Ir.Task
	finish_task = |d| { name: d.name, shell: d.shells.first() ?? "default", run: d.runs.first() ?? [] }

	shell : Str, List(Config.ShellSetting) -> Ir.Shell
	shell = |name, inner| {
		tools = inner.fold(
			[],
			|acc, setting|
				match setting {
					Tools(list) => acc.concat(list.map(|tool| tool.to_path()))
				},
		)
		{ name, tools: unique(tools) }
	}

	unique : List(a) -> List(a) where [a.is_eq : a, a -> Bool]
	unique = |items| items.fold([], |acc, item| if acc.contains(item) acc else acc.append(item))
}
