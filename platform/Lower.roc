import Config
import ir.Ir

## Turns a `Blueprint.roc` config into the IR, checking rules that span
## more than one setting.
Lower :: [].{

	Error : [
		DuplicateName(Str),
		DuplicateShell(Str),
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
	}

	lower : List(Config.Setting) -> Try(Ir, List(Error))
	lower = |settings| {
		acc = settings.fold({ names: [], systems: Err(NotGiven), overlays: [], shells: [] }, add)
		errors = check(acc)
		if errors.is_empty() {
			Ok(
				Ir.{
					version: Ir.current_version,
					name: acc.names.first() ?? "",
					systems: acc.systems ?? [X86_64Linux, Aarch64Linux, X86_64Darwin, Aarch64Darwin],
					overlays: unique(acc.overlays),
					shells: acc.shells,
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
		name_errors.concat(shell_errors).concat(no_shells).concat(no_systems)
	}

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
