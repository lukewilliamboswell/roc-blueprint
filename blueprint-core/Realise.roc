# Pure planning of a request: what the Core supplies itself, and what it asks
# of a provider. See docs/architecture.adoc, stages Fetch and Realise.
import Spec
import Project
import Request
import Layout
import Lock
import Steps
import Provider

## The Core's own plan for a request. An environment's fetched programs, the
## tools it expects of the machine and its Roc packages are the Core's to
## supply and check, from the Spec and the Lock alone. A provider is asked
## only for an environment that has a tool from a package source it
## supplies, and what the Core supplies is then added to the provider's
## steps. Nothing here observes the machine: the result is data for an
## executor.
Realise :: [].{

	## The Spec features planned here, whatever provider is at hand.
	## `explicit-sources` is the Core's own: a Spec that requires it declares
	## every source its tools name, and none is added to it.
	features : List(Str)
	features = ["explicit-sources", "source-files", "programs", "expects"]

	## The ordered steps of one request on a System, or everything that
	## stops it. Every task and build of a workflow is planned before a
	## problem is reported, so the list is whole: each program that is
	## unavailable, not in the Lock or declared with other URLs than the
	## Lock's, each source no provider supplies, and what a provider itself
	## refuses. A request with a problem yields no step at all.
	## The caller has parsed the Lock and found its intent current.
	plan : Spec, Request, Str, Layout, Lock, List(Provider) -> Try(Steps, List(Str))
	plan = |spec, request, system, layout, lock, providers| plan_within(spec, request, system, layout, Read(lock), providers, workflow_budget)

	## Everything that stops a request and can be known without the Lock, so
	## that a caller can say it before reading one: the project, the layout
	## and the System, the names the request uses, the sources no provider
	## supplies, the programs the System has none of, and what each provider
	## asked refuses in its own `preflight`. A request that passes may still
	## fail to plan, for what only the Lock says.
	preflight : Spec, Request, Str, Layout, List(Provider) -> Try({}, List(Str))
	preflight = |spec, request, system, layout, providers| {
		_ = plan_within(spec, request, system, layout, Unread, providers, workflow_budget)?
		Ok({})
	}

	## The providers Resolve has pins to ask of, for a validated Spec: one
	## that supplies a declared package source, and, while a project has
	## flake inputs or build sources a provider resolves, every provider at
	## hand. A project that declares none of these has nothing for a provider
	## to resolve, and its update needs none installed: what it fetches and
	## expects is the Core's own.
	resolvers : Spec, List(Provider) -> List(Provider)
	resolvers = |project, providers| {
		owners = Project.unique(project.sources.map(|source| source.provider.name).concat(project.resolvers.keep_if(|resolver| !resolver.inputs.is_empty()).map(|resolver| resolver.provider)))
		providers.keep_if(|candidate| owners.contains(candidate.name))
	}

	## An update was asked for names that are neither an input a provider
	## resolves nor a program: what the project does declare of each.
	unknown_names : List(Str), List(Str), List(Str) -> Str
	unknown_names = |unknown, inputs, programs| {
		listed = |kind, names| if (names.is_empty()) "no ${kind}" else "the ${kind}s ${Str.join_with(names, ", ")}"
		"no input or program named ${Str.join_with(unknown, ", ")}; Blueprint.roc declares ${listed("input", inputs)} and ${listed("program", programs)}"
	}

	## The Lock a plan is made from, or that none has been read yet.
	Authority : [Read(Lock), Unread]

	## The most text a workflow's distinct requests may hold together, files
	## and argv: 16 MiB.
	workflow_budget : U64
	workflow_budget = 16777216

	## `plan` with the workflow allowance as a parameter, so that the
	## accounting is tested with small numbers. Callers use `plan`.
	plan_within : Spec, Request, Str, Layout, Authority, List(Provider), U64 -> Try(Steps, List(Str))
	plan_within = |spec, request, system, layout, authority, providers, allowance| {
		project = Project.validate(spec).map_err(|message| [message])?
		check_layout(layout).map_err(|message| [message])?
		if !project.systems.contains(system) {
			return Err(["target ${system} is not declared by the project"])
		}
		workflow = match request {
			Request.Workflow(_) => True
			_ => False
		}
		requests = match request {
			Request.Workflow(name) =>
				Project.workflow_steps(project, name).map_err(|message| [message])?.map(
					|step|
						match step {
							RunTask(task, extra) => Request.Run(task, extra)
							BuildArtifact(build) => Request.Build(build)
						},
				)

			other => [other]
		}
		var $steps = []
		var $problems = []
		var $planned = []
		var $bytes = 0.U64
		for atomic in requests {
			# One plan for each distinct request; a repeated request still
			# appends its complete steps.
			outcome = match $planned.find_first(|entry| entry.request == atomic) {
				Ok(entry) => entry.outcome
				Err(_) => {
					fresh = plan_atomic(project, atomic, system, layout, authority, providers)
					$bytes = $bytes + (fresh.map_ok(|steps| steps.fold(0, |size, step| size + step_bytes(step))) ?? 0)
					$planned = $planned.append({ request: atomic, outcome: fresh })
					fresh
				}
			}
			match outcome {
				Ok(steps) => {
					$steps = $steps.concat(steps)
				}
				Err(problems) => {
					$problems = $problems.concat(problems)
				}
			}
		}
		if workflow and $bytes > allowance {
			$problems = $problems.append("workflow plan exceeds 16 MiB of distinct rendered requests")
		}
		if ($problems.is_empty()) Ok(Steps.{ steps: $steps }) else Err(Project.unique($problems))
	}

	## The text a step stages and starts.
	step_bytes : Steps.Step -> U64
	step_bytes = |step|
		step.files.fold(0, |size, file| size + file.contents.to_utf8().len())
			+ step.argv.fold(0, |size, arg| size + arg.to_utf8().len())

	plan_atomic : Spec, Request, Str, Layout, Authority, List(Provider) -> Try(List(Steps.Step), List(Str))
	plan_atomic = |project, request, system, layout, authority, providers|
		match request {
			# Only a provider generates files. One that supplies no declared
			# source has nothing to say about the project.
			Request.Generate => {
				var $steps = []
				for provider in providers.keep_if(|candidate| project.sources.any(|source| (candidate.realises)(source.provider))) {
					$steps = $steps.concat(asked(provider, project, request, system, layout, authority)?)
				}
				Ok($steps)
			}
			Request.Run(name, extra) => {
				task = project.tasks.find_first(|t| t.name == name).map_err(|_| ["unknown task: ${name}"])?
				argv = task.run.concat(extra)
				Project.check_argv(argv, name).map_err(|message| [message])?
				entered(project, { subject: "task ${name}", environment: task.environment, action: Run(name), argv }, request, system, layout, authority, providers)
			}
			Request.Shell(name) => {
				shell = project.shells.find_first(|s| s.name == name).map_err(|_| ["unknown shell: ${name}"])?
				# With no provider the executor starts the caller's own shell:
				# which program that is belongs to presentation, not the plan.
				entered(project, { subject: "shell ${name}", environment: shell.environment, action: Shell(name), argv: [] }, request, system, layout, authority, providers)
			}
			Request.Build(name) => built(project, name, request, system, layout, authority, providers)
			Request.Workflow(_) => Err(["workflow must expand into atomic requests"])
		}

	## A task or shell and the environment it is entered for.
	Entry : { subject : Str, environment : Str, action : [Generate, Shell(Str), Run(Str), Build(Str)], argv : List(Str) }

	## Enter an environment for a task or a shell. One with no package tool is
	## the Core's alone: the step is the task's own argv, after what the Core
	## supplies. Any other is the provider's step, with the same added first.
	entered : Spec, Entry, Request, Str, Layout, Authority, List(Provider) -> Try(List(Steps.Step), List(Str))
	entered = |project, entry, request, system, layout, authority, providers| {
		use = Project.environment_use(project, entry.environment, system).map_err(|message| [message])?
		supplied = supply(entry.subject, entry.environment, use, system, authority)
		if use.tools.is_empty() {
			match started(entry, use, system, layout) {
				Ok(argv) =>
					if supplied.problems.is_empty() {
						Ok([{ action: entry.action, files: [], argv, artifacts: [], operations: supplied.operations }])
					} else {
						Err(supplied.problems)
					}

				Err(problem) => Err(supplied.problems.append(problem))
			}
		} else {
			steps = match supplier(project, providers, entry.environment, use.tools.map(|tool| tool.source)) {
				Ok(provider) => asked(provider, project, request, system, layout, authority)
				Err(problem) => Err([problem])
			}
			match steps {
				Ok(provided) => if (supplied.problems.is_empty()) Ok(provided.map(|step| with_supplied(step, supplied.operations))) else Err(supplied.problems)
				Err(problems) => Err(supplied.problems.concat(problems))
			}
		}
	}

	## Build execution is selected explicitly. Provider capability validation
	## determines which package, downloaded or host tools it can support.
	built : Spec, Str, Request, Str, Layout, Authority, List(Provider) -> Try(List(Steps.Step), List(Str))
	built = |project, name, request, system, layout, authority, providers| {
		closure = Project.build_closure(project, name).map_err(|message| [message])?
		executors = closure.map(|build| Project.build_executor(project, build.name))
		var $owners = []
		for selected in executors {
			executor = selected.map_err(|problem| [problem])?
			$owners = Project.unique($owners.append(executor.provider))
		}
		if $owners.len() != 1 {
			return Err(["build ${name} requires unsupported mixed executors: ${Str.join_with($owners, ", ")}"])
		}
		owner = $owners.first() ?? ""
		selected = providers.keep_if(|candidate| candidate.name == owner)
		match selected {
			[provider] => asked(provider, project, request, system, layout, authority)
			[] => Err(["build ${name} executor provider is unavailable: ${owner}"])
			_ => Err(["build ${name} executor provider is registered more than once: ${owner}"])
		}
	}

	## A provider's steps for one atomic request, or what it says against it.
	## Before a Lock is read it is asked only whether it would refuse.
	asked : Provider, Spec, Request, Str, Layout, Authority -> Try(List(Steps.Step), List(Str))
	asked = |provider, project, request, system, layout, authority| {
		for source in project.sources.keep_if(|entry| entry.provider.name == provider.name) {
			_ = (provider.validate_source)(source.provider).map_err(|problem| [problem])?
		}
		for tool in project.environments.fold([], |tools, environment| tools.concat(environment.tools)).concat(project.system_tools.fold([], |tools, entry| tools.concat(entry.tools))).concat(project.commands.map(|entry| entry.tool)).concat(project.configured_tools.map(|entry| entry.tool)) {
			if project.sources.any(|source| source.name == tool.source and source.provider.name == provider.name) {
				_ = (provider.validate_tool)(tool.name).map_err(|problem| [problem])?
			}
		}
		match authority {
			Unread => {
				(provider.preflight)(project, request, system, layout).map_err(|message| [message])?
				Ok([])
			}
			Read(lock) => {
				_ = (provider.preflight)(project, request, system, layout).map_err(|message| [message])?
				match (provider.realise)(project, request, system, layout, lock) {
					Ok(steps) => Ok(steps.steps)
					Err(InvalidLock(message)) => Err([message])
					Err(Unrealisable(message)) => Err([message])
				}
			}
		}

	}

	## The one provider that supplies every one of these sources. Tools of an
	## environment come from sources by name; a source no provider here
	## supplies stops the request, and so do two providers for one
	## environment, which no step could enter together.
	supplier : Spec, List(Provider), Str, List(Str) -> Try(Provider, Str)
	supplier = |project, providers, environment, source_names| {
		var $found = []
		for name in Project.unique(source_names) {
			source = project.sources.find_first(|s| s.name == name).map_err(|_| Project.unknown_source(project.sources, name))?
			match providers.keep_if(|candidate| candidate.name == source.provider.name and (candidate.realises)(source.provider)) {
				[provider] => {
					_ = (provider.validate_source)(source.provider)?
					if !$found.any(|known| known.name == provider.name) {
						$found = $found.append(provider)
					}
				}
				[] => return Err("environment ${environment} takes tools from the source ${name} (${source_kind(source.provider)}), which no provider of this blueprint supplies")
				_ => return Err("source ${name} provider is registered more than once: ${source.provider.name}")
			}
		}
		match $found {
			[one] => Ok(one)
			[] => Err("environment ${environment} names no package source")
			_ => Err("environment ${environment} takes tools from sources of several providers: ${Str.join_with($found.map(|provider| provider.name), ", ")}")
		}
	}

	## The sources a project declares, for the end of a message.
	declared : Spec -> Str
	declared = |project|
		if (project.sources.is_empty()) "" else " (it declares ${Str.join_with(project.sources.map(|source| "${source.name}, ${source_kind(source.provider)}"), "; ")})"

	source_kind : Spec.Provider -> Str
	source_kind = |provider| "${provider.name} v${provider.version.to_str()}"

	## What the Core supplies for an environment, as operations in the order
	## an executor needs them: what the machine lacks is known before
	## anything is downloaded. A program that cannot be supplied is a
	## problem, never a missing operation.
	supply : Str, Str, Project.Use, Str, Authority -> { operations : List(Steps.Operation), problems : List(Str) }
	supply = |subject, environment, use, system, authority| {
		var $problems = use.unavailable.map(|name| "${subject}: program ${name} is not available for ${system} (its recipe answers Unavailable)")
		var $programs = []
		# Without a Lock there is no digest to give, and nothing to say yet.
		resolved = match authority {
			Read(lock) => use.programs.map(|program| (program, lock.fetched_for(program)))
			Unread => []
		}
		for (program, recorded) in resolved {
			match recorded {
				Ok(entry) =>
					if digest(entry.sha256) {
						$programs = $programs.append({ name: program.name, urls: program.urls, sha256: entry.sha256, size: entry.size, unpack: program.unpack, path: program.path })
					} else {
						$problems = $problems.append("${program.name} for ${system}: Blueprint.lock holds no SHA-256 for it; run blueprint update ${program.name}")
					}

				Err(NotLocked) => {
					$problems = $problems.append("${program.name} for ${system} is not in Blueprint.lock; run blueprint update")
				}
				Err(UrlsChanged(locked)) => {
					$problems = $problems.append("${program.name} for ${system}: Blueprint.roc now names ${Str.join_with(program.urls, ", ")}, the lock ${Str.join_with(locked, ", ")}; run blueprint update ${program.name}")
				}
			}
		}
		present = use.expects.map(|program| { program, because: "environment ${environment} expects it on PATH (Expect)" })
		{
			operations: (if (present.is_empty()) [] else [Present(present)])
				.concat(if ($programs.is_empty()) [] else [Programs($programs)])
				.concat(if (use.bundles.is_empty()) [] else [RocBundles(use.bundles)]),
			problems: $problems,
		}
	}

	## A SHA-256 in hex, as the Lock writes one.
	digest : Str -> Bool
	digest = |text| text.to_utf8().len() == 64 and text.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))

	## A provider's step with what the Core supplies ahead of its own
	## operations: the same, Roc packages included, as for an environment no
	## provider enters.
	with_supplied : Steps.Step, List(Steps.Operation) -> Steps.Step
	with_supplied = |step, operations| { ..step, operations: operations.concat(step.operations) }

	## The command every Roc script names on its first line,
	## `#!/usr/bin/env roc-stable`.
	script_command : Str
	script_command = "roc-stable"

	## The argv that starts a task the Core runs itself. Windows does not read
	## a script's first line, so there a Roc script is started as the line
	## asks: by `roc-stable`, which the environment must fetch, with the
	## script and then its arguments. Elsewhere the system reads the line. A
	## program named by a relative path is in the project, whatever directory
	## the caller is in. A shell has no argv.
	started : Entry, Project.Use, Str, Layout -> Try(List(Str), Str)
	started = |entry, use, system, layout|
		match entry.argv {
			[program, .. as rest] =>
				if system.ends_with("-windows") and program.ends_with(".roc") {
					if use.programs.any(|fetched| fetched.name == script_command) {
						Ok([script_command].concat(entry.argv))
					} else {
						Err("${entry.subject} runs the Roc script ${program}, which ${script_command} starts; give environment ${entry.environment} that program, as in Programs([Fetch(\"${script_command}\", Recipes.roc_nightly(\"<tag>\"))])")
					}
				} else {
					Ok([in_project(program, system, layout)].concat(rest))
				}

			[] => Ok([])
		}

	## A program as the process API finds it. A bare name is left to PATH and
	## an absolute path is itself; a relative path is taken from the project
	## root, where a task runs.
	in_project : Str, Str, Layout -> Str
	in_project = |program, system, layout| {
		text = if (system.ends_with("-windows")) program.replace_each("\\", "/") else program
		if !text.contains("/") or absolute(text) {
			program
		} else {
			root = if (layout.project_root.ends_with("/")) layout.project_root.drop_suffix("/") else layout.project_root
			parts = text.split_on("/").fold(
				root.split_on("/"),
				|kept, part|
					match part {
						"" | "." => kept
						".." => if (kept.len() > 1) kept.drop_last(1) else kept
						_ => kept.append(part)
					},
			)
			if (parts.len() == 1) "${Str.join_with(parts, "/")}/" else Str.join_with(parts, "/")
		}
	}

	## `Layout.validate` knows POSIX paths alone, and a Windows layout starts
	## at a drive (`D:/a/project`). The caller normalizes every path first;
	## this refuses text a plan could not carry. A provider checks the layout
	## again for what it stages.
	check_layout : Layout -> Try({}, Str)
	check_layout = |layout| {
		for path in [layout.project_root, layout.workspace, layout.generated_root, layout.lock_path] {
			if !absolute(path) or path.to_utf8().any(|b| b < 32 or b == 127 or b == '\\' or b == '"') or path.split_on("/").drop_first(1).any(|part| part == "." or part == "..") {
				return Err("layout paths must be normalized absolute paths")
			}
		}
		Ok({})
	}

	absolute : Str -> Bool
	absolute = |path|
		match path.to_utf8() {
			['/', ..] => True
			[letter, ':', '/', ..] => (letter >= 'a' and letter <= 'z') or (letter >= 'A' and letter <= 'Z')
			_ => False
		}

	## What one task needs on a System, by who supplies it: the providers
	## that must be installed, their tools as Blueprint.roc writes them, the
	## fetched programs, those the System has none of, the programs the
	## machine must have, and how many Roc packages.
	Requirement : {
		task : Str,
		environment : Str,
		providers : List(Str),
		tools : List(Str),
		programs : List(Str),
		unavailable : List(Str),
		expects : List(Str),
		roc_packages : U64,
	}

	## The tasks asked about, with every provider and expected program any of
	## them needs, each once in first-use order. `providers` names a provider
	## exactly when one of these tasks has, in its environment on the System,
	## a tool from a package source that provider supplies: it is what must
	## be on the machine to run them. A source that is declared and that none
	## of these tasks uses does not put its provider there, and neither does
	## what is not a task: a shell, a build, or resolving the Lock.
	Requirements : { system : Str, providers : List(Str), expects : List(Str), tasks : List(Requirement) }

	## What the named tasks need on a System, or every task when none is
	## named. It reads the Spec alone: not the Lock, PATH or any store, so it
	## can be asked before anything is installed.
	requirements : Spec, Str, List(Str), List(Provider) -> Try(Requirements, List(Str))
	requirements = |spec, system, names, providers| {
		project = Project.validate(spec).map_err(|message| [message])?
		if !project.systems.contains(system) {
			return Err(["target ${system} is not declared by the project"])
		}
		chosen = if (names.is_empty()) project.tasks.map(|task| task.name) else names
		var $tasks = []
		var $problems = []
		for name in chosen {
			match project.tasks.find_first(|task| task.name == name) {
				Ok(task) =>
					match requirement(project, task, system, providers) {
						Ok(entry) => {
							$tasks = $tasks.append(entry)
						}
						Err(problem) => {
							$problems = $problems.append(problem)
						}
					}

				Err(_) => {
					$problems = $problems.append("unknown task: ${name}")
				}
			}
		}
		if !$problems.is_empty() {
			return Err(Project.unique($problems))
		}
		Ok({
			system,
			providers: Project.unique($tasks.fold([], |all, entry| all.concat(entry.providers))),
			expects: Project.unique($tasks.fold([], |all, entry| all.concat(entry.expects))),
			tasks: $tasks,
		})
	}

	requirement : Spec, Spec.Task, Str, List(Provider) -> Try(Requirement, Str)
	requirement = |project, task, system, providers| {
		use = Project.environment_use(project, task.environment, system)?
		needed = if use.tools.is_empty() {
			[]
		} else {
			[supplier(project, providers, task.environment, use.tools.map(|tool| tool.source))?.name]
		}
		Ok({
			task: task.name,
			environment: task.environment,
			providers: needed,
			tools: use.tools.map(|tool| "${tool.source}#${tool.name}"),
			programs: use.programs.map(|program| program.name),
			unavailable: use.unavailable,
			expects: use.expects,
			roc_packages: use.bundles.len(),
		})
	}
}

