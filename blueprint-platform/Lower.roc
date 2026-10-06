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
		commands : List(Spec.Command),
		roc_packages : List(Spec.RocPackage),
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
		initial = { names: [], systems: [], sources: [], inputs: [], environments: [], system_tools: [], commands: [], roc_packages: [], shells: [], tasks: [], build_sources: [], builds: [], workflows: [], extensions: [], raw: [] }
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
				.concat(if acc.commands.is_empty() [] else ["commands"])
				.concat(if acc.roc_packages.is_empty() [] else ["roc-packages"])
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
				commands: acc.commands,
				roc_packages: acc.roc_packages,
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
				# Environments sharing a bundle share its one locked source.
				new_sources = lowered.roc_sources.keep_if(|source| !acc.build_sources.contains(source))
				{ ..acc, environments: acc.environments.append(lowered.environment), system_tools: acc.system_tools.concat(lowered.system_tools), commands: acc.commands.concat(lowered.commands), roc_packages: acc.roc_packages.concat(lowered.roc_packages), build_sources: acc.build_sources.concat(new_sources) }
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

	environment : Str, List(Config.EnvironmentSetting) -> Try({ environment : Spec.Environment, system_tools : List(Spec.SystemTools), commands : List(Spec.Command), roc_packages : List(Spec.RocPackage), roc_sources : List(Spec.BuildSource) }, Str)
	environment = |name, inner| {
		draft = inner.fold(
			{ tools: [], system_tools: [], commands: [], roc_urls: [], overlays: [], parents: [] },
			|acc, setting|
				match setting {
					Tools(tools) => { ..acc, tools: acc.tools.append(tools.map(|tool| tool.to_spec())) }
					ToolsFor(system, tools) => { ..acc, system_tools: acc.system_tools.append({ environment: name, system: system.to_str(), tools: tools.map(|tool| tool.to_spec()) }) }
					Command(command, tool) => { ..acc, commands: acc.commands.append({ environment: name, name: command, tool: tool.to_spec() }) }
					RocPackages(urls) => { ..acc, roc_urls: acc.roc_urls.append(urls) }
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
		if draft.roc_urls.len() > 1 {
			return Err("DuplicateRocPackages: environment ${name}")
		}
		var $roc_packages = []
		var $roc_sources = []
		for url in draft.roc_urls.first() ?? [] {
			bundle = roc_bundle(url)?
			if !$roc_packages.any(|entry| entry.name == bundle.name) {
				$roc_packages = $roc_packages.append({ environment: name, name: bundle.name, source: bundle.source.name })
				$roc_sources = $roc_sources.append(bundle.source)
			}
		}
		if draft.parents.len() > 1 {
			return Err("DuplicateExtend: environment ${name}")
		}
		Ok({ environment: { name, parents: draft.parents, tools: draft.tools.first() ?? [], overlays: draft.overlays.first() ?? [] }, system_tools: draft.system_tools, commands: draft.commands, roc_packages: $roc_packages, roc_sources: $roc_sources })
	}

	## A release bundle URL ends in `<content hash>.tar.zst`. The hash is the
	## directory Roc looks for in its package cache.
	roc_bundle : Str -> Try({ name : Str, source : Spec.BuildSource }, Str)
	roc_bundle = |url| {
		file = url.split_on("/").last() ?? ""
		hash = file.drop_suffix(".tar.zst")
		if !url.starts_with("https://") or !file.ends_with(".tar.zst") or !Project.valid_name(hash) {
			return Err("invalid Roc package URL: ${url}; expected https://.../<hash>.tar.zst")
		}
		Ok({ name: hash, source: { name: "roc-${hash}", ref: "tarball+${url}" } })
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

bundle_url : Str -> Str
bundle_url = |hash| "https://example.test/releases/download/1.0.0/${hash}.tar.zst"

# A bundle is named by the hash Roc looks for, and fetched as a locked tarball.
expect Lower.roc_bundle(bundle_url("abc123")) == Ok({ name: "abc123", source: { name: "roc-abc123", ref: "tarball+https://example.test/releases/download/1.0.0/abc123.tar.zst" } })

# Only an https URL ending in a plain `<hash>.tar.zst` is a bundle.
expect ["http://example.test/abc123.tar.zst", "https://example.test/archive.tar.gz", "https://example.test/.tar.zst", "https://example.test/a b.tar.zst", "https://example.test/abc123.tar.zst?x=1", "abc123.tar.zst", ""].all(|url| Lower.roc_bundle(url).is_err())

# Environments sharing a bundle share its one locked source; a repeated URL
# adds nothing, and validation gives the child its parent's bundles first.
expect match Lower.lower([
	Name("packages"),
	Environment("base", [RocPackages([bundle_url("abc123")])]),
	Environment("dev", [Extend("base"), RocPackages([bundle_url("def456"), bundle_url("abc123"), bundle_url("def456")])]),
]) {
	Ok(spec) => spec.requires_ == ["sources", "roc-packages"]
		and spec.build_sources == [
			{ name: "roc-abc123", ref: "tarball+${bundle_url("abc123")}" },
			{ name: "roc-def456", ref: "tarball+${bundle_url("def456")}" },
		]
			and spec.roc_packages == [
				{ environment: "base", name: "abc123", source: "roc-abc123" },
				{ environment: "dev", name: "abc123", source: "roc-abc123" },
				{ environment: "dev", name: "def456", source: "roc-def456" },
			]
	Err(_) => False
}

expect Lower.lower([Name("invalid"), Environment("dev", [RocPackages([]), RocPackages([])])]) == Err("DuplicateRocPackages: environment dev")
expect Lower.lower([Name("plain"), Environment("dev", [])]).map_ok(|spec| spec.requires_.contains("roc-packages") or !spec.roc_packages.is_empty()) == Ok(False)
