# Authoring cardinality checks feed the shared whole-project validator.
import Config
import Val
import core.Spec
import core.Project
import core.Value

## Lower authoring settings, then share semantic validation with Spec consumers.
## Setting cardinality belongs here because the Spec stores only one value.
Lower :: [].{
	Acc : {
		names : List(Str),
		systems : List(List(Str)),
		sources : List(Spec.Source),
		inputs : List(Spec.Input),
		environments : List(Spec.Environment),
		system_tools : List(Spec.SystemTools),
		shells : List(Spec.Shell),
		tasks : List(Spec.Task),
		build_sources : List(Spec.BuildSource),
		builds : List(Spec.Build),
		workflows : List(Spec.Workflow),
		extensions : List(Spec.Extension),
		raw : List(Spec.Raw),
	}

	## Explicit target defaults; never inferred from the compiling host.
	default_systems : List(Str)
	default_systems = ["x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin"]

	lower : List(Config.Setting) -> Try(Spec, Str)
	lower = |settings| {
		initial : Acc
		initial = { names: [], systems: [], sources: [], inputs: [], environments: [], system_tools: [], shells: [], tasks: [], build_sources: [], builds: [], workflows: [], extensions: [], raw: [] }
		acc = settings.fold(Ok(initial), |result, setting| add(result?, setting))?
		name = match acc.names {
			[] => return Err("MissingName: declare Name once")
			[one] => one
			_ => return Err("DuplicateName: declare Name once")
		}
		systems = match acc.systems {
			[] => default_systems
			[one] => one
			_ => return Err("DuplicateSystems: declare Systems at most once")
		}
		requires_ =
			(if acc.extensions.is_empty() [] else ["extensions"])
				.concat(if acc.raw.is_empty() [] else ["raw"])
				.concat(if acc.build_sources.is_empty() [] else ["sources"])
				.concat(if acc.builds.is_empty() [] else ["builds"])
				.concat(if acc.workflows.is_empty() [] else ["workflows"])
				.concat(if acc.system_tools.is_empty() [] else ["system-tools"])
		Project.validate(
			Spec.{
				format: Spec.current_format,
				name,
				requires_,
				systems,
				sources: acc.sources,
				inputs: acc.inputs,
				environments: acc.environments,
				system_tools: acc.system_tools,
				shells: acc.shells,
				tasks: acc.tasks,
				build_sources: acc.build_sources,
				builds: acc.builds,
				workflows: acc.workflows,
				extensions: acc.extensions,
				raw: acc.raw,
			},
		)
	}

	add : Acc, Config.Setting -> Try(Acc, Str)
	add = |acc, setting| {
		next = match setting {
			Name(name) => { ..acc, names: acc.names.append(name) }
			Systems(systems) => { ..acc, systems: acc.systems.append(systems.map(|s| s.to_str())) }
			Packages(name, source) => { ..acc, sources: acc.sources.append({ name: name.to_str(), provider: provider(source) }) }
			Input(name, ref) => { ..acc, inputs: acc.inputs.append({ name: name.to_str(), url: ref.to_str(), kind: Flake }) }
			Overlay(name, ref) => { ..acc, inputs: acc.inputs.append({ name: name.to_str(), url: ref.to_str(), kind: Overlay }) }
			Environment(name, inner) => {
				lowered = environment(name.to_str(), inner)?
				{ ..acc, environments: acc.environments.append(lowered.environment), system_tools: acc.system_tools.concat(lowered.system_tools) }
			}
			Shell(name, inner) => { ..acc, shells: acc.shells.append(shell(name.to_str(), inner)?) }
			Task(name, inner) => { ..acc, tasks: acc.tasks.append(task(name.to_str(), inner)?) }
			Source(name, ref) => { ..acc, build_sources: acc.build_sources.append({ name: name.to_str(), ref: ref.to_str() }) }
			Build(name, inner) => { ..acc, builds: acc.builds.append(build(name.to_str(), inner)?) }
			Workflow(name, steps) => {
				..acc,
				workflows: acc.workflows.append({
					name: name.to_str(),
					steps: steps.map(workflow_step),
				}),
			}
			Custom(kind, name, value) => { ..acc, extensions: acc.extensions.append({ kind, name, value: to_value(value) }) }
			Raw(backend, target, value) => { ..acc, raw: acc.raw.append({ backend, target, value: to_value(value) }) }
		}
		Ok(next)
	}

	workflow_step : Config.WorkflowStep -> Spec.WorkflowStep
	workflow_step = |step|
		match step {
			RunTask(name, argv) => RunTask(name.to_str(), argv)
			BuildArtifact(name) => BuildArtifact(name.to_str())
			RunWorkflow(name) => RunWorkflow(name.to_str())
		}

	provider : Config.PackageSource -> Spec.Provider
	provider = |source|
		match source {
			Auto => Auto
			From(NixPackages(ref)) => NixPackages(ref.to_str())
			From(GuixPackages(channel)) => GuixPackages(channel)
		}

	environment : Str, List(Config.EnvironmentSetting) -> Try({ environment : Spec.Environment, system_tools : List(Spec.SystemTools) }, Str)
	environment = |name, inner| {
		draft = inner.fold(
			{ tools: [], system_tools: [], overlays: [], parents: [] },
			|acc, setting|
				match setting {
					Tools(tools) => { ..acc, tools: acc.tools.append(tools.map(|tool| tool.to_spec())) }
					ToolsFor(system, tools) => { ..acc, system_tools: acc.system_tools.append({ environment: name, system: system.to_str(), tools: tools.map(|tool| tool.to_spec()) }) }
					Overlays(overlays) => { ..acc, overlays: acc.overlays.append(overlays.map(|overlay| overlay.to_str())) }
					Extend(parent) => { ..acc, parents: acc.parents.append(parent.to_str()) }
				},
		)
		if draft.tools.len() > 1 {
			return Err("DuplicateTools: environment ${name}")
		}
		if draft.overlays.len() > 1 {
			return Err("DuplicateOverlays: environment ${name}")
		}
		if draft.parents.len() > 1 {
			return Err("DuplicateExtend: environment ${name}")
		}
		Ok({ environment: { name, parents: draft.parents, tools: draft.tools.first() ?? [], overlays: draft.overlays.first() ?? [] }, system_tools: draft.system_tools })
	}

	shell : Str, List(Config.ShellSetting) -> Try(Spec.Shell, Str)
	shell = |name, inner| {
		environments = inner.map(
			|setting| match setting {
				Use(env) => env.to_str()
			},
		)
		match environments {
			[environment_name] => Ok({ name, environment: environment_name })
			[] => Err("MissingUse: shell ${name}")
			_ => Err("DuplicateUse: shell ${name}")
		}
	}

	task : Str, List(Config.TaskSetting) -> Try(Spec.Task, Str)
	task = |name, inner| {
		draft = inner.fold(
			{ environments: [], runs: [] },
			|acc, setting|
				match setting {
					Use(env) => { ..acc, environments: acc.environments.append(env.to_str()) }
					Run(argv) => { ..acc, runs: acc.runs.append(argv) }
				},
		)
		environment_name = match draft.environments {
			[one] => one
			[] => return Err("MissingUse: task ${name}")
			_ => return Err("DuplicateUse: task ${name}")
		}
		run = match draft.runs {
			[one] => one
			[] => return Err("MissingRun: task ${name}")
			_ => return Err("DuplicateRun: task ${name}")
		}
		Ok({ name, environment: environment_name, run })
	}

	build : Str, List(Config.BuildSetting) -> Try(Spec.Build, Str)
	build = |name, inner| {
		draft = inner.fold(
			{ environments: [], inputs: [], needs: [], runs: [], outputs: [] },
			|acc, setting|
				match setting {
					Use(env) => { ..acc, environments: acc.environments.append(env.to_str()) }
					Inputs(inputs) => { ..acc, inputs: acc.inputs.append(inputs.map(|input| input.to_str())) }
					Needs(needs) => { ..acc, needs: acc.needs.append(needs.map(|need| need.to_str())) }
					Run(argv) => { ..acc, runs: acc.runs.append(argv) }
					Output(path) => { ..acc, outputs: acc.outputs.append(path) }
				},
		)
		environment_name = match draft.environments {
			[one] => one
			[] => return Err("MissingUse: build ${name}")
			_ => return Err("DuplicateUse: build ${name}")
		}
		run = match draft.runs {
			[one] => one
			[] => return Err("MissingRun: build ${name}")
			_ => return Err("DuplicateRun: build ${name}")
		}
		output = match draft.outputs {
			[one] => one
			[] => return Err("MissingOutput: build ${name}")
			_ => return Err("DuplicateOutput: build ${name}")
		}
		if draft.inputs.len() > 1 {
			return Err("DuplicateInputs: build ${name}")
		}
		if draft.needs.len() > 1 {
			return Err("DuplicateNeeds: build ${name}")
		}
		Ok({ name, environment: environment_name, inputs: draft.inputs.first() ?? [], needs: draft.needs.first() ?? [], run, output })
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
}