## A provider that supplies Nix package sources and answers every
## request with one step naming it, so that a plan shows what it was asked.
## It refuses the task `broken`, as a provider refuses what it cannot render.
stub : Provider
stub = Provider.{
	migrate_lock: |lock| Ok(lock),
	validate_source: |_source| Ok({}),
	validate_tool: |_name| Ok({}),
	name: "nix",
	features: [],
	realises: |source| source.name == "nix" and source.version == 1,
	build_argv: |step, _options| Ok(step.argv),
	build_prepare_argv: |step| Ok(step.argv),
	build_prepared: |_text| Err("not prepared here"),
	build_execute_argv: |step, _prepared, _options| Ok(step.argv),
	build_result: |_text| Err("not built here"),
	build_sources: |_spec, _name| Ok([]),
	render: |_spec| Ok([]),
	inspect_lock: |_lock| Ok([]),
	preflight: |spec, request, _system, _layout| match request {
		Request.Build(name) => {
			closure = Project.build_closure(spec, name)?
			for build in closure {
				if !spec.environment_programs.keep_if(|entry| entry.environment == build.environment).is_empty() {
					return Err("fixture executor rejects downloaded tools")
				}
			}
			Ok({})
		}
		_ => Ok({})
	},
	realise: |_spec, request, system, layout, _lock|
		match request {
			Request.Run("broken", _) => Err(Unrealisable("unsupported Nix target riscv64-linux"))
			Request.Run("unpinned", _) => Err(InvalidLock("the lock has no nix hint"))
			Request.Run(name, extra) => Ok(Steps.{ steps: [provided(Run(name), ["nix", "develop", "${layout.generated_root}#${system}.${name}", "--command"].concat(extra), layout, [VerifyTree({ path: "/project/assets", digest: "sha256:00" })])] })
			Request.Shell(name) => Ok(Steps.{ steps: [provided(Shell(name), ["nix", "develop", "${layout.generated_root}#${system}.${name}"], layout, [])] })
			Request.Build(name) => Ok(Steps.{ steps: [provided(Build(name), ["nix", "build", name], layout, [])] })
			Request.Generate => Ok(Steps.{ steps: [provided(Generate, [], layout, [])] })
			Request.Workflow(_) => Err(Unrealisable("workflow must expand into atomic requests"))
		},
	resolve: |_spec, _system, _layout, _update| Err("not resolved here"),
	lock_from_native: |_spec, _layout, _text, _trees| Err("not resolved here"),
}

