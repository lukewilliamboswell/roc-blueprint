import Config
import Val
import ir.Ir
import ir.Value

## Turns a `Blueprint.roc` config into the IR, checking rules that span
## more than one setting.
Lower :: [].{

	Error : [
		DuplicateName(Str),
		DuplicateShell(Str),
		DuplicateTask(Str),
		DuplicateInput(Str),
		DuplicateExtension(Str, Str),
		TaskWithoutRun(Str),
		TaskWithSeveral(Str, [Run, In]),
		TaskInUnknownShell(Str, Str),
		UnknownPackageSet(Str, Str),
		EmptyShell(Str),
		EmptyField(Str),
		MissingName,
		NoShells,
		NoSystems,
	]

	Acc : {
		names : List(Str),
		systems : Try(List(Str), [NotGiven]),
		inputs : List(Ir.Input),
		overlays : List(Str),
		shells : List({ name : Str, tools : List({ label : Str, pkg : Ir.Package }) }),
		tasks : List(Draft),
		extensions : List(Ir.Extension),
		raw : List(Ir.Raw),
	}

	## A task before validation: every Run and In it was given.
	Draft : { name : Str, runs : List(List(Str)), shells : List(Str) }

	## The package set used when a config declares no "nixpkgs" input.
	default_nixpkgs : Ir.Input
	default_nixpkgs = { name: "nixpkgs", url: "github:NixOS/nixpkgs/nixos-unstable", kind: Packages }

	## Systems used when a config has no `Systems` setting.
	default_systems : List(Str)
	default_systems = ["x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin"]

	lower : List(Config.Setting) -> Try(Ir, List(Error))
	lower = |settings| {
		acc = settings.fold(
			{ names: [], systems: Err(NotGiven), inputs: [], overlays: [], shells: [], tasks: [], extensions: [], raw: [] },
			add,
		)
		inputs = all_inputs(acc)
		errors = check(acc, inputs)
		if errors.is_empty() {
			requires_ =
				(if acc.extensions.is_empty() [] else ["extensions"])
					.concat(if acc.raw.is_empty() [] else ["raw"])
			Ok(
				Ir.{
					format: Ir.current_format,
					name: acc.names.first() ?? "",
					requires_,
					systems: acc.systems ?? default_systems,
					inputs,
					shells: acc.shells.map(|s| { name: s.name, packages_: s.tools.map(|t| t.pkg) }),
					tasks: acc.tasks.map(finish_task),
					extensions: acc.extensions,
					raw: acc.raw,
				},
			)
		} else {
			Err(errors)
		}
	}

	## Declared inputs, then a default "nixpkgs" if none was declared, then
	## overlays, named "overlay0", "overlay1", ...
	all_inputs : Acc -> List(Ir.Input)
	all_inputs = |acc| {
		declared = if acc.inputs.any(|i| i.name == "nixpkgs") acc.inputs else [default_nixpkgs].concat(acc.inputs)
		overlays = unique(acc.overlays).fold(
			[],
			|list, url| list.append({ name: "overlay${list.len().to_str()}", url, kind: Overlay }),
		)
		declared.concat(overlays)
	}

	add : Acc, Config.Setting -> Acc
	add = |acc, setting|
		match setting {
			Name(name) => { ..acc, names: acc.names.append(name) }
			Systems(systems) => { ..acc, systems: Ok(unique((acc.systems ?? []).concat(systems.map(|s| s.to_str())))) }
			Packages(name, ref) => { ..acc, inputs: acc.inputs.append({ name: name.to_str(), url: ref.to_str(), kind: Packages }) }
			Input(name, ref) => { ..acc, inputs: acc.inputs.append({ name: name.to_str(), url: ref.to_str(), kind: Flake }) }
			Overlay(ref) => { ..acc, overlays: acc.overlays.append(ref.to_str()) }
			Shell(env, inner) => { ..acc, shells: acc.shells.append(shell(env.to_str(), inner)) }
			Task(name, inner) => { ..acc, tasks: acc.tasks.append(draft(name.to_str(), inner)) }
			Custom(kind, name, value) => { ..acc, extensions: acc.extensions.append({ kind, name, value: to_value(value) }) }
			Raw(backend, target, value) => { ..acc, raw: acc.raw.append({ backend, target, value: to_value(value) }) }
		}

	to_value : Val -> Value
	to_value = |val|
		match val {
			Str(s) => Value.Str(s)
			Int(n) => Value.Int(n)
			Bool(b) => Value.Bool(b)
			List(items) => Value.List(items.map(to_value))
			Attrs(pairs) => Value.Attrs(pairs.map(|(name, v)| { name, value: to_value(v) }))
		}

	check : Acc, List(Ir.Input) -> List(Error)
	check = |acc, inputs| {
		name_errors =
			if acc.names.is_empty() {
				[MissingName]
			} else {
				acc.names.drop_first(1).map(|n| DuplicateName(n))
			}
		input_errors = duplicates(inputs.map(|i| i.name)).map(|n| DuplicateInput(n))
		package_sets = inputs.keep_if(|i| i.kind == Packages).map(|i| i.name)
		shell_errors = acc.shells.fold(
			{ seen: [], errors: [] },
			|state, s| {
				errors =
					if state.seen.contains(s.name) {
						state.errors.append(DuplicateShell(s.name))
					} else if s.tools.is_empty() {
						state.errors.append(EmptyShell(s.name))
					} else {
						state.errors.concat(
							s.tools
								.drop_if(|t| package_sets.contains(t.pkg.source))
								.map(|t| UnknownPackageSet(t.label, t.pkg.source)),
						)
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
		extension_errors =
			acc.extensions
				.fold(
					{ seen: [], errors: [] },
					|state, e| {
						key = (e.kind, e.name)
						errors =
							if e.kind.is_empty() {
								state.errors.append(EmptyField("Custom kind"))
							} else if state.seen.contains(key) {
								state.errors.append(DuplicateExtension(e.kind, e.name))
							} else {
								state.errors
							}
						{ seen: state.seen.append(key), errors }
					},
				)
				.errors
		raw_errors = acc.raw.fold(
			[],
			|errors, r|
				if r.backend.is_empty() {
					errors.append(EmptyField("Raw backend"))
				} else if r.target.is_empty() {
					errors.append(EmptyField("Raw target"))
				} else {
					errors
				},
		)
		name_errors
			.concat(input_errors)
			.concat(shell_errors)
			.concat(no_shells)
			.concat(no_systems)
			.concat(task_errors)
			.concat(extension_errors)
			.concat(raw_errors)
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

	shell : Str, List(Config.ShellSetting) -> { name : Str, tools : List({ label : Str, pkg : Ir.Package }) }
	shell = |name, inner| {
		tools = inner.fold(
			[],
			|acc, setting|
				match setting {
					Tools(list) => acc.concat(list.map(|tool| { label: tool.to_str(), pkg: { source: tool.source(), path: tool.to_path() } }))
				},
		)
		{ name, tools: unique(tools) }
	}

	duplicates : List(Str) -> List(Str)
	duplicates = |names|
		names.fold(
			{ seen: [], dups: [] },
			|state, n|
				if state.seen.contains(n) and !state.dups.contains(n) {
					{ ..state, dups: state.dups.append(n) }
				} else {
					{ ..state, seen: state.seen.append(n) }
				},
		).dups

	unique : List(a) -> List(a) where [a.is_eq : a, a -> Bool]
	unique = |items| items.fold([], |acc, item| if acc.contains(item) acc else acc.append(item))
}
