# Authoring cardinality checks feed the shared whole-project validator.
import Config
import Recipes
import ProviderSource
import System
import Url
import Val
import core.Spec
import core.Project
import core.Value
import nix.Native

## Lower authoring settings, then share semantic validation with Spec consumers.
## Setting cardinality belongs here because the Spec stores only one value.
Lower :: [].{
	Acc : {
		names : List(Str),
		systems : List(List(System)),
		sources : List(Spec.Source),
		resolvers : List(Spec.Resolver),
		executors : List(Spec.Executor),
		build_executors : List(Spec.BuildExecutor),
		inputs : List(Spec.Input),
		environments : List(Spec.Environment),
		system_tools : List(Spec.SystemTools),
		commands : List(Spec.Command),
		configured_tools : List(Spec.ConfiguredTool),
		roc_packages : List(Spec.RocPackage),
		recipes : List(Recipe),
		environment_programs : List(Spec.EnvironmentPrograms),
		expects : List(Spec.Expects),
		shells : List(Spec.Shell),
		tasks : List(Spec.Task),
		source_files : List(Spec.SourceFile),
		build_sources : List(Spec.BuildSource),
		build_files : List(Spec.BuildFiles),
		builds : List(Spec.Build),
		workflows : List(Spec.Workflow),
		extensions : List(Spec.Extension),
		raw : List(Spec.Raw),
	}

	## A program an environment lists: its command name and the function that
	## says, for a System, where it is downloaded from.
	Recipe : { name : Str, recipe : (System -> Config.Download) }

	## Explicit target defaults; never inferred from the compiling host.
	default_systems : List(System)
	default_systems = ["x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin"]

	lower : List(Config.Setting) -> Try(Spec, Str)
	lower = |settings| {
		initial : Acc
		initial = { resolvers: [], executors: [], build_executors: [], source_files: [], names: [], systems: [], sources: [], inputs: [], environments: [], system_tools: [], commands: [], configured_tools: [], roc_packages: [], recipes: [], environment_programs: [], expects: [], shells: [], tasks: [], build_sources: [], builds: [], build_files: [], workflows: [], extensions: [], raw: [] }
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
		programs = fetched(acc.recipes, Project.unique(systems))?
		# `explicit-sources` is always there: a consumer from before sources
		# were explicit would give this Spec a source it does not declare, and
		# must refuse it by name instead.
		requires_ =
			[explicit_sources]
				.concat(if (acc.extensions.is_empty()) [] else ["extensions"])
				.concat(if (acc.raw.is_empty()) [] else ["raw"])
				.concat(if (acc.build_sources.is_empty()) [] else ["sources"])
				.concat(if (acc.source_files.is_empty()) [] else ["source-files"])
				.concat(if (acc.builds.is_empty()) [] else ["builds"])
				.concat(if (acc.build_files.is_empty()) [] else ["build-files"])
				.concat(if (acc.workflows.is_empty()) [] else ["workflows"])
				.concat(if (acc.system_tools.is_empty()) [] else ["system-tools"])
				.concat(if (acc.commands.is_empty()) [] else ["commands"])
				.concat(if (acc.configured_tools.is_empty()) [] else ["configured-tools"])
				.concat(if (acc.roc_packages.is_empty()) [] else ["roc-packages"])
				.concat(if (programs.is_empty() and acc.environment_programs.is_empty()) [] else ["programs"])
				.concat(if (acc.expects.is_empty()) [] else ["expects"])
		lowered = Spec.{
			resolvers: acc.resolvers,
			executors: acc.executors,
			build_executors: acc.build_executors,
			source_files: acc.source_files,
			format: Spec.current_format,
			name,
			requires_,
			systems: systems.map(|system| system.to_str()),
			sources: acc.sources,
			inputs: acc.inputs,
			environments: acc.environments,
			system_tools: acc.system_tools,
			commands: acc.commands,
			configured_tools: acc.configured_tools,
			roc_packages: acc.roc_packages,
			programs,
			environment_programs: acc.environment_programs,
			expects: acc.expects,
			shells: acc.shells,
			tasks: acc.tasks,
			build_sources: acc.build_sources,
			build_files: acc.build_files,
			builds: acc.builds,
			workflows: acc.workflows,
			extensions: acc.extensions,
			raw: acc.raw,
		}
		project = Project.validate({ ..lowered, resolvers: owned_resolvers(lowered) })?
		for environment in project.environments {
			for tool in environment.tools.concat(project.commands.keep_if(|entry| entry.environment == environment.name).map(|entry| entry.tool)).concat(project.configured_tools.keep_if(|entry| entry.environment == environment.name).map(|entry| entry.tool)).concat(project.system_tools.keep_if(|entry| entry.environment == environment.name).fold([], |tools, entry| tools.concat(entry.tools))) {
				source = project.sources.find_first(|candidate| candidate.name == tool.source).map_err(|_| "unknown source: ${tool.source}")?
				if source.provider.name == "nix" {
					Native.check_tool(Nix, tool.name)?
				} else if source.provider.name == "guix" {
					Native.check_tool(Guix, tool.name)?
				}
			}
		}
		Ok(project)
	}

	add : Acc, Config.Setting -> Try(Acc, Str)
	add = |acc, setting| {
		next = match setting {
			Name(name) => { ..acc, names: acc.names.append(name) }
			Systems(systems) => { ..acc, systems: acc.systems.append(systems) }
			Resolver(provider, inputs) => { ..acc, resolvers: acc.resolvers.append({ provider, inputs: inputs.map(|input| input.to_str()) }) }
			Executor(name, selected) => { ..acc, executors: acc.executors.append(executor(name.to_str(), selected)) }
			Packages(name, source) => { ..acc, sources: acc.sources.append({ name: name.to_str(), provider: provider(source) }) }
			Input(name, ref) => { ..acc, inputs: acc.inputs.append({ name: name.to_str(), url: ref.to_str(), kind: Flake }) }
			Overlay(name, ref) => { ..acc, inputs: acc.inputs.append({ name: name.to_str(), url: ref.to_str(), kind: Overlay }) }
			Environment(name, inner) => {
				lowered = environment(name.to_str(), inner)?
				# Environments sharing a bundle share its one locked source.
				new_sources = lowered.roc_sources.keep_if(|source| !acc.build_sources.contains(source))
				{ ..acc, environments: acc.environments.append(lowered.environment), system_tools: acc.system_tools.concat(lowered.system_tools), commands: acc.commands.concat(lowered.commands), configured_tools: acc.configured_tools.concat(lowered.configured_tools), roc_packages: acc.roc_packages.concat(lowered.roc_packages), recipes: acc.recipes.concat(lowered.recipes), environment_programs: acc.environment_programs.concat(lowered.environment_programs), expects: acc.expects.concat(lowered.expects), build_sources: acc.build_sources.concat(new_sources) }
			}
			Shell(name, inner) => { ..acc, shells: acc.shells.append(shell(name.to_str(), inner)?) }
			Task(name, inner) => { ..acc, tasks: acc.tasks.append(task(name.to_str(), inner)?) }
			SourceFile(name, url, sha256) => { ..acc, source_files: acc.source_files.append({ name: name.to_str(), url: url.to_str(), sha256 }) }
			Source(name, ref) => { ..acc, build_sources: acc.build_sources.append({ name: name.to_str(), ref: ref.to_str() }) }
			Build(name, inner) => {
				var $selected = []
				var $executors = []
				for build_setting in inner {
					match build_setting {
						Execute(executor) => {
							$executors = $executors.append({ build: name.to_str(), executor: executor.to_str() })
						}
						Files(paths) => {
							$selected = $selected.append(paths)
						}
						_ => {}
					}
				}
				if $selected.len() > 1 {
					return Err("DuplicateFiles: build ${name.to_str()}")
				}
				lowered_build = build(name.to_str(), inner)?
				if $executors.len() != 1 {
					return Err("build ${name.to_str()} requires exactly one Execute")
				}
				files = $selected.map(|paths| { build: name.to_str(), paths })
				{ ..acc, builds: acc.builds.append(lowered_build), build_files: acc.build_files.concat(files), build_executors: acc.build_executors.concat($executors) }
			}
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

	## Ask each recipe once for every declared System, in declaration order,
	## and keep only its answers: the Spec holds data, never the function. A
	## program no declared System has could never run, and is refused.
	##
	## A program several environments list is one program: the same name
	## must mean the same downloads. Functions cannot be compared, so two
	## recipes under one name are compared by what they answer for the
	## declared Systems. Two that differ only for a System the project does
	## not declare are taken for the same program.
	fetched : List(Recipe), List(System) -> Try(List(Spec.Program), Str)
	fetched = |recipes, systems| {
		var $programs = []
		var $known = []
		for entry in recipes {
			var $answers = []
			for system in systems {
				match (entry.recipe)(system) {
					File(url) => {
						$answers = $answers.append(program_entry(entry.name, system, File(url), []))
					}
					Archive(url, format, member) => {
						$answers = $answers.append(program_entry(entry.name, system, Archive(url, format, member), []))
					}
					Mirrored(primary, alternates) => {
						$answers = $answers.append(program_entry(entry.name, system, primary, alternates))
					}
					Unavailable => {}
				}
			}
			if $answers.is_empty() {
				return Err("Fetch ${entry.name}: its recipe answers Unavailable for every declared system (${Str.join_with(systems.map(|system| system.to_str()), ", ")})")
			}
			match $known.find_first(|other| other.name == entry.name) {
				Ok(other) => if other.answers != $answers {
					return Err("two different programs are named ${entry.name}: their recipes do not give the same downloads")
				}
				Err(_) => {
					$known = $known.append({ name: entry.name, answers: $answers })
					$programs = $programs.concat($answers)
				}
			}
		}
		Ok($programs)
	}

	## One System's entry: the download's own URL first, then its alternates
	## in the order they were given.
	program_entry : Str, System, Config.Primary, List(Url) -> Spec.Program
	program_entry = |name, system, primary, alternates| {
		others = alternates.map(|url| url.to_str())
		match primary {
			File(url) => { name, system: system.to_str(), urls: [url.to_str()].concat(others), unpack: File, path: "" }
			Archive(url, format, member) => {
				unpack = match format {
					TarGz => TarGz
					TarXz => TarXz
					Zip => Zip
				}
				{ name, system: system.to_str(), urls: [url.to_str()].concat(others), unpack, path: member.to_str() }
			}
		}
	}

	workflow_step : Config.WorkflowStep -> Spec.WorkflowStep
	workflow_step = |step|
		match step {
			RunTask(name, argv) => RunTask(name.to_str(), argv)
			BuildArtifact(name) => BuildArtifact(name.to_str())
			RunWorkflow(name) => RunWorkflow(name.to_str())
		}

	## Lower an executor declaration to its provider name and bootstrap source.
	executor : Str, Config.ExecutorProvider -> Spec.Executor
	executor = |name, selected|
		match selected {
			Nix(source) => { name, provider: "nix", source: source.to_str() }
			Adapter(provider_name, source) => { name, provider: provider_name, source }
		}

	## Declarations whose type already names Nix, flake inputs and overlays,
	## build sources and Roc package bundles, are owned by the Nix resolver
	## unless a Resolver assigns them elsewhere. The Spec records the result
	## explicitly, so a consumer never guesses an owner.
	owned_resolvers : Spec -> List(Spec.Resolver)
	owned_resolvers = |spec| {
		declared = spec.inputs.map(|input| input.name).concat(Project.resolved_build_sources(spec).map(|source| source.name))
		owned = spec.resolvers.fold([], |names, resolver| names.concat(resolver.inputs))
		unowned = Project.unique(declared.keep_if(|name| !owned.contains(name)))
		if unowned.is_empty() {
			spec.resolvers
		} else if spec.resolvers.any(|resolver| resolver.provider == "nix") {
			spec.resolvers.map(|resolver| if (resolver.provider == "nix") { ..resolver, inputs: resolver.inputs.concat(unowned) } else resolver)
		} else {
			spec.resolvers.append({ provider: "nix", inputs: unowned })
		}
	}

	## Lower an explicitly declared package source.
	provider : Config.PackageSource -> Spec.Provider
	provider = |source|
		match source {
			From(NixPackages(ref)) => { name: "nix", version: 1, ref: ref.to_str() }
			From(GuixPackages(channel)) => { name: "guix", version: 1, ref: channel }
			From(Adapter(declaration)) => { name: declaration.provider(), version: declaration.version(), ref: declaration.reference() }
		}

	## The feature every Spec lowered here requires: its sources are all
	## declared, and none is implied.
	explicit_sources : Str
	explicit_sources = "explicit-sources"

	environment : Str, List(Config.EnvironmentSetting) -> Try({ environment : Spec.Environment, system_tools : List(Spec.SystemTools), commands : List(Spec.Command), configured_tools : List(Spec.ConfiguredTool), roc_packages : List(Spec.RocPackage), roc_sources : List(Spec.BuildSource), recipes : List(Recipe), environment_programs : List(Spec.EnvironmentPrograms), expects : List(Spec.Expects) }, Str)
	environment = |name, inner| {
		draft = inner.fold(
			{ tools: [], system_tools: [], commands: [], configured_tools: [], roc_urls: [], overlays: [], parents: [], programs: [], expects: [] },
			|acc, setting|
				match setting {
					Tools(tools) => { ..acc, tools: acc.tools.append(tools.map(|tool| tool.to_spec())) }
					ToolsFor(system, tools) => { ..acc, system_tools: acc.system_tools.append({ environment: name, system: system.to_str(), tools: tools.map(|tool| tool.to_spec()) }) }
					Command(command, tool) => { ..acc, commands: acc.commands.append({ environment: name, name: command, tool: tool.to_spec() }) }
					ToolWith(tool, options) => { ..acc, configured_tools: acc.configured_tools.append({ environment: name, tool: tool.to_spec(), options: to_value(Attrs(options)) }) }
					RocPackages(urls) => { ..acc, roc_urls: acc.roc_urls.append(urls) }
					Overlays(overlays) => { ..acc, overlays: acc.overlays.append(overlays.map(|overlay| overlay.to_str())) }
					Extend(parent) => { ..acc, parents: acc.parents.append(parent.to_str()) }
					Programs(programs) => {
						..acc,
						programs: acc.programs.append(
							programs.map(
								|program|
									match program {
										Fetch(command, recipe) => { name: command.to_str(), recipe }
									},
							),
						),
					}
					Expect(names) => { ..acc, expects: acc.expects.append(names.map(|program| program.to_str())) }
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
		if draft.programs.len() > 1 {
			return Err("DuplicatePrograms: environment ${name}")
		}
		if draft.expects.len() > 1 {
			return Err("DuplicateExpect: environment ${name}")
		}
		# An empty list selects nothing, so it leaves no entry behind.
		selection = |lists| lists.keep_if(|names| !names.is_empty()).map(|names| { environment: name, programs: names })
		recipes = draft.programs.first() ?? []
		Ok({ environment: { name, parents: draft.parents, tools: draft.tools.first() ?? [], overlays: draft.overlays.first() ?? [] }, system_tools: draft.system_tools, commands: draft.commands, configured_tools: draft.configured_tools, roc_packages: $roc_packages, roc_sources: $roc_sources, recipes, environment_programs: selection([recipes.map(|entry| entry.name)]), expects: selection(draft.expects) })
	}

	## A release bundle URL ends in `<content hash>.tar.zst`. The hash is the
	## directory Roc looks for in its package cache.
	roc_bundle : Str -> Try({ name : Str, source : Spec.BuildSource }, Str)
	roc_bundle = |url| {
		file = url.split_on("/").last() ?? ""
		hash = file.drop_suffix(".tar.zst")
		if !url.starts_with("https://") or !file.ends_with(".tar.zst") or !Project.valid_name(hash) {
			return Err("invalid Roc package URL; expected https://.../<hash>.tar.zst:\n    ${url}")
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
					Execute(_) => acc
					Files(_) => acc
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

# Every Spec says its sources are all declared: nothing is added to them, a
# project that declares none has none, and a consumer from before that refuses
# the Spec by the feature's name.
expect Lower.lower([Name("plain"), Environment("dev", [])]).map_ok(|spec| (spec.requires_, spec.sources)) == Ok((["explicit-sources"], []))
expect Lower.lower([Name("sourced"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("dev", [Tools(["nix#git"])])]).map_ok(|spec| (spec.requires_, spec.sources)) == Ok((["explicit-sources"], [{ name: "nix", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-unstable" } }]))

# A source that leaves its package set to the consumer is told what to write,
# and a tool cannot name a source that is not declared.
expect Lower.lower([Name("invalid"), Environment("dev", [Tools(["nix#git"])])]) == Err("unknown source: nix; Blueprint.roc declares no package source")
expect Lower.lower([Name("invalid"), Packages("stable", From(NixPackages("github:NixOS/nixpkgs/nixos-24.05"))), Environment("dev", [Command("vcs", "nix#git")])]) == Err("unknown source: nix; Blueprint.roc declares stable")

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
	Ok(spec) => spec.requires_ == ["explicit-sources", "sources", "roc-packages"]
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

# A configured tool is the tool and its options as data; the Spec says it
# needs a consumer that knows them.
expect match Lower.lower([
	Name("configured"),
	Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))),
	Environment("dev", [ToolWith("nix#rust-bin.stable.\"1.95.0\".default", [("extensions", List([Str("rust-src")]))])]),
]) {
	Ok(spec) => spec.requires_ == ["explicit-sources", "configured-tools"]
		and spec.configured_tools == [
			{
				environment: "dev",
				tool: { source: "nix", name: "rust-bin.stable.\"1.95.0\".default" },
				options: Value.Attrs([{ name: "extensions", value: Value.List([Value.Str("rust-src")]) }]),
			},
		]
	Err(_) => False
}

expect Lower.lower([Name("invalid"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("dev", [ToolWith("nix#zig", []), ToolWith("nix#zig", [])])]) == Err("DuplicateToolWith: environment dev: zig")
expect Lower.lower([Name("invalid"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("dev", [Tools(["nix#zig"]), ToolWith("nix#zig", [])])]) == Err("tool is both plain and configured in environment dev: zig")
expect Lower.lower([Name("invalid"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("dev", [ToolWith("nix#zig", [("a", Int(1)), ("a", Int(2))])])]) == Err("DuplicateOption: tool zig: a")
expect Lower.lower([Name("plain"), Environment("dev", [])]).map_ok(|spec| spec.requires_.contains("roc-packages") or !spec.roc_packages.is_empty()) == Ok(False)

# A recipe from a local function: the release's version is captured, and the
# System decides what the program is called there, or that there is none.
tool_release : Str -> (System -> Config.Download)
tool_release = |version|
	|system|
		match system {
			"x86_64-linux" | "aarch64-darwin" => File("https://example.test/releases/${version}/tool-${system.to_str()}")
			"x86_64-windows" => Archive("https://example.test/releases/${version}/tool-windows.zip", Zip, "tool/tool.exe")
			_ => Unavailable
		}

tool : Config.Program
tool = Fetch("tool", tool_release("1.2.0"))

roc_stable : Config.Program
roc_stable = Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-04-130536d"))

# Each recipe is asked once per declared System, in declaration order, and the
# Spec holds its answers as data: one entry where the program exists and none
# where it does not. Different recipes, capturing or not, share one list, and
# a program two environments list is there once.
expect match Lower.lower([
	Name("fetching"),
	Systems(["x86_64-linux", "aarch64-linux", "x86_64-windows"]),
	Environment("base", [Programs([roc_stable]), Expect(["git"])]),
	Environment(
		"dev",
		[
			Extend("base"),
			Programs([tool, roc_stable, Fetch("notes", |system| Archive("https://example.test/notes-${system.to_str()}.tar.xz", TarXz, "notes/bin/notes"))]),
			Expect(["gh"]),
		],
	),
	Environment("plain", [Programs([]), Expect([])]),
]) {
	Ok(spec) => spec.requires_ == ["explicit-sources", "programs", "expects"]
		and spec.programs == [
			{ name: "roc-stable", system: "x86_64-linux", urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_x86_64-2026-10-04-130536d.tar.gz"], unpack: TarGz, path: "roc_nightly-linux_x86_64-2026-10-04-130536d/roc" },
			{ name: "roc-stable", system: "aarch64-linux", urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_arm64-2026-10-04-130536d.tar.gz"], unpack: TarGz, path: "roc_nightly-linux_arm64-2026-10-04-130536d/roc" },
			{ name: "roc-stable", system: "x86_64-windows", urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-windows_x86_64-2026-10-04-130536d.zip"], unpack: Zip, path: "roc_nightly-windows_x86_64-2026-10-04-130536d/roc.exe" },
			{ name: "tool", system: "x86_64-linux", urls: ["https://example.test/releases/1.2.0/tool-x86_64-linux"], unpack: File, path: "" },
			{ name: "tool", system: "x86_64-windows", urls: ["https://example.test/releases/1.2.0/tool-windows.zip"], unpack: Zip, path: "tool/tool.exe" },
			{ name: "notes", system: "x86_64-linux", urls: ["https://example.test/notes-x86_64-linux.tar.xz"], unpack: TarXz, path: "notes/bin/notes" },
			{ name: "notes", system: "aarch64-linux", urls: ["https://example.test/notes-aarch64-linux.tar.xz"], unpack: TarXz, path: "notes/bin/notes" },
			{ name: "notes", system: "x86_64-windows", urls: ["https://example.test/notes-x86_64-windows.tar.xz"], unpack: TarXz, path: "notes/bin/notes" },
		]
		# Validation gives the child its parent's programs first.
		and spec.environment_programs == [{ environment: "base", programs: ["roc-stable"] }, { environment: "dev", programs: ["roc-stable", "tool", "notes"] }]
		and spec.expects == [{ environment: "base", programs: ["git"] }, { environment: "dev", programs: ["git", "gh"] }]
	Err(_) => False
}

# A System declared twice is asked about once.
expect Lower.lower([Name("fetching"), Systems(["x86_64-linux", "x86_64-linux"]), Environment("dev", [Programs([tool])])]).map_ok(|spec| spec.programs.len()) == Ok(1)

# With no Systems setting the recipe answers for the default ones.
expect Lower.lower([Name("fetching"), Environment("dev", [Programs([tool])])]).map_ok(|spec| spec.programs.map(|program| program.system)) == Ok(["x86_64-linux", "aarch64-darwin"])

# A file recipe names the System in its URL, for every declared System.
expect Lower.lower([Name("fetching"), Systems(["x86_64-linux", "aarch64-darwin"]), Environment("dev", [Programs([Fetch("tool", Recipes.file("https://example.test/{os}/tool-{system}"))])])]).map_ok(|spec| spec.programs.map(|program| program.urls)) == Ok([["https://example.test/linux/tool-x86_64-linux"], ["https://example.test/darwin/tool-aarch64-darwin"]])

# A project that fetches nothing and expects nothing requires neither feature.
expect Lower.lower([Name("plain"), Environment("dev", [Programs([]), Expect([])])]).map_ok(|spec| (spec.requires_, spec.environment_programs, spec.expects)) == Ok((["explicit-sources"], [], []))
expect Lower.lower([Name("expecting"), Environment("dev", [Expect(["git"])])]).map_ok(|spec| spec.requires_) == Ok(["explicit-sources", "expects"])

# A program no declared System has could never run.
expect Lower.lower([Name("invalid"), Systems(["aarch64-linux", "riscv64-linux"]), Environment("dev", [Programs([tool])])]) == Err("Fetch tool: its recipe answers Unavailable for every declared system (aarch64-linux, riscv64-linux)")
expect Lower.lower([Name("invalid"), Environment("dev", [Programs([Fetch("tool", |_| Unavailable)])])]) == Err("Fetch tool: its recipe answers Unavailable for every declared system (x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin)")

# One name is one program, wherever it is listed: the same recipe, or another
# that answers the same for the declared Systems, is that program once.
expect Lower.lower([
	Name("shared"),
	Systems(["x86_64-linux"]),
	Environment("one", [Programs([tool])]),
	Environment("two", [Programs([Fetch("tool", tool_release("1.2.0")), tool])]),
	Environment("three", [Programs([Fetch("tool", |_| File("https://example.test/releases/1.2.0/tool-x86_64-linux"))])]),
]).map_ok(|spec| (spec.programs.len(), spec.environment_programs.map(|entry| entry.programs))) == Ok((1, [["tool"], ["tool"], ["tool"]]))

# Two recipes that answer differently are two programs, and cannot share a name.
expect Lower.lower([Name("invalid"), Environment("one", [Programs([tool])]), Environment("two", [Programs([Fetch("tool", tool_release("1.3.0"))])])]) == Err("two different programs are named tool: their recipes do not give the same downloads")
expect Lower.lower([Name("invalid"), Environment("dev", [Programs([tool, Fetch("tool", tool_release("1.3.0"))])])]) == Err("two different programs are named tool: their recipes do not give the same downloads")
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux", "x86_64-windows"]), Environment("one", [Programs([tool])]), Environment("two", [Programs([Fetch("tool", |system| if (system == "x86_64-linux") File("https://example.test/releases/1.2.0/tool-x86_64-linux") else Unavailable)])])]) == Err("two different programs are named tool: their recipes do not give the same downloads")

# They are compared on the declared Systems alone: these differ on Windows,
# which this project does not declare.
expect Lower.lower([Name("shared"), Systems(["x86_64-linux"]), Environment("one", [Programs([tool])]), Environment("two", [Programs([Fetch("tool", |system| if (system == "x86_64-windows") Unavailable else File("https://example.test/releases/1.2.0/tool-x86_64-linux"))])])]).map_ok(|spec| spec.programs.len()) == Ok(1)

expect Lower.lower([Name("invalid"), Environment("dev", [Programs([]), Programs([])])]) == Err("DuplicatePrograms: environment dev")
expect Lower.lower([Name("invalid"), Environment("dev", [Expect(["git"]), Expect(["gh"])])]) == Err("DuplicateExpect: environment dev")

# The shared validator sees what a recipe answered. A quoted URL or path is
# refused where it is written; one that is assembled is refused here, with
# the value on a line of its own.
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux"]), Environment("dev", [Programs([Fetch("tool", |system| File("http://example.test/tool-${system.to_str()}"))])])]) == Err("program tool on x86_64-linux has a URL that is not a download URL; expected https://<host>/<path> with no credentials, query or fragment:\n    http://example.test/tool-x86_64-linux")
expect {
	up = ".."
	Lower.lower([Name("invalid"), Systems(["x86_64-linux"]), Environment("dev", [Programs([Fetch("tool", |_| Archive("https://example.test/tool.tar.gz", TarGz, "${up}/tool"))])])]) == Err("program tool on x86_64-linux: invalid path in its archive:\n    ../tool")
}
expect Lower.lower([Name("invalid"), Environment("dev", [Programs([tool]), Expect(["tool"])])]) == Err("environment dev has tool as both a program and an expected tool")
expect Lower.lower([Name("invalid"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("base", [Command("tool", "nix#hello")]), Environment("dev", [Extend("base"), Programs([tool])])]) == Err("environment dev has tool as both a program and a Command")
expect Lower.lower([Name("invalid"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("dev", [Command("git", "nix#git"), Expect(["git"])])]) == Err("environment dev has git as both an expected tool and a Command")

# Alternates for the same bytes follow the download's own URL, in order, for a
# file and for an archive; with none given the download is as it was.
expect Lower.lower([
	Name("mirrored"),
	Systems(["x86_64-linux"]),
	Environment(
		"dev",
		[
			Programs([
				Fetch("tool", |system| Mirrored(File("https://example.test/tool-${system.to_str()}"), ["https://mirror.example.test/tool-${system.to_str()}", "https://other.example.test/tool"])),
				Fetch("notes", |_| Mirrored(Archive("https://example.test/notes.tar.gz", TarGz, "notes/bin/notes"), ["https://mirror.example.test/notes.tar.gz"])),
				Fetch("plain", |_| Mirrored(File("https://example.test/plain"), [])),
			]),
		],
	),
]).map_ok(|spec| spec.programs) == Ok([
	{ name: "tool", system: "x86_64-linux", urls: ["https://example.test/tool-x86_64-linux", "https://mirror.example.test/tool-x86_64-linux", "https://other.example.test/tool"], unpack: File, path: "" },
	{ name: "notes", system: "x86_64-linux", urls: ["https://example.test/notes.tar.gz", "https://mirror.example.test/notes.tar.gz"], unpack: TarGz, path: "notes/bin/notes" },
	{ name: "plain", system: "x86_64-linux", urls: ["https://example.test/plain"], unpack: File, path: "" },
])

# An alternate is held to the rule of every URL, and is given once.
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux"]), Environment("dev", [Programs([Fetch("tool", |_| Mirrored(File("https://example.test/tool"), ["https://mirror.example.test/tool", Url.assembled("http://mirror.example.test/tool")]))])])]) == Err("program tool on x86_64-linux has a URL that is not a download URL; expected https://<host>/<path> with no credentials, query or fragment:\n    http://mirror.example.test/tool")
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux"]), Environment("dev", [Programs([Fetch("tool", |_| Mirrored(File("https://example.test/tool"), ["https://example.test/tool"]))])])]) == Err("program tool on x86_64-linux names a URL twice:\n    https://example.test/tool")
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux"]), Environment("dev", [Programs([Fetch("tool", |_| Mirrored(Archive("https://example.test/tool.zip", Zip, "tool.exe"), ["https://mirror.example.test/tool.zip", "https://mirror.example.test/tool.zip"]))])])]) == Err("program tool on x86_64-linux names a URL twice:\n    https://mirror.example.test/tool.zip")

# File selection is optional; an explicit empty selection is distinct from omitted.
expect Lower.lower([Name("selected"), Environment("build", []), Executor("native", Adapter("fixture", "")), Build("app", [Execute("native"), Use("build"), Files(["scripts", "recipe.txt"]), Run(["build"]), Output("out")])]).map_ok(|spec| { files: spec.build_files, feature: spec.requires_.contains("build-files") }) == Ok({ files: [{ build: "app", paths: ["scripts", "recipe.txt"] }], feature: True })
expect Lower.lower([Name("empty"), Environment("build", []), Executor("native", Adapter("fixture", "")), Build("app", [Execute("native"), Use("build"), Files([]), Run(["build"]), Output("out")])]).map_ok(|spec| spec.build_files) == Ok([{ build: "app", paths: [] }])
expect Lower.lower([Name("duplicate"), Environment("build", []), Executor("native", Adapter("fixture", "")), Build("app", [Execute("native"), Use("build"), Files([]), Files([]), Run(["build"]), Output("out")])]) == Err("DuplicateFiles: build app")
expect Lower.lower([Name("escape"), Environment("build", []), Executor("native", Adapter("fixture", "")), Build("app", [Execute("native"), Use("build"), Files(["../outside"]), Run(["build"]), Output("out")])]) == Err("invalid selected build path: ../outside")

# An executor carries its provider's settings: a Nix executor names the package
# source it bootstraps from, and another adapter's executor may name none.
expect Lower.lower([Name("executors"), Packages("pkgs", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("build", []), Executor("native", Nix("pkgs")), Executor("other", Adapter("fixture", "")), Build("app", [Execute("native"), Use("build"), Run(["build"]), Output("out")])]).map_ok(|spec| spec.executors) == Ok([{ name: "native", provider: "nix", source: "pkgs" }, { name: "other", provider: "fixture", source: "" }])
expect Lower.lower([Name("unowned"), Environment("build", []), Executor("native", Nix("pkgs")), Build("app", [Execute("native"), Use("build"), Run(["build"]), Output("out")])]) == Err("executor native bootstrap source pkgs is not owned by nix")

# Flake inputs, overlays, build sources and Roc bundles are Nix-typed, so the
# Nix resolver owns them without a Resolver line; one merges with an explicit
# Nix entry, and another provider's Resolver takes a name out of Nix's hands.
expect Lower.lower([Name("owned"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Overlay("roc", "github:roc-lang/roc-overlay"), Input("utils", "github:numtide/flake-utils"), Environment("dev", [Overlays(["roc"])])]).map_ok(|spec| spec.resolvers) == Ok([{ provider: "nix", inputs: ["roc", "utils"] }])
expect Lower.lower([Name("merged"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Resolver("nix", ["roc"]), Overlay("roc", "github:roc-lang/roc-overlay"), Input("utils", "github:numtide/flake-utils"), Environment("dev", [Overlays(["roc"])])]).map_ok(|spec| spec.resolvers) == Ok([{ provider: "nix", inputs: ["roc", "utils"] }])
expect Lower.lower([Name("elsewhere"), Resolver("fixture", ["assets"]), Environment("build", []), Executor("native", Adapter("fixture", "")), Source("assets", "path:./assets"), Build("app", [Execute("native"), Use("build"), Inputs(["assets"]), Run(["build"]), Output("out")])]).map_ok(|spec| spec.resolvers) == Ok([{ provider: "fixture", inputs: ["assets"] }])
