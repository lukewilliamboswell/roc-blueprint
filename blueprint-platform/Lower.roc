# Authoring cardinality checks feed the shared whole-project validator.
import Config
import Recipes
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
		configured_tools : List(Spec.ConfiguredTool),
		roc_packages : List(Spec.RocPackage),
		recipes : List(Recipe),
		environment_programs : List(Spec.EnvironmentPrograms),
		expects : List(Spec.Expects),
		shells : List(Spec.Shell),
		tasks : List(Spec.Task),
		build_sources : List(Spec.BuildSource),
		builds : List(Spec.Build),
		workflows : List(Spec.Workflow),
		extensions : List(Spec.Extension),
		raw : List(Spec.Raw),
	}

	## A declared program: its command name and the function that says, for a
	## System, where it is downloaded from.
	Recipe : { name : Str, recipe : (Str -> Config.Download) }

	## Explicit target defaults; never inferred from the compiling host.
	default_systems : List(Str)
	default_systems = ["x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin"]

	lower : List(Config.Setting) -> Try(Spec, Str)
	lower = |settings| {
		initial : Acc
		initial = { names: [], systems: [], sources: [], inputs: [], environments: [], system_tools: [], commands: [], configured_tools: [], roc_packages: [], recipes: [], environment_programs: [], expects: [], shells: [], tasks: [], build_sources: [], builds: [], workflows: [], extensions: [], raw: [] }
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
		requires_ =
			(if acc.extensions.is_empty() [] else ["extensions"])
				.concat(if acc.raw.is_empty() [] else ["raw"])
				.concat(if acc.build_sources.is_empty() [] else ["sources"])
				.concat(if acc.builds.is_empty() [] else ["builds"])
				.concat(if acc.workflows.is_empty() [] else ["workflows"])
				.concat(if acc.system_tools.is_empty() [] else ["system-tools"])
				.concat(if acc.commands.is_empty() [] else ["commands"])
				.concat(if acc.configured_tools.is_empty() [] else ["configured-tools"])
				.concat(if acc.roc_packages.is_empty() [] else ["roc-packages"])
				.concat(if programs.is_empty() and acc.environment_programs.is_empty() [] else ["programs"])
				.concat(if acc.expects.is_empty() [] else ["expects"])
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
				configured_tools: acc.configured_tools,
				roc_packages: acc.roc_packages,
				programs,
				environment_programs: acc.environment_programs,
				expects: acc.expects,
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
				{ ..acc, environments: acc.environments.append(lowered.environment), system_tools: acc.system_tools.concat(lowered.system_tools), commands: acc.commands.concat(lowered.commands), configured_tools: acc.configured_tools.concat(lowered.configured_tools), roc_packages: acc.roc_packages.concat(lowered.roc_packages), environment_programs: acc.environment_programs.concat(lowered.environment_programs), expects: acc.expects.concat(lowered.expects), build_sources: acc.build_sources.concat(new_sources) }
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
			Fetch(name, recipe) => { ..acc, recipes: acc.recipes.append({ name: name.to_str(), recipe }) }
		}
		Ok(next)
	}

	## Ask each recipe once for every declared System, in declaration order,
	## and keep only its answers: the Spec holds data, never the function. A
	## recipe's `Invalid` is the configuration's error. So is a program no
	## declared System has, which nothing could ever run.
	fetched : List(Recipe), List(Str) -> Try(List(Spec.Program), Str)
	fetched = |recipes, systems| {
		var $programs = []
		var $names = []
		for entry in recipes {
			if $names.contains(entry.name) {
				return Err("DuplicateFetch: ${entry.name}")
			}
			$names = $names.append(entry.name)
			var $available = False
			for system in systems {
				match (entry.recipe)(system) {
					File(url) => {
						$available = True
						$programs = $programs.append(program_entry(entry.name, system, File(url), []))
					}
					Archive(url, format, path) => {
						$available = True
						$programs = $programs.append(program_entry(entry.name, system, Archive(url, format, path), []))
					}
					Mirrored(primary, alternates) => {
						$available = True
						$programs = $programs.append(program_entry(entry.name, system, primary, alternates))
					}
					Unavailable => {}
					Invalid(message) => return Err("Fetch ${entry.name}: ${message}")
				}
			}
			if !$available {
				return Err("Fetch ${entry.name}: its recipe answers Unavailable for every declared system (${Str.join_with(systems, ", ")})")
			}
		}
		Ok($programs)
	}

	## One System's entry: the download's own URL first, then its alternates
	## in the order they were given.
	program_entry : Str, Str, Config.Primary, List(Str) -> Spec.Program
	program_entry = |name, system, primary, alternates|
		match primary {
			File(url) => { name, system, urls: [url].concat(alternates), unpack: File, path: "" }
			Archive(url, format, path) => {
				unpack = match format {
					TarGz => TarGz
					TarXz => TarXz
					Zip => Zip
				}
				{ name, system, urls: [url].concat(alternates), unpack, path }
			}
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

	environment : Str, List(Config.EnvironmentSetting) -> Try({ environment : Spec.Environment, system_tools : List(Spec.SystemTools), commands : List(Spec.Command), configured_tools : List(Spec.ConfiguredTool), roc_packages : List(Spec.RocPackage), roc_sources : List(Spec.BuildSource), environment_programs : List(Spec.EnvironmentPrograms), expects : List(Spec.Expects) }, Str)
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
					Programs(names) => { ..acc, programs: acc.programs.append(names.map(|program| program.to_str())) }
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
		Ok({ environment: { name, parents: draft.parents, tools: draft.tools.first() ?? [], overlays: draft.overlays.first() ?? [] }, system_tools: draft.system_tools, commands: draft.commands, configured_tools: draft.configured_tools, roc_packages: $roc_packages, roc_sources: $roc_sources, environment_programs: selection(draft.programs), expects: selection(draft.expects) })
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

# A configured tool is the tool and its options as data; the Spec says it
# needs a consumer that knows them.
expect match Lower.lower([
	Name("configured"),
	Environment("dev", [ToolWith("rust-bin.stable.\"1.95.0\".default", [("extensions", List([Str("rust-src")]))])]),
]) {
	Ok(spec) => spec.requires_ == ["configured-tools"]
		and spec.configured_tools == [
			{
				environment: "dev",
				tool: { source: "default", name: "rust-bin.stable.\"1.95.0\".default" },
				options: Value.Attrs([{ name: "extensions", value: Value.List([Value.Str("rust-src")]) }]),
			},
		]
	Err(_) => False
}

expect Lower.lower([Name("invalid"), Environment("dev", [ToolWith("zig", []), ToolWith("zig", [])])]) == Err("DuplicateToolWith: environment dev: zig")
expect Lower.lower([Name("invalid"), Environment("dev", [Tools(["zig"]), ToolWith("zig", [])])]) == Err("tool is both plain and configured in environment dev: zig")
expect Lower.lower([Name("invalid"), Environment("dev", [ToolWith("zig", [("a", Int(1)), ("a", Int(2))])])]) == Err("DuplicateOption: tool zig: a")
expect Lower.lower([Name("plain"), Environment("dev", [])]).map_ok(|spec| spec.requires_.contains("roc-packages") or !spec.roc_packages.is_empty()) == Ok(False)

# A recipe from a local function: the release's version is captured, and the
# System decides what the program is called there, or that there is none.
tool_release : Str -> (Str -> Config.Download)
tool_release = |version|
	|system|
		match system {
			"x86_64-linux" | "aarch64-darwin" => File("https://example.test/releases/${version}/tool-${system}")
			"x86_64-windows" => Archive("https://example.test/releases/${version}/tool-windows.zip", Zip, "tool/tool.exe")
			_ => Unavailable
		}

# Each recipe is asked once per declared System, in declaration order, and the
# Spec holds its answers as data: one entry where the program exists and none
# where it does not. Different recipes, capturing or not, share one list.
expect match Lower.lower([
	Name("fetching"),
	Systems(["x86_64-linux", "aarch64-linux", "x86_64-windows"]),
	Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-04-130536d")),
	Fetch("tool", tool_release("1.2.0")),
	Fetch("notes", |system| Archive("https://example.test/notes-${system}.tar.xz", TarXz, "notes/bin/notes")),
	Environment("base", [Programs(["roc-stable"]), Expect(["git"])]),
	Environment("dev", [Extend("base"), Programs(["tool", "roc-stable"]), Expect(["gh"])]),
	Environment("plain", [Programs([]), Expect([])]),
]) {
	Ok(spec) => spec.requires_ == ["programs", "expects"]
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
			# Validation gives the child its parent's selections first.
			and spec.environment_programs == [{ environment: "base", programs: ["roc-stable"] }, { environment: "dev", programs: ["roc-stable", "tool"] }]
				and spec.expects == [{ environment: "base", programs: ["git"] }, { environment: "dev", programs: ["git", "gh"] }]
	Err(_) => False
}

# A System declared twice is asked about once.
expect Lower.lower([Name("fetching"), Systems(["x86_64-linux", "x86_64-linux"]), Fetch("tool", tool_release("1.2.0"))]).map_ok(|spec| spec.programs.len()) == Ok(1)

# With no Systems setting the recipe answers for the default ones.
expect Lower.lower([Name("fetching"), Fetch("tool", tool_release("1.2.0"))]).map_ok(|spec| spec.programs.map(|program| program.system)) == Ok(["x86_64-linux", "aarch64-darwin"])

# A project that fetches nothing and expects nothing requires neither feature.
expect Lower.lower([Name("plain"), Environment("dev", [Programs([]), Expect([])])]).map_ok(|spec| (spec.requires_, spec.environment_programs, spec.expects)) == Ok(([], [], []))
expect Lower.lower([Name("expecting"), Environment("dev", [Expect(["git"])])]).map_ok(|spec| spec.requires_) == Ok(["expects"])

# What a recipe calls invalid is the configuration's error, in its own words.
expect Lower.lower([Name("invalid"), Fetch("roc-stable", Recipes.roc_nightly("v1.0"))]) == Err("Fetch roc-stable: \"v1.0\" is not a Roc nightly tag; expected nightly-YYYY-MM-DD-<commit>")
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux", "aarch64-darwin"]), Fetch("tool", |system| if system == "aarch64-darwin" Invalid("no build for ${system} since 2.0") else Unavailable)]) == Err("Fetch tool: no build for aarch64-darwin since 2.0")

# A program no declared System has could never run.
expect Lower.lower([Name("invalid"), Systems(["aarch64-linux", "riscv64-linux"]), Fetch("tool", tool_release("1.2.0"))]) == Err("Fetch tool: its recipe answers Unavailable for every declared system (aarch64-linux, riscv64-linux)")

# A name is declared once, even by a recipe that would answer nothing.
expect Lower.lower([Name("invalid"), Fetch("tool", tool_release("1.2.0")), Fetch("tool", tool_release("1.3.0"))]) == Err("DuplicateFetch: tool")
expect Lower.lower([Name("invalid"), Fetch("tool", tool_release("1.2.0")), Fetch("tool", |_| Unavailable)]) == Err("DuplicateFetch: tool")

expect Lower.lower([Name("invalid"), Environment("dev", [Programs([]), Programs([])])]) == Err("DuplicatePrograms: environment dev")
expect Lower.lower([Name("invalid"), Environment("dev", [Expect(["git"]), Expect(["gh"])])]) == Err("DuplicateExpect: environment dev")

# The shared validator sees what a recipe answered: a URL that is not a
# download, a selection nothing declares, and one name with two origins.
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux"]), Fetch("tool", |system| File("http://example.test/tool-${system}"))]) == Err("program tool on x86_64-linux: \"http://example.test/tool-x86_64-linux\" is not a download URL; expected https://<host>/<path> with no credentials, query or fragment")
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux"]), Fetch("tool", |_| Archive("https://example.test/tool.tar.gz", TarGz, "../tool"))]) == Err("program tool on x86_64-linux: invalid path in its archive: ../tool")
expect Lower.lower([Name("invalid"), Environment("dev", [Programs(["tool"])])]) == Err("environment dev selects program tool, which no Fetch declares")
expect Lower.lower([Name("invalid"), Fetch("tool", tool_release("1.2.0")), Environment("dev", [Programs(["tool"]), Expect(["tool"])])]) == Err("environment dev has tool as both a program and an expected tool")
expect Lower.lower([Name("invalid"), Fetch("tool", tool_release("1.2.0")), Environment("base", [Command("tool", "hello")]), Environment("dev", [Extend("base"), Programs(["tool"])])]) == Err("environment dev has tool as both a program and a Command")
expect Lower.lower([Name("invalid"), Environment("dev", [Command("git", "git"), Expect(["git"])])]) == Err("environment dev has git as both an expected tool and a Command")

# Alternates for the same bytes follow the download's own URL, in order, for a
# file and for an archive; with none given the download is as it was.
expect Lower.lower([
	Name("mirrored"),
	Systems(["x86_64-linux"]),
	Fetch("tool", |system| Mirrored(File("https://example.test/tool-${system}"), ["https://mirror.example.test/tool-${system}", "https://other.example.test/tool"])),
	Fetch("notes", |_| Mirrored(Archive("https://example.test/notes.tar.gz", TarGz, "notes/bin/notes"), ["https://mirror.example.test/notes.tar.gz"])),
	Fetch("plain", |_| Mirrored(File("https://example.test/plain"), [])),
]).map_ok(|spec| spec.programs) == Ok([
	{ name: "tool", system: "x86_64-linux", urls: ["https://example.test/tool-x86_64-linux", "https://mirror.example.test/tool-x86_64-linux", "https://other.example.test/tool"], unpack: File, path: "" },
	{ name: "notes", system: "x86_64-linux", urls: ["https://example.test/notes.tar.gz", "https://mirror.example.test/notes.tar.gz"], unpack: TarGz, path: "notes/bin/notes" },
	{ name: "plain", system: "x86_64-linux", urls: ["https://example.test/plain"], unpack: File, path: "" },
])

# An alternate is held to the rule of every URL, and is given once.
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux"]), Fetch("tool", |_| Mirrored(File("https://example.test/tool"), ["https://mirror.example.test/tool", "http://mirror.example.test/tool"]))]) == Err("program tool on x86_64-linux: \"http://mirror.example.test/tool\" is not a download URL; expected https://<host>/<path> with no credentials, query or fragment")
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux"]), Fetch("tool", |_| Mirrored(File("https://example.test/tool"), ["https://example.test/tool"]))]) == Err("program tool on x86_64-linux names \"https://example.test/tool\" twice")
expect Lower.lower([Name("invalid"), Systems(["x86_64-linux"]), Fetch("tool", |_| Mirrored(Archive("https://example.test/tool.zip", Zip, "tool.exe"), ["https://mirror.example.test/tool.zip", "https://mirror.example.test/tool.zip"]))]) == Err("program tool on x86_64-linux names \"https://mirror.example.test/tool.zip\" twice")