provided : [Generate, Shell(Str), Run(Str), Build(Str)], List(Str), Layout, List(Steps.Operation) -> Steps.Step
provided = |action, argv, layout, operations| { action, files: [{ path: "${layout.generated_root}/flake.nix", contents: "{ }" }], argv, artifacts: [], operations }

unix : Layout
unix = Layout.{ project_root: "/project", workspace: "/project/.blueprint", generated_root: "/project/.blueprint", lock_path: "/project/Blueprint.lock" }

windows : Layout
windows = Layout.{ project_root: "D:/a/project", workspace: "D:/a/project/.blueprint", generated_root: "D:/a/project/.blueprint", lock_path: "D:/a/project/Blueprint.lock" }

roc_urls : Str -> List(Str)
roc_urls = |system| ["https://example.test/roc-${system}.tar.gz", "https://mirror.example.test/roc-${system}.tar.gz"]

roc_sha : Str
roc_sha = "893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f"

tool_sha : Str
tool_sha = "2c083762ce177e407730eaa41a8257631969341716950252df3c9fefd2b070aa"

## `roc-stable` for three Systems and `tool` for Linux alone; environments
## that fetch, expect, take package tools, or do several of these.
sample : Spec
sample = {
	..Spec.empty("sample"),
	resolvers: [{ provider: "nix", inputs: ["roc-abc"] }],
	executors: [{ name: "native", provider: "nix", source: "nix" }],
	build_executors: ["library", "app", "fetched"].map(|build| { build, executor: "native" }),
	systems: ["x86_64-linux", "aarch64-darwin", "x86_64-windows"],
	requires_: ["programs", "expects", "roc-packages", "sources", "builds", "workflows"],
	sources: [{ name: "guix", provider: { name: "guix", version: 1, ref: "https://git.savannah.gnu.org/git/guix.git" } }, { name: "nix", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-unstable" } }],
	programs: [
		{ name: "roc-stable", system: "x86_64-linux", urls: roc_urls("x86_64-linux"), unpack: TarGz, path: "roc/roc" },
		{ name: "roc-stable", system: "aarch64-darwin", urls: roc_urls("aarch64-darwin"), unpack: TarGz, path: "roc/roc" },
		{ name: "roc-stable", system: "x86_64-windows", urls: ["https://example.test/roc-windows.zip"], unpack: Zip, path: "roc/roc.exe" },
		{ name: "tool", system: "x86_64-linux", urls: ["https://example.test/tool-x86_64-linux"], unpack: File, path: "" },
	],
	environments: [
		{ name: "plain", parents: [], tools: [], overlays: [] },
		{ name: "scripts", parents: ["plain"], tools: [], overlays: [] },
		{ name: "dev", parents: ["scripts"], tools: [], overlays: [] },
		{ name: "host", parents: ["dev"], tools: [{ source: "nix", name: "zig" }], overlays: [] },
		{ name: "builder", parents: [], tools: [{ source: "nix", name: "coreutils" }], overlays: [] },
		{ name: "foreign", parents: [], tools: [{ source: "guix", name: "git" }], overlays: [] },
	],
	environment_programs: [{ environment: "scripts", programs: ["roc-stable"] }, { environment: "dev", programs: ["tool"] }],
	expects: [{ environment: "dev", programs: ["gh", "git"] }],
	build_sources: [{ name: "roc-abc", ref: "tarball+https://example.test/releases/1.0/abc.tar.zst" }],
	roc_packages: [{ environment: "scripts", name: "abc", source: "roc-abc" }],
	shells: [{ name: "default", environment: "dev" }, { name: "plain", environment: "plain" }, { name: "host", environment: "host" }],
	tasks: [
		{ name: "hello", environment: "plain", run: ["hello", "configured"] },
		{ name: "local", environment: "plain", run: ["tools/report", "roc-stable"] },
		{ name: "script", environment: "scripts", run: ["scripts/check_all.roc", "--quick"] },
		{ name: "bare", environment: "plain", run: ["scripts/check_all.roc"] },
		{ name: "check", environment: "dev", run: ["roc-stable", "version"] },
		{ name: "host", environment: "host", run: ["zig", "build"] },
		{ name: "broken", environment: "host", run: ["zig", "build"] },
		{ name: "unpinned", environment: "builder", run: ["true"] },
		{ name: "foreign", environment: "foreign", run: ["git", "status"] },
	],
	builds: [
		{ name: "library", environment: "builder", inputs: [], needs: [], run: ["cp", "a", "b"], output: "b" },
		{ name: "app", environment: "builder", inputs: [], needs: ["library"], run: ["cp", "b", "c"], output: "c" },
		{ name: "fetched", environment: "scripts", inputs: [], needs: ["library"], run: ["roc-stable", "build"], output: "app" },
	],
	workflows: [
		{ name: "ci", steps: [RunTask("hello", []), RunTask("check", ["--verbose"]), BuildArtifact("app"), RunTask("hello", []), RunTask("host", [])] },
		{ name: "doomed", steps: [RunTask("check", []), RunTask("foreign", []), RunTask("broken", []), BuildArtifact("fetched"), RunTask("check", [])] },
		{ name: "empty", steps: [] },
	],
}

## A Lock that has resolved every program of `sample`.
locked : Lock
locked = Lock.{
	format: Lock.current_format,
	intent: Lock.intent_of(sample),
	sources: [],
	hints: [],
	fetched: [
		{ name: "roc-stable", system: "x86_64-linux", urls: roc_urls("x86_64-linux"), sha256: roc_sha, size: 69614310, obtained: Both },
		{ name: "roc-stable", system: "aarch64-darwin", urls: roc_urls("aarch64-darwin"), sha256: roc_sha, size: 66810227, obtained: Published },
		{ name: "roc-stable", system: "x86_64-windows", urls: ["https://example.test/roc-windows.zip"], sha256: roc_sha, size: 67310620, obtained: Published },
		{ name: "tool", system: "x86_64-linux", urls: ["https://example.test/tool-x86_64-linux"], sha256: tool_sha, size: 5900520, obtained: Computed },
	],
}

## A plan's steps: `Steps` itself has no equality.
planned : Spec, Request, Str, Layout, Lock -> Try(List(Steps.Step), List(Str))
planned = |spec, request, system, layout, lock| Realise.plan(spec, request, system, layout, lock, [stub]).map_ok(|steps| steps.steps)

linux_roc : Steps.Program
linux_roc = { name: "roc-stable", urls: roc_urls("x86_64-linux"), sha256: roc_sha, size: 69614310, unpack: TarGz, path: "roc/roc" }

bundle : Steps.Operation
bundle = RocBundles([{ name: "abc", url: "https://example.test/releases/1.0/abc.tar.zst" }])

## What the Core supplies on Linux for `dev`, or for `host`, which inherits
## it all: an inherited expectation is the inheriting environment's own.
supplied_for : Str -> List(Steps.Operation)
supplied_for = |environment| [
	Present([{ program: "gh", because: "environment ${environment} expects it on PATH (Expect)" }, { program: "git", because: "environment ${environment} expects it on PATH (Expect)" }]),
	Programs([linux_roc, { name: "tool", urls: ["https://example.test/tool-x86_64-linux"], sha256: tool_sha, size: 5900520, unpack: File, path: "" }]),
	bundle,
]

# A task with nothing to supply is its argv, with the caller's arguments last,
# and no provider is asked: none is needed on the machine.
expect planned(sample, Request.Run("hello", ["extra"]), "x86_64-linux", unix, locked) == Ok([{ action: Run("hello"), files: [], argv: ["hello", "configured", "extra"], artifacts: [], operations: [] }])
expect Realise.plan(sample, Request.Run("hello", []), "x86_64-linux", unix, locked, []).map_ok(|steps| steps.steps.len()) == Ok(1)

# What the Core supplies comes first and in the order an executor needs: the
# machine's own programs are checked before anything is downloaded, programs
# carry every URL in order with the Lock's digest and length, and inherited
# ones lead.
expect planned(sample, Request.Run("check", ["--verbose"]), "x86_64-linux", unix, locked) == Ok([{ action: Run("check"), files: [], argv: ["roc-stable", "version", "--verbose"], artifacts: [], operations: supplied_for("dev") }])

# Elsewhere the program is that System's download; a script is left to its
# first line, and a path in the project is named from the project root.
expect planned(sample, Request.Run("script", ["extra"]), "aarch64-darwin", unix, locked) == Ok([
	{
		action: Run("script"),
		files: [],
		argv: ["/project/scripts/check_all.roc", "--quick", "extra"],
		artifacts: [],
		operations: [Programs([{ name: "roc-stable", urls: roc_urls("aarch64-darwin"), sha256: roc_sha, size: 66810227, unpack: TarGz, path: "roc/roc" }]), bundle],
	},
])

# Windows does not read a script's first line: roc-stable starts it, with the
# script's own path and then its arguments.
expect planned(sample, Request.Run("script", ["extra"]), "x86_64-windows", windows, locked) == Ok([
	{
		action: Run("script"),
		files: [],
		argv: ["roc-stable", "scripts/check_all.roc", "--quick", "extra"],
		artifacts: [],
		operations: [Programs([{ name: "roc-stable", urls: ["https://example.test/roc-windows.zip"], sha256: roc_sha, size: 67310620, unpack: Zip, path: "roc/roc.exe" }]), bundle],
	},
])

# Without the program there is nothing to start the script with, there alone.
expect planned(sample, Request.Run("bare", []), "x86_64-windows", windows, locked) == Err(["task bare runs the Roc script scripts/check_all.roc, which roc-stable starts; give environment plain that program, as in Programs([Fetch(\"roc-stable\", Recipes.roc_nightly(\"<tag>\"))])"])
expect planned(sample, Request.Run("bare", []), "x86_64-linux", unix, locked).map_ok(|steps| steps.map(|step| step.argv)) == Ok([["/project/scripts/check_all.roc"]])

# A program in the project is named in full, in either Windows spelling; only
# the program a task starts is rewritten, never an argument.
expect planned(sample, Request.Run("local", []), "x86_64-windows", windows, locked).map_ok(|steps| steps.map(|step| step.argv)) == Ok([["D:/a/project/tools/report", "roc-stable"]])
expect Realise.in_project("./tools/../bin/report", "x86_64-linux", unix) == "/project/bin/report"
expect Realise.in_project("../shared/report", "x86_64-windows", windows) == "D:/a/shared/report"
expect Realise.in_project("../../../report.exe", "x86_64-windows", windows) == "D:/report.exe"
expect Realise.in_project("tools\\report", "x86_64-linux", unix) == "tools\\report"
expect Realise.in_project("tools\\report", "x86_64-windows", windows) == "D:/a/project/tools/report"
expect ["report", "/usr/bin/report", "C:/tools/report.exe", "C:\\tools\\report.exe"].all(|program| Realise.in_project(program, "x86_64-windows", windows) == program)

# A provider is asked only for an environment that has one of its tools. Its
# step is kept as it is, after what the Core supplies for the same environment.
expect planned(sample, Request.Run("host", ["-Doptimize"]), "x86_64-linux", unix, locked) == Ok([
	{
		action: Run("host"),
		files: [{ path: "/project/.blueprint/flake.nix", contents: "{ }" }],
		argv: ["nix", "develop", "/project/.blueprint#x86_64-linux.host", "--command", "-Doptimize"],
		artifacts: [],
		operations: supplied_for("host").concat([VerifyTree({ path: "/project/assets", digest: "sha256:00" })]),
	},
])

# A shell is planned as a task is. With no package tool it has no argv: the
# executor starts the caller's own shell with what was supplied.
expect planned(sample, Request.Shell("default"), "x86_64-linux", unix, locked) == Ok([{ action: Shell("default"), files: [], argv: [], artifacts: [], operations: supplied_for("dev") }])
expect planned(sample, Request.Shell("plain"), "x86_64-linux", unix, locked) == Ok([{ action: Shell("plain"), files: [], argv: [], artifacts: [], operations: [] }])
expect planned(sample, Request.Shell("host"), "x86_64-linux", unix, locked).map_ok(|steps| steps.map(|step| (step.argv, step.operations))) == Ok([(["nix", "develop", "/project/.blueprint#x86_64-linux.host"], supplied_for("host"))])

# A build is the provider's whole, even when its environment has no tool:
# its sandbox is then that of the first declared source a provider supplies,
# here the second declared. A project with no such source cannot build, and
# is told what to declare, with what it does declare.
expect planned(sample, Request.Build("app"), "x86_64-linux", unix, locked) == Ok([{ action: Build("app"), files: [{ path: "/project/.blueprint/flake.nix", contents: "{ }" }], argv: ["nix", "build", "app"], artifacts: [], operations: [] }])
expect {
	bare = { ..sample, resolvers: [], workflows: [], tasks: [], shells: [], environments: sample.environments.keep_if(|environment| environment.tools.is_empty()), build_executors: [{ build: "bare", executor: "native" }], builds: [{ name: "bare", environment: "plain", inputs: [], needs: [], run: ["true"], output: "out" }] }
	planned(bare, Request.Build("bare"), "x86_64-linux", unix, locked).map_ok(|steps| steps.map(|step| step.argv)) == Ok([["nix", "build", "bare"]])
		and planned({ ..bare, sources: [] }, Request.Build("bare"), "x86_64-linux", unix, locked) == Err(["executor native bootstrap source nix is not owned by nix"])
		and planned({ ..bare, sources: sample.sources.take_first(1) }, Request.Build("bare"), "x86_64-linux", unix, locked) == Err(["executor native bootstrap source nix is not owned by nix"])
}

# A sandbox holds nothing of the machine, so a build whose own environment
# fetches or expects is refused; one that only depends on such a build is too.
expect planned(sample, Request.Build("fetched"), "x86_64-linux", unix, locked) == Err(["fixture executor rejects downloaded tools"])
expect {
	needing = { ..sample, build_executors: sample.build_executors.append({ build: "outer", executor: "native" }), builds: sample.builds.append({ name: "outer", environment: "builder", inputs: [], needs: ["fetched"], run: ["true"], output: "out" }) }
	planned(needing, Request.Build("outer"), "x86_64-linux", unix, locked) == Err(["fixture executor rejects downloaded tools"])
}

# Only a provider generates files, and only one that supplies a declared
# source: a project that declares none, or only another provider's, has
# nothing generated for it.
expect planned(sample, Request.Generate, "x86_64-linux", unix, locked) == Ok([{ action: Generate, files: [{ path: "/project/.blueprint/flake.nix", contents: "{ }" }], argv: [], artifacts: [], operations: [] }])
expect Realise.plan(sample, Request.Generate, "x86_64-linux", unix, locked, []).map_ok(|steps| steps.steps) == Ok([])
expect {
	fetching = { ..sample, executors: [], environments: sample.environments.keep_if(|environment| environment.tools.is_empty()), shells: [], tasks: [], builds: [], build_executors: [], resolvers: [], workflows: [] }
	planned({ ..fetching, sources: [] }, Request.Generate, "x86_64-linux", unix, locked) == Ok([])
		and planned({ ..fetching, sources: [{ name: "channel", provider: { name: "guix", version: 1, ref: "https://example.test/guix.git" } }] }, Request.Generate, "x86_64-linux", unix, locked) == Ok([])
		and planned(fetching, Request.Generate, "x86_64-linux", unix, locked).map_ok(|steps| steps.len()) == Ok(1)
}

# A workflow is its tasks and builds in order, each planned once and repeated
# whole; a step is the same in a workflow as alone.
expect {
	hello = planned(sample, Request.Run("hello", []), "x86_64-linux", unix, locked)?
	check = planned(sample, Request.Run("check", ["--verbose"]), "x86_64-linux", unix, locked)?
	artifact = planned(sample, Request.Build("app"), "x86_64-linux", unix, locked)?
	host = planned(sample, Request.Run("host", []), "x86_64-linux", unix, locked)?
	planned(sample, Request.Workflow("ci"), "x86_64-linux", unix, locked) == Ok(hello.concat(check).concat(artifact).concat(hello).concat(host))
		and planned(sample, Request.Workflow("empty"), "x86_64-linux", unix, locked) == Ok([])
}

# Everything that stops a workflow is reported together and once, before any
# step exists: an unavailable program, a source no provider supplies, what
# the Core cannot supply and what the provider refuses for one task, and a
# build that cannot have its programs. The repeated task adds nothing.
expect planned(sample, Request.Workflow("doomed"), "aarch64-darwin", unix, locked) == Err([
	"task check: program tool is not available for aarch64-darwin (its recipe answers Unavailable)",
	"environment foreign takes tools from the source guix (guix v1), which no provider of this blueprint supplies",
	"task broken: program tool is not available for aarch64-darwin (its recipe answers Unavailable)",
	"unsupported Nix target riscv64-linux",
	"fixture executor rejects downloaded tools",
])

# A provider's own refusal, of the request or of the Lock, is the plan's.
expect planned(sample, Request.Run("unpinned", []), "x86_64-linux", unix, locked) == Err(["the lock has no nix hint"])
expect planned(sample, Request.Run("foreign", []), "x86_64-linux", unix, locked) == Err(["environment foreign takes tools from the source guix (guix v1), which no provider of this blueprint supplies"])
expect Realise.plan(sample, Request.Run("host", []), "x86_64-linux", unix, locked, []).map_ok(|steps| steps.steps) == Err(["environment host takes tools from the source nix (nix v1), which no provider of this blueprint supplies"])

# An environment cannot be entered by two providers at once.
expect {
	guix = {
		..stub,
		name: "guix",
		realises: |source|
			match source {
				{ name: "guix", version: 1, ref: _ } => True
				_ => False
			},
	}
	mixed = { ..sample, environments: sample.environments.append({ name: "mixed", parents: ["foreign"], tools: [{ source: "nix", name: "zig" }], overlays: [] }), tasks: sample.tasks.append({ name: "mixed", environment: "mixed", run: ["true"] }) }
	Realise.plan(mixed, Request.Run("mixed", []), "x86_64-linux", unix, locked, [stub, guix]).map_ok(|steps| steps.steps.len()) == Err(["environment mixed takes tools from sources of several providers: guix, nix"])
		and Realise.plan(mixed, Request.Run("foreign", []), "x86_64-linux", unix, locked, [stub, guix]).map_ok(|steps| steps.steps.len()) == Ok(1)
}

# A program the Lock has not resolved, or resolved from other URLs, is named
# with the command that resolves it; every such program is, in one answer.
expect {
	stale = { ..locked, fetched: [{ name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/older.tar.gz"], sha256: roc_sha, size: 1, obtained: Computed }] }
	planned(sample, Request.Run("check", []), "x86_64-linux", unix, stale) == Err([
		"roc-stable for x86_64-linux: Blueprint.roc now names https://example.test/roc-x86_64-linux.tar.gz, https://mirror.example.test/roc-x86_64-linux.tar.gz, the lock https://example.test/older.tar.gz; run blueprint update roc-stable",
		"tool for x86_64-linux is not in Blueprint.lock; run blueprint update",
	])
		and planned(sample, Request.Run("check", []), "x86_64-linux", unix, { ..locked, fetched: [] }) == Err(["roc-stable for x86_64-linux is not in Blueprint.lock; run blueprint update", "tool for x86_64-linux is not in Blueprint.lock; run blueprint update"])
		# Another System's entry is not this one's.
		and planned(sample, Request.Run("script", []), "aarch64-darwin", unix, stale) == Err(["roc-stable for aarch64-darwin is not in Blueprint.lock; run blueprint update"])
		# A task that fetches nothing does not read them.
		and planned(sample, Request.Run("hello", []), "x86_64-linux", unix, { ..locked, fetched: [] }).is_ok()
}

# A digest that is not one is never handed to an executor to compare with.
expect
	["", "893c86d2", "sha256:${roc_sha}", roc_sha.replace_each("8", "G"), "${roc_sha}00"].all(
		|sha256| planned(sample, Request.Run("script", []), "aarch64-darwin", unix, { ..locked, fetched: [{ name: "roc-stable", system: "aarch64-darwin", urls: roc_urls("aarch64-darwin"), sha256, size: 1, obtained: Computed }] }) == Err(["roc-stable for aarch64-darwin: Blueprint.lock holds no SHA-256 for it; run blueprint update roc-stable"]),
	)

# The request is refused whole before planning: an invalid project, a System
# the project does not declare, an unknown name, a layout no plan can carry.
expect planned({ ..sample, requires_: [] }, Request.Run("hello", []), "x86_64-linux", unix, locked) == Err(["build sources require feature: sources"])
expect planned(sample, Request.Run("hello", []), "riscv64-linux", unix, locked) == Err(["target riscv64-linux is not declared by the project"])
expect planned(sample, Request.Run("absent", []), "x86_64-linux", unix, locked) == Err(["unknown task: absent"])
expect planned(sample, Request.Shell("absent"), "x86_64-linux", unix, locked) == Err(["unknown shell: absent"])
expect planned(sample, Request.Build("absent"), "x86_64-linux", unix, locked) == Err(["unknown build: absent"])
expect planned(sample, Request.Workflow("absent"), "x86_64-linux", unix, locked) == Err(["unknown workflow: absent"])
expect planned(sample, Request.Run("hello", [Str.from_utf8([0]) ?? ""]), "x86_64-linux", unix, locked) == Err(["NUL in argv: hello"])
expect
	["project", "D:project", "D:\\a\\project", "D:/a/../project", "D:/a/\"project"].all(
		|root| planned(sample, Request.Run("hello", []), "x86_64-windows", { ..windows, project_root: root }, locked) == Err(["layout paths must be normalized absolute paths"]),
	)

# A workflow's distinct requests share one allowance of text; a repeated
# request is counted once, and a request on its own is not limited.
expect {
	once = Realise.plan_within(sample, Request.Workflow("ci"), "x86_64-linux", unix, Read(locked), [stub], 200).map_ok(|steps| steps.steps.len())
	once == Ok(5)
		and Realise.plan_within(sample, Request.Workflow("ci"), "x86_64-linux", unix, Read(locked), [stub], 100).map_ok(|steps| steps.steps.len()) == Err(["workflow plan exceeds 16 MiB of distinct rendered requests"])
		and Realise.plan_within(sample, Request.Run("host", []), "x86_64-linux", unix, Read(locked), [stub], 1).is_ok()
}

# What tasks need is read from the Spec alone, per System and per task: the
# provider to install, its tools as they are written, and what is fetched,
# missing there, or expected of the machine.
expect Realise.requirements(sample, "x86_64-linux", ["check", "host", "hello"], [stub]) == Ok({
	system: "x86_64-linux",
	providers: ["nix"],
	expects: ["gh", "git"],
	tasks: [
		{ task: "check", environment: "dev", providers: [], tools: [], programs: ["roc-stable", "tool"], unavailable: [], expects: ["gh", "git"], roc_packages: 1 },
		{ task: "host", environment: "host", providers: ["nix"], tools: ["nix#zig"], programs: ["roc-stable", "tool"], unavailable: [], expects: ["gh", "git"], roc_packages: 1 },
		{ task: "hello", environment: "plain", providers: [], tools: [], programs: [], unavailable: [], expects: [], roc_packages: 0 },
	],
})

# A project whose tasks need no provider says so, and a program a System has
# none of is shown, not hidden.
expect Realise.requirements(sample, "aarch64-darwin", ["check", "script"], [stub]) == Ok({
	system: "aarch64-darwin",
	providers: [],
	expects: ["gh", "git"],
	tasks: [
		{ task: "check", environment: "dev", providers: [], tools: [], programs: ["roc-stable"], unavailable: ["tool"], expects: ["gh", "git"], roc_packages: 1 },
		{ task: "script", environment: "scripts", providers: [], tools: [], programs: ["roc-stable"], unavailable: [], expects: [], roc_packages: 1 },
	],
})

# With no task named it answers for every task, and so meets the one whose
# source nothing supplies; unknown names are all reported.
expect Realise.requirements({ ..sample, workflows: [], tasks: sample.tasks.keep_if(|task| task.name != "foreign") }, "x86_64-linux", [], [stub]).map_ok(|needs| (needs.providers, needs.tasks.map(|entry| entry.task))) == Ok((["nix"], ["hello", "local", "script", "bare", "check", "host", "broken", "unpinned"]))
expect Realise.requirements(sample, "x86_64-linux", [], [stub]) == Err(["environment foreign takes tools from the source guix (guix v1), which no provider of this blueprint supplies"])
expect Realise.requirements(sample, "x86_64-linux", ["absent", "hello", "gone"], [stub]) == Err(["unknown task: absent", "unknown task: gone"])
expect Realise.requirements(sample, "riscv64-linux", [], [stub]) == Err(["target riscv64-linux is not declared by the project"])
expect Realise.requirements(sample, "x86_64-linux", ["unpinned"], [stub]).map_ok(|needs| needs.tasks.map(|entry| entry.tools)) == Ok([["nix#coreutils"]])

expect Realise.features == ["explicit-sources", "source-files", "programs", "expects"]

# Before a Lock is read, a request is refused for whatever the Spec alone
# shows, the provider's own refusal included, and for nothing the Lock says.
expect Realise.preflight(sample, Request.Run("check", []), "x86_64-linux", unix, [stub]) == Ok({})
expect Realise.preflight(sample, Request.Workflow("ci"), "x86_64-linux", unix, [stub]) == Ok({})
expect Realise.preflight(sample, Request.Run("unpinned", []), "x86_64-linux", unix, [stub]) == Ok({})
expect Realise.preflight(sample, Request.Run("absent", []), "x86_64-linux", unix, [stub]) == Err(["unknown task: absent"])
expect Realise.preflight(sample, Request.Run("foreign", []), "x86_64-linux", unix, [stub]) == Err(["environment foreign takes tools from the source guix (guix v1), which no provider of this blueprint supplies"])
expect Realise.preflight(sample, Request.Run("check", []), "aarch64-darwin", unix, [stub]) == Err(["task check: program tool is not available for aarch64-darwin (its recipe answers Unavailable)"])
expect {
	refusing = { ..stub, preflight: |_spec, _request, _system, _layout| Err("unsupported Nix target riscv64-linux") }
	Realise.preflight(sample, Request.Run("host", []), "x86_64-linux", unix, [refusing]) == Err(["unsupported Nix target riscv64-linux"])
		# A provider is not asked about a request it has no part in.
		and Realise.preflight(sample, Request.Run("check", []), "x86_64-linux", unix, [refusing]) == Ok({})
}

# Resolve asks a provider only for what a provider resolves: a source it
# supplies, a flake input, or a build source that is not a task's own bundle.
# Programs, expected tools and the Roc packages of tasks ask none.
expect {
	names = |project| Realise.resolvers(project, [stub]).map(|provider| provider.name)
	fetching = { ..sample, executors: [], sources: [], environments: sample.environments.keep_if(|environment| environment.tools.is_empty()), shells: [], tasks: [], builds: [], build_executors: [], resolvers: [], workflows: [] }
	names(sample) == ["nix"]
		# `sample` has Roc packages, and with no build they are the Core's.
		and names(fetching) == []
		and names({ ..fetching, sources: [{ name: "channel", provider: { name: "guix", version: 1, ref: "https://example.test/guix.git" } }] }) == []
		and names({ ..fetching, sources: sample.sources }) == ["nix"]
		and names({ ..fetching, resolvers: [{ provider: "nix", inputs: ["roc"] }], inputs: [{ name: "roc", url: "github:roc-lang/roc-overlay", kind: Overlay }] }) == ["nix"]
		and names({ ..fetching, resolvers: [{ provider: "nix", inputs: ["assets"] }], build_sources: fetching.build_sources.append({ name: "assets", ref: "path:./assets" }) }) == ["nix"]
		# A build in an environment with a Roc package makes its bundle a provider's.
		and names({ ..fetching, resolvers: [{ provider: "nix", inputs: ["roc-abc"] }], builds: [{ name: "app", environment: "scripts", inputs: [], needs: [], run: ["true"], output: "out" }] }) == ["nix"]
		and Realise.resolvers(sample, []).is_empty()
}

expect Realise.unknown_names(["nope", "gone"], ["nix", "roc"], ["roc-stable"]) == "no input or program named nope, gone; Blueprint.roc declares the inputs nix, roc and the programs roc-stable"
expect Realise.unknown_names(["nope"], [], []) == "no input or program named nope; Blueprint.roc declares no input and no program"

# A provider is required by use, not by declaration. A project that declares
# a Nix source none of its tasks uses needs no provider to run them; one tool
# of that source in one task's environment requires it, for that task alone.
expect {
	declared = { ..sample, environments: sample.environments.keep_if(|environment| environment.tools.is_empty()), tasks: sample.tasks.keep_if(|task| ["hello", "script", "check"].contains(task.name)), shells: [], builds: [], build_executors: [], resolvers: [], workflows: [] }
	used = { ..declared, environments: declared.environments.append({ name: "host", parents: ["dev"], tools: [{ source: "nix", name: "zig" }], overlays: [] }), tasks: declared.tasks.append({ name: "host", environment: "host", run: ["zig", "build"] }) }
	declared.sources.any(|source| (stub.realises)(source.provider))
		and Realise.requirements(declared, "x86_64-linux", [], [stub]).map_ok(|needs| (needs.providers, needs.tasks.map(|entry| entry.providers))) == Ok(([], [[], [], []]))
		and Realise.requirements(used, "x86_64-linux", [], [stub]).map_ok(|needs| (needs.providers, needs.tasks.map(|entry| entry.providers))) == Ok((["nix"], [[], [], [], ["nix"]]))
		# Asked about the tasks that do not use it, the answer is still none.
		and Realise.requirements(used, "x86_64-linux", ["hello", "check"], [stub]).map_ok(|needs| needs.providers) == Ok([])
}

# A tool declared for one System requires its provider there and nowhere else.
expect {
	scoped = {
		..sample,
		requires_: sample.requires_.append("system-tools"),
		environments: [{ name: "plain", parents: [], tools: [], overlays: [] }],
		system_tools: [{ environment: "plain", system: "x86_64-linux", tools: [{ source: "nix", name: "wayland" }] }],
		environment_programs: [],
		expects: [],
		roc_packages: [],
		build_sources: [],
		shells: [],
		tasks: [{ name: "hello", environment: "plain", run: ["hello"] }],
		builds: [],
		build_executors: [],
		resolvers: [],
		workflows: [],
	}
	Realise.requirements(scoped, "x86_64-linux", [], [stub]).map_ok(|needs| (needs.providers, needs.tasks.map(|entry| entry.tools))) == Ok((["nix"], [["nix#wayland"]]))
		and Realise.requirements(scoped, "aarch64-darwin", [], [stub]).map_ok(|needs| (needs.providers, needs.tasks.map(|entry| entry.tools))) == Ok(([], [[]]))
}

# A tool-free executor has no package source. Registration order does not
# determine ownership, and another registered provider observes nothing.
expect {
	project = { ..Spec.empty("independent"), systems: ["x86_64-linux"], requires_: ["builds"], environments: [{ name: "empty", parents: [], tools: [], overlays: [] }], executors: [{ name: "native", provider: "fixture", source: "" }], build_executors: [{ build: "artifact", executor: "native" }], builds: [{ name: "artifact", environment: "empty", inputs: [], needs: [], run: ["produce"], output: "out" }] }
	executor = { ..stub, name: "fixture", preflight: |_spec, _request, _system, _layout| Ok({}) }
	unselected = { ..stub, name: "unused", preflight: |_spec, _request, _system, _layout| Err("must not be asked"), realise: |_spec, _request, _system, _layout, _lock| Err(Unrealisable("must not be asked")) }
	Realise.plan(project, Request.Build("artifact"), "x86_64-linux", unix, locked, [executor, unselected]).map_ok(|steps| steps.steps) == Realise.plan(project, Request.Build("artifact"), "x86_64-linux", unix, locked, [unselected, executor]).map_ok(|steps| steps.steps) and Realise.preflight(project, Request.Build("artifact"), "x86_64-linux", unix, [executor, unselected]) == Ok({}) and Realise.preflight({ ..project, build_executors: [] }, Request.Build("artifact"), "x86_64-linux", unix, [executor]) == Err(["build artifact has no executor; declare Execute"])
}

# Downloaded tools are an executor capability, never a blanket Core refusal.
expect {
	project = { ..Spec.empty("download-executor"), systems: ["x86_64-linux"], requires_: ["builds", "programs"], environments: [{ name: "download", parents: [], tools: [], overlays: [] }], programs: [sample.programs.first()?], environment_programs: [{ environment: "download", programs: ["roc-stable"] }], executors: [{ name: "verified", provider: "fixture", source: "" }], build_executors: [{ build: "artifact", executor: "verified" }], builds: [{ name: "artifact", environment: "download", inputs: [], needs: [], run: ["roc-stable", "build"], output: "out" }] }
	executor = { ..stub, name: "fixture", preflight: |_spec, _request, _system, _layout| Ok({}) }
	Realise.preflight(project, Request.Build("artifact"), "x86_64-linux", unix, [executor]) == Ok({}) and Realise.plan(project, Request.Build("artifact"), "x86_64-linux", unix, locked, [executor]).is_ok()
}

expect {
	project = { ..Spec.empty("owned"), systems: ["x86_64-linux"], requires_: ["sources"], build_sources: [{ name: "assets", ref: "path:./assets" }], resolvers: [{ provider: "fixture", inputs: ["assets"] }] }
	owner = { ..stub, name: "fixture" }
	Realise.resolvers(project, [stub, owner]).map(|provider| provider.name) == ["fixture"] and Realise.resolvers(project, [owner, stub]).map(|provider| provider.name) == ["fixture"] and Project.validate({ ..project, resolvers: [] }).is_err() and Project.validate({ ..project, resolvers: [{ provider: "fixture", inputs: ["assets"] }, { provider: "nix", inputs: ["assets"] }] }).is_err()
}
