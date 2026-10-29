# Pure Nix rendering for validated, reusable environment closures.
import core.Spec
import core.Project
import Native
import core.Value
import core.Request
import core.Layout
import core.Lock
import core.Steps
import core.Provider
import core.Realise
import core.JsonData
import core.Activation
import Locks
import LockJson
import Runner

## Package names are native Nix attributes, never translated or filtered.
## Each environment imports its sources with only its ordered overlay stack.
## Shell aliases and task entries share those imports. Raw values remain data,
## not executable Nix; Custom extensions are deliberately unsupported.
## Raw supports Attrs at `flake` and `shell:<alias>`, ignores other providers,
## and rejects duplicate attributes or replacement of packages/devShells.
## Alias Raw does not leak into another alias or a task's environment entry.
NixProvider :: [].{
	provider : Provider
	provider = Provider.{
		validate_source: validate_source,
		validate_tool: |name| Native.check_tool(Nix, name),
		validate_executor: Native.check_executor,
		validate_reference: Native.check_ref,
		activation_argv,
		activation,
		build_prepare_argv,
		build_prepared,
		build_execute_argv,
		build_result,
		build_inputs: direct_sources,
		build_local_inputs: local_build_inputs,
		build_sources: provenance_sources,
		build_capabilities: ["builds", "build-files", "dependency-builds", "prepare", "checked-rebuild"],
		build_guarantees: ["captured-declared-inputs", "sandboxed-filesystem", "sandboxed-network", "checked-rebuild-comparison"],
		build_exclusions: |spec, layout| {
			project = Project.validate(spec)?
			Ok(excluded(layout, Locks.inputs(project)?))
		},
		name: "nix",
		features: ["raw", "sources", "builds", "workflows", "system-tools", "commands", "roc-packages", "configured-tools", "build-files"],
		realises,
		render: |spec| {
			# A project with no Nix source has no flake: there is nothing of
			# it for Nix to build.
			project = Project.validate(spec)?
			if project.sources.any(|source| realises(source.provider)) {
				render(project).map_ok(|contents| [{ path: "flake.nix", contents }])
			} else {
				Ok([])
			}
		},
		inspect_lock: |lock| {
			entries = Locks.inspect(lock)?
			Ok(
				entries.map(
					|entry| {
						name: entry.name,
						content_identity: entry.identity,
						digest_kind: Tree,
						metadata: match entry.fetch_tree {
							LockJson.Null => []
							value => [{ name: "fetchTree", value: Locks.to_value(value) }]
						},
					},
				),
			)
		},
		preflight,
		realise: |spec, request, target, layout, text| {
			lock = Locks.from_lock(text).map_err(|m| InvalidLock(m))?
			plan(spec, request, target, layout, lock).map_err(|m| Unrealisable(m))
		},
		resolve,
		lock_from_native: |spec, layout, text, trees| {
			locks = Locks.from_nix(spec, layout, text)?
			Ok(Locks.to_lock(locks.with_trees(layout, trees)?))
		},
	}

	## Nix supplies a source that names a Nix package set, and no other: a
	## Guix channel is not its to realise, and neither is a source that names
	## no set, which nothing declares any longer.
	realises : Spec.Provider -> Bool
	realises = |source| source.name == "nix" and source.version == 1

	validate_source : Spec.Provider -> Try({}, Str)
	validate_source = |source| {
		if !realises(source) or Native.check_ref(source.ref).is_err() {
			return Err("unsupported Nix source declaration version or reference")
		}
		Ok({})
	}

	## `nix flake update` resolves every input of the staged flake. Given
	## names it resolves those and keeps the rest of the lock beside the flake,
	## so a named update stages the Lock's own native lock first. A local input
	## is named with them: Nix reads its tree again, as the Core hashes it again.
	resolve : Spec, Str, Layout, Provider.Update -> Try(Provider.Resolution, Str)
	resolve = |spec, target, layout, update| {
		files = update_files(spec, target, layout)?
		locals = local_checks(spec, target, layout)?
		native_lock = "${layout.generated_root}/flake.lock"
		flake = ["--flake", Locks.path_reference(layout.generated_root)]
		# The machine must have Nix itself: nothing installs it.
		present = [{ program: "nix", because: resolving(Project.validate(spec)?) }]
		match update {
			All => Ok({ present, files, locals, argv: ["nix", "flake", "update"].concat(flake), native_lock })
			Named(names, lock) => {
				project = Project.validate(spec)?
				declared = Locks.inputs(project)?
				unknown = names.keep_if(|name| !declared.any(|input| input.name == name))
				if !unknown.is_empty() {
					return Err(Realise.unknown_names(unknown, declared.map(|input| input.name), Project.unique(project.programs.map(|program| program.name))))
				}
				derived = Locks.derive(Locks.from_lock(lock)?, project, layout)?
				# Nix leaves a lock it has nothing to change in as it found it,
				# so stage it in the order Nix writes: the published Lock then
				# reads the same whichever of the two wrote the native one.
				kept = LockJson.encode(LockJson.sorted(LockJson.decode(derived.contents)?))
				local = declared.keep_if(|input| input.ref.starts_with("path:") and !names.contains(input.name)).map(|input| input.name)
				Ok({
					present,
					files: files.append({ path: native_lock, contents: kept }),
					locals,
					argv: ["nix", "flake", "update"].concat(names).concat(local).concat(flake),
					native_lock,
				})
			}
		}
	}

	## Why an update starts Nix, for whoever finds it missing: the first
	## thing the project declares that only Nix resolves.
	resolving : Spec -> Str
	resolving = |project|
		match (project.sources.find_first(|source| realises(source.provider)), project.inputs.first(), Project.resolved_build_sources(project).first()) {
			(Ok(source), _, _) => "Blueprint.roc declares the Nix source ${source.name}, which Nix resolves"
			(Err(_), Ok(input), _) => "Blueprint.roc declares the input ${input.name}, which Nix resolves"
			(Err(_), Err(_), Ok(source)) => "Blueprint.roc declares the source ${source.name}, which Nix locks"
			(Err(_), Err(_), Err(_)) => "blueprint update resolves pins with Nix"
		}

	## Rendering supports these target shapes, not cross-compilation or a host
	## support claim. Nix itself rejects tools unavailable on a declared target.
	supported_systems : List(Str)
	supported_systems = [
		"x86_64-linux",
		"aarch64-linux",
		"x86_64-darwin",
		"aarch64-darwin",
	]

	## Reserved shell prefix keeps aliases distinct from task environment refs.
	environment_shell : Str -> Str
	environment_shell = |name| "blueprint-env-${name}"

	## Validate and select the request before a consumer reads lock authority.
	## Planning reuses this same selection and renderer, without CLI semantics.
	preflight : Spec, Request, Str, Layout -> Try({}, Str)
	preflight = |spec, request, target, layout| {
		_ = prepare(spec, request, target, layout)?
		Ok({})
	}

	Prepared : {
		project : Spec,
		inputs : List(Locks.Input),
		builds : List(Spec.Build),
		argv : List(Str),
		contents : Str,
		action : [Generate, Shell(Str), Run(Str), Build(Str)],
		needs_nix : Str,
	}

	## The most text a workflow's distinct requests may render together, flakes
	## and argv: 16 MiB.
	workflow_budget : U64
	workflow_budget = 16777216

	## Expand only semantic requests. Every atomic request shares this selection
	## and renderer; never reload config or defer later capability/layout checks.
	prepare : Spec, Request, Str, Layout -> Try(List(Prepared), Str)
	prepare = |spec, request, target, layout| prepare_within(spec, request, target, layout, workflow_budget)

	## `prepare` with the workflow allowance as a parameter, so the accounting
	## is tested with kilobytes. Callers use `prepare`.
	prepare_within : Spec, Request, Str, Layout, U64 -> Try(List(Prepared), Str)
	prepare_within = |spec, request, target, layout, allowance| {
		project = Project.validate(spec)?
		match request {
			Request.Workflow(name) => {
				var $prepared = []
				var $templates = []
				var $bytes = 0.U64
				for step in Project.workflow_steps(project, name)? {
					atomic = match step {
						RunTask(task, extra) => Request.Run(task, extra)
						BuildArtifact(build) => Request.Build(build)
					}
					# Share immutable recipes, NEVER runtime artifacts or project copies.
					# Repeated requests still append a complete executable step.
					selected = match $templates.find_first(|entry| entry.request == atomic) {
						Ok(entry) => entry.selected
						Err(_) => {
							fresh = prepare_atomic(
								project,
								atomic,
								target,
								layout,
								Limited(allowance - $bytes),
							)?
							$bytes = $bytes + fresh.contents.to_utf8().len()
								+ fresh.argv.fold(0, |n, arg| n + arg.to_utf8().len())
							$templates = $templates.append({ request: atomic, selected: fresh })
							fresh
						}
					}
					$prepared = $prepared.append(selected)
				}
				# Empty workflows still check global features, declarations and layout.
				if $prepared.is_empty() {
					inputs = Locks.inputs(project)?
					_ = render_selected(
						project,
						[target],
						[],
						[],
						Unplanned,
						Some({ inputs, layout }),
						Limited(allowance),
					)?
					check_layout(project, target, layout)?
				}
				return Ok($prepared)
			}
			_ => {}
		}
		Ok([prepare_atomic(project, request, target, layout, Unlimited)?])
	}

	## Structural validation belongs to prepare, before selecting any steps.
	prepare_atomic : Spec, Request, Str, Layout, RenderBudget -> Try(Prepared, Str)
	prepare_atomic = |project, request, target, layout, budget| {
		var $names = []
		var $builds = []
		var $argv = []
		var $action = Generate
		base_ref = Locks.path_reference(layout.generated_root)
		read_only = ["--no-update-lock-file", "--no-write-lock-file"]
		match request {
			Request.Generate => {
				$names = whole(project)
				for build in project.builds {
					if !$builds.any(|selected| selected.name == build.name) {
						for dependency in Project.build_closure(project, build.name)? {
							if !$builds.any(|selected| selected.name == dependency.name) {
								$builds = $builds.append(dependency)
							}
						}
					}
				}
			}
			Request.Shell(name) => {
				$action = Shell(name)
				shell = project.shells.find_first(|s| s.name == name)
					.map_err(|_| "unknown shell: ${name}")?
				$names = [shell.environment]
				$argv = ["nix", "develop"].concat(read_only).append(
					"${base_ref}#devShells.${target}.${name}",
				)
			}
			Request.Run(name, extra) => {
				$action = Run(name)
				task = project.tasks.find_first(|t| t.name == name)
					.map_err(|_| "unknown task: ${name}")?
				command = task.run.concat(extra)
				Project.check_argv(command, name)?
				$names = [task.environment]
				entry = environment_shell(task.environment)
				$argv = ["nix", "develop"].concat(read_only)
					.concat(["${base_ref}#devShells.${target}.${entry}", "--command"])
					.concat(command)
			}
			Request.Build(name) => {
				$action = Build(name)
				if target != "x86_64-linux" {
					return Err("sandboxed builds currently require target x86_64-linux")
				}
				$builds = Project.build_closure(project, name)?
				if $builds.any(|build| build.inputs.contains("blueprint-input-evidence")) {
					return Err("build input name blueprint-input-evidence is reserved for selected reproduction evidence")
				}
				for selected in $builds {
					executor = Project.build_executor(project, selected.name)?
					Native.check_executor(executor).map_err(|problem| "Nix build ${selected.name}: ${problem}")?
					use = Project.environment_use(project, selected.environment, target)?
					if !(use.programs.is_empty() and use.unavailable.is_empty() and use.expects.is_empty()) {
						return Err("Nix build ${selected.name} does not support downloaded or expected tools")
					}
				}
				$names = $builds.map(|b| b.environment)
				# Namespace witnesses compare caller/build on the same kernel.
				# Never dispatch this local isolation contract to a remote builder.
				$argv = ["nix", "build", "--no-link", "--print-out-paths"]
					.concat(read_only)
					.concat([
						"--builders",
						"",
						"--option",
						"sandbox",
						"true",
						"--option",
						"sandbox-fallback",
						"false",
						"--option",
						"extra-sandbox-paths",
						"/blueprint-isolation/witness=@blueprint-isolation-source@/witness",
						"${base_ref}#packages.${target}.${name}",
					])
			}
			Request.Workflow(_) => return Err("workflow must expand into atomic requests")
		}
		inputs = Locks.inputs(project)?
		remaining = charge_rendered(
			budget,
			$argv.fold(0, |n, arg| n + arg.to_utf8().len()),
		)?
		# Only an explicit build observes its caller; other requests render
		# builds that refuse to evaluate.
		source = match $action {
			Build(_) => Planned
			_ => Unplanned
		}
		contents = render_selected(
			project,
			if (request == Request.Generate) project.systems else [target],
			$names,
			$builds,
			source,
			Some({ inputs, layout }),
			remaining,
		)?
		check_layout(project, target, layout)?
		# Why this step starts Nix, for whoever finds it missing. Generating
		# files starts nothing.
		needs_nix = match $action {
			Generate => ""
			Build(name) => "build ${name} runs in the Nix sandbox"
			Shell(_) | Run(_) => {
				environment = $names.first() ?? ""
				match Project.environment_use(project, environment, target).map_ok(|use| use.tools.first()) {
					Ok(Ok(tool)) => "environment ${environment} takes ${tool.source}#${tool.name} from the Nix source ${tool.source}"
					_ => "environment ${environment} is entered through Nix"
				}
			}
		}
		Ok({ project, inputs, builds: $builds, argv: $argv, contents, action: $action, needs_nix })
	}

	## Derive executable data only after complete structure, selected capability,
	## target, caller layout and authoritative lock checks. No effects occur here.
	plan : Spec, Request, Str, Layout, Locks -> Try(Steps, Str)
	plan = |spec, request, target, layout, locks| plan_within(spec, request, target, layout, locks, workflow_budget)

	## `plan` with the workflow allowance as a parameter, as `prepare_within`.
	plan_within : Spec, Request, Str, Layout, Locks, U64 -> Try(Steps, Str)
	plan_within = |spec, request, target, layout, locks, allowance| {
		prepared = prepare_within(spec, request, target, layout, allowance)?
		derived = Locks.derive(locks, Project.validate(spec)?, layout)?
		var $steps = []
		var $templates = []
		for selected in prepared {
			step = match $templates.find_first(
				|entry| entry.action == selected.action and entry.argv == selected.argv,
			) {
				Ok(entry) => entry
				Err(_) => {
					entry = materialize_plan(selected, target, layout, derived)
					$templates = $templates.append(entry)
					entry
				}
			}
			$steps = $steps.append(step)
		}
		Ok(Steps.{ steps: $steps })
	}

	## An isolation observation belongs to one explicit build, never an artifact name.
	## Recheck supplied local pins on every step, including after source-editing tasks.
	## Besides its locked inputs, everything the flake reads from outside its
	## own directory it reads as a locked path, through a record the host
	## writes beside the flake: where the content is and the NAR hash the
	## host measured with Nix, so that evaluation is pure.
	materialize_plan : Prepared, Str, Layout, { contents : Str, operations : List(Steps.Operation) } -> Steps.Step
	materialize_plan = |selected, target, layout, derived| {
		{ builds, argv, contents, action, needs_nix, .. } = selected
		base_ref = Locks.path_reference(layout.generated_root)
		used = selected.project.source_files.keep_if(|source| builds.any(|build| build.inputs.contains(source.name)))
		var $operations = derived.operations
		for source in used {
			$operations = $operations.append(SourceFile(source))
		}
		(measured, measures) = match action {
			Build(_) => {
				# Nix sandbox-paths splits on whitespace and cannot quote paths.
				# A fixed Linux temporary parent keeps arbitrary project/cache paths
				# out of that setting; the executor creates a private child per call.
				$operations = $operations.append(SourceFile(Runner.compiler)).append(Isolation({ directory: "/tmp", placeholder: "@blueprint-isolation-source@" }))
					.append(LocalSystem(target))
				# Only once the caller may build is anything copied or hashed.
				originals = used.append(Runner.compiler).map(
					|source| Measure({ target: SourceFile(source.sha256), argv: nar_hash, marker: source_marker(source.sha256), record: path_record }),
				)
				projects = builds.map(
					|build| Measure({ target: Snapshot(build.name), argv: nar_hash, marker: project_marker(build.name), record: path_record }),
				)
				(True, originals.concat(projects))
			}
			_ => (False, [])
		}
		$operations = $operations.concat(measures)
		# Generation measures nothing: its builds cannot run, and its records
		# say only where each original file is.
		source_record = |sha256| if (measured) source_marker(sha256) else "{\"path\":@blueprint-source-file-${sha256}@}"
		compiler_files = if measured {
			[{ path: "${layout.generated_root}/source-file-${Runner.compiler.sha256}.json", contents: source_marker(Runner.compiler.sha256) }]
				.concat(builds.map(|build| { path: "${layout.generated_root}/project-${build.name}.json", contents: project_marker(build.name) }))
		} else {
			[]
		}
		files = staged_files(layout, contents)
			.append({
				path: "${layout.generated_root}/flake.lock",
				contents: derived.contents,
			}).concat(
			used.map(
				|source| {
					path: "${layout.generated_root}/source-file-${source.sha256}.json",
					contents: source_record(source.sha256),
				},
			),
		)
		all_files = files.concat(compiler_files)
		# The machine must have Nix itself: nothing installs it.
		if !needs_nix.is_empty() {
			$operations = $operations.append(Present([{ program: "nix", because: needs_nix }]))
		}
		{
			action,
			files: all_files,
			argv,
			operations: $operations,
			artifacts: builds.map(
				|build| {
					name: build.name,
					provider: "nix",
					installable: "${base_ref}#packages.${target}.${build.name}",
					output: build.output,
					dependencies: build.needs,
				},
			),
		}
	}

	## How Nix identifies a path it is to read: the NAR hash `nix hash path`
	## prints, which `builtins.fetchTree` checks for a `path` input.
	nar_hash : List(Str)
	nar_hash = ["nix", "hash", "path"]

	## A locked path as the flake reads it: where the host put the content,
	## and its NAR hash.
	path_record : Str
	path_record = "{\"path\":@path@,\"narHash\":@identity@}"

	source_marker : Str -> Str
	source_marker = |sha256| "@blueprint-source-record-${sha256}@"

	project_marker : Str -> Str
	project_marker = |build| "@blueprint-project-record-${build}@"

	## What a build never reads from the project: VCS metadata names at every
	## depth, then caller-generated roots, the authority and local inputs.
	## The host's selection of a build's project files leaves these out.
	excluded : Layout, List(Locks.Input) -> List(Str)
	excluded = |layout, inputs|
		[
			".git",
			".hg",
			".svn",
			".jj",
			layout.workspace,
			layout.generated_root,
			layout.lock_path,
		]
			.concat(
				inputs.keep_if(|i| i.ref.starts_with("path:"))
					.map(|i| "${layout.project_root}/${Locks.local_path(i)}"),
			)

	## Update consumers check these source roots before staging or fetching.
	## Keep provider/input path interpretation here, not duplicated in the CLI.
	local_checks : Spec, Str, Layout -> Try(List(Str), Str)
	local_checks = |spec, target, layout| {
		project = Project.validate(spec)?
		check_layout(project, target, layout)?
		Ok(
			Locks.inputs(project)?
				.keep_if(|input| input.ref.starts_with("path:"))
				.map(|input| "${layout.project_root}/${Locks.local_path(input)}"),
		)
	}

	## Update renders the stable declarations but does not create authority.
	## The caller runs Nix explicitly, then validates with Locks.from_nix.
	update_files : Spec, Str, Layout -> Try(List(Steps.File), Str)
	update_files = |spec, target, layout| {
		project = Project.validate(spec)?
		check_layout(project, target, layout)?
		inputs = Locks.inputs(project)?
		names = whole(project)
		contents = render_selected(
			project,
			project.systems,
			names,
			project.builds,
			Unplanned,
			Some({ inputs, layout }),
			Unlimited,
		)?
		Ok(staged_files(layout, contents))
	}

	staged_files : Layout, Str -> List(Steps.File)
	staged_files = |layout, contents| [{ path: "${layout.generated_root}/flake.nix", contents }]

	check_layout : Spec, Str, Layout -> Try({}, Str)
	check_layout = |project, target, layout| {
		Layout.validate(layout)?
		if !project.systems.contains(target) {
			return Err("target ${target} is not declared by the project")
		}
		# A generated directory may contain the workspace, but an actual file
		# must never become its ancestor: the workspace is a directory.
		files = staged_files(layout, "").map(|file| file.path)
			.append("${layout.generated_root}/flake.lock")
			.append(Layout.ignore_file(layout))
		for file in files {
			if Layout.contains(file, layout.workspace)
				or Layout.contains(file, layout.lock_path)
				or Layout.contains(layout.lock_path, file) {
				return Err("generated files, workspace and authority must not overlap")
			}
		}
		if Layout.contains(layout.generated_root, layout.lock_path) {
			return Err("generated files, workspace and authority must not overlap")
		}
		for input in Locks.inputs(project)? {
			if input.ref.starts_with("path:") {
				path = "${layout.project_root}/${Locks.local_path(input)}"
				if Layout.contains(path, layout.workspace)
					or Layout.contains(layout.workspace, path)
					or Layout.contains(path, layout.generated_root)
					or Layout.contains(layout.generated_root, path)
					or Layout.contains(path, layout.lock_path) {
					return Err("local input overlaps caller-generated paths or lock")
				}
			}
		}
		Ok({})
	}

	## Whole rendering checks environments used by shells, tasks or builds.
	## Whole-project structural validation still rejects malformed declarations.
	render : Spec -> Try(Str, Str)
	render = |spec| {
		project = Project.validate(spec)?
		_ = Locks.inputs(project)?
		render_selected(project, project.systems, whole(project), project.builds, Unplanned, None, Unlimited)
	}

	## A Shell/Run consumer selects one environment before staging any effects.
	## Unrelated provider constraints must not block this request.
	render_environment : Spec, Str -> Try(Str, Str)
	render_environment = |spec, name| {
		project = Project.validate(spec)?
		_ = Locks.inputs(project)?
		render_closure(project, [name])
	}

	render_closure : Spec, List(Str) -> Try(Str, Str)
	render_closure = |spec, names|
		render_selected(spec, spec.systems, names, [], Unplanned, None, Unlimited)

	## Charge exact emitted UTF-8 bytes before retaining a renderer chunk.
	## Unlimited keeps standalone/inspection rendering on this same code path.
	RenderBudget : [Unlimited, Limited(U64)]

	charge_rendered : RenderBudget, U64 -> Try(RenderBudget, Str)
	charge_rendered = |budget, bytes| match budget {
		Unlimited => Ok(Unlimited)
		Limited(remaining) => if bytes > remaining {
			Err("workflow plan exceeds 16 MiB of distinct rendered requests")
		} else Ok(Limited(remaining - bytes))
	}

	## Accepted chunks stay within the remaining workflow text allowance.
	Rendered : { chunks : List(Str), budget : RenderBudget }

	## Never join a closure/system before checking its individual definitions.
	append_rendered : Rendered, Str -> Try(Rendered, Str)
	append_rendered = |rendered, chunk| {
		budget = charge_rendered(rendered.budget, chunk.to_utf8().len())?
		Ok({ chunks: rendered.chunks.append(chunk), budget })
	}

	## The project a build reads: only an explicit build plan has one.
	Source : [Unplanned, Planned]

	## Inspection and executable plans share one renderer. Plans supply the full
	## stable input set and explicit project source; inspection never guesses one.
	render_selected : Spec,
	List(Str),
	List(Str),
	List(Spec.Build),
	Source,
	[
		None,
		Some({ inputs : List(Locks.Input), layout : Layout }),
	],
	RenderBudget -> Try(Str, Str)
	render_selected = |input_spec, systems, names, builds, copied, staging, budget| {
		# What the Core plans itself is not this provider's to refuse.
		missing = input_spec.unsupported_features(provider.features.concat(Realise.features))
		if !missing.is_empty() {
			return Err("unsupported features: ${Str.join_with(missing, ", ")}")
		}
		spec = Project.validate(input_spec)?
		if builds.any(|build| build.inputs.contains("blueprint-input-evidence")) {
			return Err("build input name blueprint-input-evidence is reserved for selected reproduction evidence")
		}
		if !spec.extensions.is_empty() {
			kinds = spec.extensions.map(|e| "'${e.kind}' (${e.name})")
			return Err(
				"this blueprint does not support extensions yet; "
					.concat("Blueprint.roc uses ${Str.join_with(kinds, ", ")}"),
			)
		}
		selected_names = names.fold(
			[],
			|seen, name| if (seen.contains(name)) seen else seen.append(name),
		)
		for name in selected_names {
			Native.check_environment(spec, Nix, name)?
		}
		environments = spec.environments.keep_if(|e| names.contains(e.name))
		# Builds own an executor domain, independent of project tool downloads.
		# Shell/task environments must reject real tools on unsupported systems.
		shell_environment = |name| !builds.any(|build| build.environment == name)
			or spec.shells.any(|shell| shell.environment == name)
			or spec.tasks.any(|task| task.environment == name)
		for system in systems {
			if !supported_systems.contains(system) {
				for environment in environments.keep_if(|e| shell_environment(e.name)) {
					if !(Project.environment_use(spec, environment.name, system)?.tools.is_empty()) {
						return Err("unsupported Nix target ${system}")
					}
				}
			}
		}

		shells = spec.shells.keep_if(|s| names.contains(s.environment))
		builder = builder_source(spec)
		for environment in environments {
			if source_names(environment, spec.system_tools, spec.commands, spec.configured_tools, builder).is_empty() {
				return Err("environment ${environment.name} has no tool of a Nix source, and Blueprint.roc declares no Nix source to build it with")
			}
		}
		# Validate all Raw declarations, even aliases outside this request.
		# Only selected aliases are emitted; flake-level data is always retained.
		var $shell_raw = []
		var $flake_raw = []
		for r in spec.raw.keep_if(|r| r.backend == "nix") {
			if r.target == "flake" {
				$flake_raw = $flake_raw.concat(raw_attrs(r)?)
			} else if r.target.starts_with("shell:") {
				name = r.target.drop_prefix("shell:")
				if !spec.shells.any(|s| s.name == name) {
					return Err("raw nix target \"${r.target}\" names no shell")
				}
				$shell_raw = $shell_raw.concat(
					raw_attrs(r)?.map(|a| { shell: name, attr: a }),
				)
			} else {
				return Err(
					"unknown raw nix target \"${r.target}\"; "
						.concat("expected \"flake\" or \"shell:<name>\""),
				)
			}
		}
		check_attr_names(
			"the raw flake outputs",
			$flake_raw.map(|a| a.name),
			["devShells", "packages"],
		)?
		for shell in spec.shells {
			if shell.name.starts_with("blueprint-env-") {
				return Err("shell prefix blueprint-env- is reserved")
			}
			extra = $shell_raw.keep_if(|x| x.shell == shell.name)
				.map(|x| x.attr)
			check_attr_names(
				"the raw attributes of shell \"${shell.name}\"",
				extra.map(|a| a.name),
				["packages"],
			)?
		}
		var $rendered = { chunks: [], budget }
		$rendered = append_rendered(
			$rendered,
			lines([
				"# Generated by blueprint from Blueprint.roc. Do not edit.",
				"{",
				"  description = ${quote("Development environments for ${spec.name}")};",
				"",
				"  inputs = {",
			]),
		)?
		# Inspection retains scoped inputs; plans emit stable full declarations.
		# Either way `declared` is exactly what this flake declares.
		var $declared = []
		match staging {
			None => {
				for source in spec.sources.keep_if(
					|s| environments.any(|e| (if (builds.is_empty()) source_names(e, spec.system_tools, spec.commands, spec.configured_tools, builder) else Project.unique(builder.concat(source_names(e, spec.system_tools, spec.commands, spec.configured_tools, builder)))).contains(s.name)),
				) {
					if !realises(source.provider) {
						return Err("Nix cannot use ${source.provider.name} source ${source.name}")
					}
					url = source.provider.ref
					$declared = $declared.append({ name: source.name, kind: "packages" })
					$rendered = append_rendered(
						$rendered,
						"    ${quote(source.name)}.url = ${quote(url)};\n",
					)?
				}
				# An input some environment applies as an overlay enters only with
				# such an environment; any other input is a plain flake input.
				for input in spec.inputs.keep_if(
					|i| !Locks.overlay_names(spec).contains(i.name)
						or environments.any(|e| e.overlays.contains(i.name)),
				) {
					$declared = $declared.append({ name: input.name, kind: "flake" })
					$rendered = append_rendered(
						$rendered,
						"    ${quote(input.name)}.url = ${quote(input.url)};\n",
					)?
				}
				for source in Project.resolved_build_sources(spec) {
					$declared = $declared.append({ name: source.name, kind: "source" })
					$rendered = append_rendered(
						$rendered,
						"    ${quote(source.name)} = { url = ${quote(source.ref)}; "
							.concat("flake = false; };\n"),
					)?
				}
			}
			Some(data) => {
				for input in data.inputs {
					url = quote(Locks.input_url(input, data.layout))
					flake = if (input.flake) "true" else "false"
					$declared = $declared.append({ name: input.name, kind: input.kind })
					$rendered = append_rendered(
						$rendered,
						"    ${quote(input.name)} = { url = ${url}; "
							.concat("flake = ${flake}; };\n"),
					)?
				}
			}
		}
		$rendered = append_rendered($rendered, render_shell_alias($declared))?
		$rendered = append_rendered(
			$rendered,
			lines(
				[
					"  };",
					"",
					if spec.source_files.is_empty() {
						"  outputs = { self, ... }@inputs:"
					} else {
						"  outputs = { self, ... }@flakeInputs:"
					},
					"    let",
				].concat(
					if spec.source_files.is_empty() {
						[]
					} else {
						["      inputs = flakeInputs // { ${Str.join_with(spec.source_files.map(|source| "${quote(source.name)} = ${recorded_file(source.sha256)};"), " ")} };"]
					},
				).append("      environmentsFor = system: {"),
			),
		)?
		for environment in environments {
			$rendered = append_rendered(
				$rendered,
				render_environment_definition(environment, spec.system_tools, spec.commands, spec.configured_tools, builder),
			)?
		}
		$rendered = append_rendered(
			$rendered,
			lines([
				"      };",
				"    in",
				"    {",
				"      devShells = {",
			]),
		)?
		for system in systems.keep_if(|system| supported_systems.contains(system)) {
			$rendered = append_rendered(
				$rendered,
				lines([
					"        ${quote(system)} = let",
					"          environments = environmentsFor ${quote(system)};",
					"        in {",
				]),
			)?
			for environment in environments {
				$rendered = append_rendered(
					$rendered,
					"          ${quote(environment_shell(environment.name))} = "
						.concat("environments.${quote(environment.name)} { };\n"),
				)?
			}
			for shell in shells {
				extra = $shell_raw.keep_if(|x| x.shell == shell.name)
					.map(|x| x.attr)
				$rendered = append_rendered(
					$rendered,
					"          ${quote(shell.name)} = "
						.concat("environments.${quote(shell.environment)} ")
						.concat("${value_to_nix(Value.Attrs(extra))};\n"),
				)?
			}
			$rendered = append_rendered($rendered, "        };\n")?
		}
		$rendered = append_rendered($rendered, "      };\n")?
		if !builds.is_empty() {
			$rendered = append_rendered($rendered, render_source(copied))?
			for system in systems.keep_if(|system| system == "x86_64-linux") {
				$rendered = append_rendered(
					$rendered,
					"        ${quote(system)} = let artifacts = {\n",
				)?
				for build in builds {
					env = environments.find_first(|e| e.name == build.environment)
						.map_err(|_| "unknown build environment")?
					$rendered = append_rendered(
						$rendered,
						render_build(build, env, spec.system_tools, spec.commands, spec.configured_tools, spec.roc_packages, spec.source_files, system, [Project.build_executor(spec, build.name)?.source]),
					)?
				}
				$rendered = append_rendered(
					$rendered,
					"        }; in artifacts;\n",
				)?
			}
			$rendered = append_rendered($rendered, "      };\n")?
		}
		for attr in $flake_raw {
			$rendered = append_rendered(
				$rendered,
				"      ${quote(attr.name)} = ${value_to_nix(attr.value)};\n",
			)?
		}
		$rendered = append_rendered($rendered, lines(["    };", "}"]))?
		Ok(Str.join_with($rendered.chunks, ""))
	}

	## The input `nix develop` takes its own bash from, pinned like the source
	## it follows. Without it Nix uses the registry's floating nixpkgs for that
	## bash on every shell and task, whatever the Lock says. See
	## `Locks.shell_source` for which source is followed and when none is.
	render_shell_alias : List({ name : Str, kind : Str }) -> Str
	render_shell_alias = |declared| match Locks.shell_source(declared) {
		Ok(target) => "    ${quote(Locks.shell_alias)}.follows = ${quote(target)};\n"
		Err(NoAlias) => ""
	}

	## The environments a rendering of the whole project holds: those of its
	## shells, tasks and builds. In a project with no Nix source, a shell's or
	## a task's environment that has no tool of a Nix source is left out,
	## with its shells: nothing of it is Nix's, and the Core enters it without
	## Nix. That is the case of a project whose only business with Nix is an
	## input or a build source to lock. A build's environment always stays,
	## so that a build Nix cannot build is refused by name.
	whole : Spec -> List(Str)
	whole = |project| {
		builder = builder_source(project)
		buildable = |name|
			project.environments.find_first(|e| e.name == name)
				.map_ok(|e| !source_names(e, project.system_tools, project.commands, project.configured_tools, builder).is_empty()) ?? True
		project.shells.map(|s| s.environment)
			.concat(project.tasks.map(|t| t.environment))
			.keep_if(buildable)
			.concat(project.builds.map(|b| b.environment))
	}

	## Bootstrap sources for environment rendering come from selected Nix
	## executors. A shell-only environment may fall back to its first declared
	## Nix package source. Builds always use their own explicit executor source.
	builder_source : Spec -> List(Str)
	builder_source = |spec| {
		selected = spec.build_executors.map(|entry| entry.executor)
		explicit = spec.executors.keep_if(|executor| selected.contains(executor.name) and executor.provider == "nix" and !executor.source.is_empty()).map(|executor| executor.source)
		if explicit.is_empty() {
			# Environment rendering only; Builds never reach this fallback.
			spec.sources.keep_if(|source| realises(source.provider)).take_first(1).map(|source| source.name)
		} else {
			Project.unique(explicit).sort_with(Project.bytewise)
		}
	}

	## The sources an environment imports. mkShell, and a build's sandbox
	## tools, come from the first: the source of the environment's first
	## tool, on any System, which keeps unrelated providers outside the
	## request. An environment with no tool at all uses `builder` instead
	## (see `builder_source`).
	source_names : Spec.Environment, List(Spec.SystemTools), List(Spec.Command), List(Spec.ConfiguredTool), List(Str) -> List(Str)
	source_names = |environment, system_tools, commands, configured, builder| {
		all_tools = environment.tools.concat(system_tools.keep_if(|entry| entry.environment == environment.name).fold([], |tools, entry| tools.concat(entry.tools))).concat(commands.keep_if(|entry| entry.environment == environment.name).map(|entry| entry.tool)).concat(configured.keep_if(|entry| entry.environment == environment.name).map(|entry| entry.tool))
		initial = if (all_tools.is_empty()) builder else []
		all_tools.map(|t| t.source).fold(
			initial,
			|seen, name|
				if (seen.contains(name)) seen else seen.append(name),
		)
	}

	## What `nix develop` would export for a shell or task step, printed as
	## data instead of entered: the same installable, the same read-only lock.
	activation_argv : Steps.Step -> Try(List(Str), Str)
	activation_argv = |step| {
		match step.argv {
			[program, "develop", .. as rest] => {
				installable = rest.keep_if(|arg| arg.contains("#devShells.")).first().map_err(|_| "Nix shell plan names no dev shell")?
				options = rest.keep_if(|arg| arg.starts_with("--no-"))
				Ok([program, "print-dev-env", "--json"].concat(options).append(installable))
			}
			_ => Err("not a Nix shell plan")
		}
	}

	## The exported variables of a dev shell. Nix lists every variable of
	## the shell; only exported ones reach a caller, and PATH becomes search
	## path entries. The store is read only, so nothing here is a secret.
	activation : Str -> Try(Activation, Str)
	activation = |text| {
		data = JsonData.decode(text).map_err(|_| "Nix returned invalid dev shell JSON")?
		variables = JsonData.object(JsonData.field(data, "variables").map_err(|_| "Nix dev shell JSON has no variables")?).map_err(|_| "Nix dev shell variables are invalid")?
		var $path = []
		var $exported = []
		for variable in variables {
			kind = JsonData.string(JsonData.field(variable.value, "type") ?? JsonData.String("")) ?? ""
			if kind == "exported" {
				value = JsonData.string(JsonData.field(variable.value, "value") ?? JsonData.String("")).map_err(|_| "Nix exported ${variable.name} as something other than text")?
				if variable.name == "PATH" {
					$path = value.split_on(":").keep_if(|entry| !entry.is_empty()).map(|entry| { directory: entry, origin: "nix" })
				} else if Activation.valid_name(variable.name) and !["HOME", "TMPDIR", "TEMPDIR", "TMP", "TEMP", "SHLVL", "PWD", "OLDPWD", "NIX_BUILD_TOP"].contains(variable.name) {
					$exported = $exported.append({ name: variable.name, value, origin: "nix" })
				}
			}
		}
		Ok(Activation.{ path: $path, variables: $exported })
	}

	## Native output is always decoded, including the human path.
	build_argv : Steps.Step, Provider.BuildOptions -> Try(List(Str), Str)
	build_argv = |step, options| {
		argv = step.argv.keep_if(|arg| arg != "--print-out-paths").append("--json")
		Ok(if (options.rebuild) argv.append("--rebuild") else argv)
	}

	## Derivation inspection must never realize dependencies through IFD.
	build_prepare_argv : Steps.Step -> Try(List(Str), Str)
	build_prepare_argv = |step| {
		match step.argv {
			[program, "build", .. as args] => {
				var $kept = []
				var $skip = 0.U64
				for arg in args {
					if $skip > 0 {
						$skip = $skip - 1
					} else if arg == "extra-sandbox-paths" {
						$kept = $kept.drop_last(1)
						$skip = 1
					} else if arg != "--no-link" and arg != "--print-out-paths" {
						$kept = $kept.append(arg)
					}
				}
				Ok([program, "derivation", "show"].concat($kept).concat(["--option", "allow-import-from-derivation", "false"]))
			}
			_ => Err("Nix build plan has no build command")
		}
	}

	build_prepared : Str -> Try(Provider.PreparedBuild, Str)
	build_prepared = |text| {
		parsed = JsonData.decode(text).map_err(|_| "Nix returned invalid derivation JSON")?
		# Nix 2.34 uses schema 4: a versioned envelope and store basenames.
		(entries, basenames) = match parsed {
			Object(fields) => {
				if fields.any(|field| field.name == "version" or field.name == "derivations") {
					version = fields.find_first(|field| field.name == "version").map_err(|_| "Nix derivation envelope has no version")?
					if version.value != Number("4") {
						return Err("unsupported Nix derivation JSON version")
					}
					derivations = fields.find_first(|field| field.name == "derivations").map_err(|_| "Nix derivation envelope has no derivations")?
					match derivations.value {
						Object(values) => (values, True)
						_ => return Err("Nix derivation envelope is invalid")
					}
				} else {
					(fields, False)
				}
			}
			_ => return Err("Nix returned invalid derivation JSON")
		}
		match entries {
			[entry] => {
				identity = prepared_store_path(entry.name, basenames)?
				if !identity.ends_with(".drv") {
					return Err("Nix returned an invalid derivation identity")
				}
				fields = match entry.value {
					Object(values) => values
					_ => return Err("Nix derivation is not an object")
				}
				output_field = fields.find_first(|field| field.name == "outputs").map_err(|_| "Nix derivation has no outputs")?
				outputs = match output_field.value {
					Object(values) => values
					_ => return Err("Nix derivation outputs are invalid")
				}
				var $paths = []
				for output in outputs {
					properties = match output.value {
						Object(values) => values
						_ => return Err("Nix output is invalid")
					}
					field = properties.find_first(|property| property.name == "path").map_err(|_| "Nix output has no static path")?
					value = match field.value {
						String(path) => path
						_ => return Err("Nix output path is invalid")
					}
					output_path = prepared_store_path(value, basenames)?
					$paths = $paths.append({ name: output.name, path: output_path })
				}
				if $paths.is_empty() {
					return Err("Nix derivation has no outputs")
				}
				Ok({ build_identity: identity, outputs: $paths })
			}
			_ => Err("Nix returned an unexpected number of derivations")
		}
	}

	prepared_store_path : Str, Bool -> Try(Str, Str)
	prepared_store_path = |value, basenames| {
		full = if basenames and !value.starts_with("/") {
			"/nix/store/${value}"
		} else {
			value
		}
		if !full.starts_with("/nix/store/") {
			return Err("Nix returned a non-store build path")
		}
		name = full.drop_prefix("/nix/store/")
		if name.is_empty() or name == "." or name == ".." or name.contains("/") or name.contains("\\") or name.to_utf8().any(|byte| byte < 32 or byte == 127) {
			return Err("Nix returned an invalid store path")
		}
		Ok(full)
	}

	## Execute the captured recipe, never evaluate the mutable installable again.
	build_execute_argv : Steps.Step, Provider.PreparedBuild, Provider.BuildOptions -> Try(List(Str), Str)
	build_execute_argv = |step, prepared, options| {
		if !prepared.build_identity.starts_with("/nix/store/") or !prepared.build_identity.ends_with(".drv") {
			return Err("invalid prepared Nix build identity")
		}
		argv = build_argv(step, options)?
		artifact = match step.action {
			Build(name) => step.artifacts.find_first(|item| item.name == name).map_err(|_| "missing selected artifact")?
			_ => return Err("not a build plan")
		}
		Ok(argv.map(|arg| if (arg == artifact.installable) "${prepared.build_identity}^*" else arg))
	}

	build_result : Str -> Try(Provider.BuildResult, Str)
	build_result = |text| {
		parsed : Try(List({ drvPath : Str, outputs : { out : Str } }), _)
		parsed = Json.parse(text)
		match parsed.map_err(|_| "Nix returned invalid build JSON")? {
			[built] => Ok({ build_identity: built.drvPath, outputs: [{ name: "out", path: built.outputs.out }], metadata: [{ name: "derivation", value: Value.Str(built.drvPath) }] })
			_ => Err("Nix returned an unexpected number of build results")
		}
	}

	## Direct imported pins belong to one node; closure provenance is their union.
	direct_sources : Spec, Str -> Try(List(Str), Str)
	direct_sources = |spec, name| {
		project = Project.validate(spec)?
		build = project.builds.find_first(|entry| entry.name == name).map_err(|_| "unknown build ${name}")?
		env = project.environments.find_first(|entry| entry.name == build.environment).map_err(|_| "unknown build environment")?
		executor = Project.build_executor(project, name)?
		builder = if executor.source.is_empty() {
			[]
		} else {
			[executor.source]
		}
		Ok(
			Project.unique(
				source_names(env, project.system_tools, project.commands, project.configured_tools, builder)
					.concat(env.overlays).concat(build.inputs)
					.concat(project.roc_packages.keep_if(|entry| entry.environment == env.name).map(|entry| entry.source)),
			),
		)
	}

	## Structural inspection verifies selected local pins without native layout,
	## host restrictions or preparation effects. The host owns the tree reads.
	local_build_inputs : Spec, Str, Layout, Lock -> Try(List({ name : Str, path : Str, digest : Str }), Str)
	local_build_inputs = |spec, name, layout, lock| {
		selected = provenance_sources(spec, name)?
		inputs = Locks.inputs(Project.validate(spec)?)?.keep_if(|input| selected.contains(input.name) and input.ref.starts_with("path:"))
		if inputs.is_empty() {
			return Ok([])
		}
		locked = Locks.from_lock(lock)?
		var $locals = []
		for input in inputs {
			pin = locked.locals.find_first(|entry| entry.name == input.name).map_err(|_| "missing local build pin: ${input.name}")?
			$locals = $locals.append({ name: input.name, path: "${layout.project_root}/${Locks.local_path(input)}", digest: pin.digest })
		}
		Ok($locals)
	}

	provenance_sources : Spec, Str -> Try(List(Str), Str)
	provenance_sources = |spec, name| {
		closure = Project.build_closure(spec, name)?
		var $names = []
		for build in closure {
			$names = Project.unique($names.concat(direct_sources(spec, build.name)?))
		}
		Ok($names)
	}

	## A package holding only bin/<name>, which execs the tool's main program.
	## The tool's own bin directory stays off PATH, so a renamed compiler can
	## share an environment with another of the same name.
	command_package : Spec.Command -> Str
	command_package = |command| {
		set = "sets.${quote(command.tool.source)}"
		target = "${set}.${attr_path(tool_path(command.tool.name))}"
		"(${set}.writeShellScriptBin ${quote(command.name)} ''exec \${${set}.lib.getExe ${target}} \"$@\"'')"
	}

	## The tool with its options passed to the package's own `override`. The
	## options are rendered as data, so they select among what the package
	## offers and cannot say how to build it.
	configured_package : Spec.ConfiguredTool -> Str
	configured_package = |entry|
		"(sets.${quote(entry.tool.source)}.${attr_path(tool_path(entry.tool.name))}.override ${value_to_nix(entry.options)})"

	render_environment_definition : Spec.Environment, List(Spec.SystemTools), List(Spec.Command), List(Spec.ConfiguredTool), List(Str) -> Str
	render_environment_definition = |environment, system_tools, commands, configured, builder| {
		sources = source_names(environment, system_tools, commands, configured, builder)
		# `render_selected` has refused an environment with no source.
		primary = sources.first() ?? ""
		overlays = environment.overlays.map(
			|name| "inputs.${quote(name)}.overlays.default",
		)
		set_lines = sources.map(
			|name|
				"            ${quote(name)} = import inputs.${quote(name)} "
					.concat("{ inherit system overlays; };"),
		)
		tools = environment.tools.map(
			|tool|
				"            sets.${quote(tool.source)}."
					.concat(attr_path(tool_path(tool.name))),
		).concat(
			commands.keep_if(|entry| entry.environment == environment.name).map(
				|entry| "            ${command_package(entry)}",
			),
		).concat(
			configured.keep_if(|entry| entry.environment == environment.name).map(
				|entry| "            ${configured_package(entry)}",
			),
		)
		scoped = system_tools.keep_if(|entry| entry.environment == environment.name).map(
			|entry| {
				selected = entry.tools.map(|tool| "sets.${quote(tool.source)}.${attr_path(tool_path(tool.name))}")
				"          ++ (if system == ${quote(entry.system)} then [ ${Str.join_with(selected, " ")} ] else [])"
			},
		)
		prefix = lines([
			"        ${quote(environment.name)} = let",
			"          overlays = [ ${Str.join_with(overlays, " ")} ];",
			"          sets = {",
		]).concat(lines(set_lines)).concat(
			lines([
				"          };",
				"        in extra: sets.${quote(primary)}.mkShell ({",
				"          packages = [",
			]),
		).concat(lines(tools))
		suffix = if scoped.is_empty() {
			lines(["          ];", "        } // extra);"])
		} else {
			lines(["          ]"]).concat(lines(scoped)).concat(lines(["          ;", "        } // extra);"]))
		}
		prefix.concat(suffix)
	}

	## Open `packages` with what every build shares. The host copies each
	## build's selected project files and stages a record of where the copy
	## is and its NAR hash; Nix reads the copy as that locked path, so
	## evaluation is pure and the project's location is not in the recipe.
	## Nix records only whether the owner may execute a file. Namespace
	## authorization travels outside these bytes. The versioned runner's
	## source is independent of the CLI executable.
	render_source : Source -> Str
	render_source = |source| {
		runner = [
			"      packages = let",
			"        runnerSource = { url = ${quote(Runner.source.url)}; sha256 = ${quote(Runner.source.sha256)}; };",
			"        runnerFor = pkgs: (${Runner.nix}) { inherit pkgs; source = pkgs.fetchurl runnerSource; compilerArchive = ${recorded_file(Runner.compiler.sha256)}; };",
		]
		match source {
			Unplanned => lines(
				runner.concat([
					"        projectFor = _: builtins.throw \"build execution requires NixProvider.plan "
						.concat("and a caller project\";"),
					"        isolation = builtins.throw "
						.concat("\"build execution requires a caller isolation witness\";"),
					"        runner = builtins.throw \"build execution requires a caller runner\";",
					"      in {",
				]),
			)
			Planned => lines(
				runner.concat([
					"        projectFor = record: let project = builtins.fromJSON (builtins.readFile record); in "
						.concat("(builtins.fetchTree { type = \"path\"; path = project.path; narHash = project.narHash; }).outPath;"),
					"      in {",
				]),
			)
		}
	}

	## An original file, read through the record the host stages beside the
	## flake: a locked path wherever the host's store keeps it, whose flat
	## SHA-256 Nix checks again. Its store identity is independent of that
	## location.
	recorded_file : Str -> Str
	recorded_file = |sha256|
		"(let record = builtins.fromJSON (builtins.readFile ./source-file-${sha256}.json); "
			.concat("file = (builtins.fetchTree { type = \"path\"; path = record.path; narHash = record.narHash; }).outPath; ")
			.concat("in assert builtins.hashFile \"sha256\" file == ${quote(sha256)}; file)")

	## Ordinary, non-fixed-output derivations keep fetching outside user Run.
	## The standalone versioned runner uses the locked package set's native Roc utility.
	## Its own tools are absolute paths; argv and metadata enter through JSON.
	render_build : Spec.Build, Spec.Environment, List(Spec.SystemTools), List(Spec.Command), List(Spec.ConfiguredTool), List(Spec.RocPackage), List(Spec.SourceFile), Str, List(Str) -> Str
	render_build = |build, environment, system_tools, commands, configured, roc_packages, source_files, system, builder| {
		# A build has no network, so the runner gives Roc a cache of its own
		# holding these. Other builds' derivations stay as they were.
		bundles = roc_packages.keep_if(|entry| entry.environment == environment.name).map(roc_package_location)
		package_lines = if bundles.is_empty() {
			[]
		} else {
			[
				"              roc_packages = [ ${Str.join_with(bundles, " ")} ];",
				"              ln = \"\${pkgs.coreutils}/bin/ln\";",
			]
		}
		sources = Project.unique(builder.concat(source_names(environment, system_tools, commands, configured, builder)))
		primary = sources.first() ?? ""
		overlays = environment.overlays.map(
			|name| "inputs.${quote(name)}.overlays.default",
		)
		sets = sources.map(
			|name|
				"            ${quote(name)} = import inputs.${quote(name)} "
					.concat("{ inherit system overlays; };"),
		)
		selected_tools = environment.tools.concat(system_tools.keep_if(|entry| entry.environment == environment.name and entry.system == system).fold([], |tools, entry| tools.concat(entry.tools)))
		tools = selected_tools.map(
			|tool|
				"sets.${quote(tool.source)}.${attr_path(tool_path(tool.name))}",
		).concat(commands.keep_if(|entry| entry.environment == environment.name).map(command_package))
			.concat(configured.keep_if(|entry| entry.environment == environment.name).map(configured_package))
		tool_roots = selected_tools.map(|tool| { name: "${tool.source}#${tool.name}", root_path: "sets.${quote(tool.source)}.${attr_path(tool_path(tool.name))}" })
			.concat(configured.keep_if(|entry| entry.environment == environment.name).map(|entry| { name: "${entry.tool.source}#${entry.tool.name}", root_path: configured_package(entry) }))
			.concat(commands.keep_if(|entry| entry.environment == environment.name).map(|entry| { name: entry.name, root_path: "sets.${quote(entry.tool.source)}.${attr_path(tool_path(entry.tool.name))}" }))
			.map(|entry| "{ name = ${quote(entry.name)}; path = ${entry.root_path}; }")
		# Selected reproduction evidence is an input, never the identity of the
		# final derivation. Unrelated authority and mutable locators stay out.
		package_evidence = sources.concat(environment.overlays).map(
			|name| "{ name = ${quote(name)}; provider = \"nix\"; rev = inputs.${quote(name)}.rev or \"\"; narHash = inputs.${quote(name)}.narHash or \"\"; }",
		)
		file_evidence = source_files.keep_if(|entry| build.inputs.contains(entry.name)).map(
			|entry| "{ name = ${quote(entry.name)}; provider = \"file\"; sha256 = ${quote(entry.sha256)}; }",
		)
		source_evidence = build.inputs.keep_if(|name| !source_files.any(|entry| entry.name == name)).map(
			|name| "{ name = ${quote(name)}; path = inputs.${quote(name)}; rev = inputs.${quote(name)}.rev or \"\"; narHash = inputs.${quote(name)}.narHash or \"\"; }",
		)
		inputs = build.inputs.map(
			|name|
				"{ name = ${quote(name)}; path = inputs.${quote(name)}; }",
		)
		dependencies = build.needs.map(
			|name|
				"{ name = ${quote(name)}; path = artifacts.${quote(name)}; }",
		)
		# The host selected this build's project files (`Files` or the whole
		# project) and recorded the copy it made of them.
		project = "projectFor ./project-${build.name}.json"
		argv = Str.join_with(build.run.map(quote), " ")
		lines([
			"          ${quote(build.name)} = let",
			"            system = ${quote(system)};",
			"            overlays = [ ${Str.join_with(overlays, " ")} ];",
			"            sets = {",
		]).concat(lines(sets)).concat(
			lines([
				"            };",
				"            pkgs = sets.${quote(primary)};",
				"            tools = [ ${Str.join_with(tools, " ")} ];",
				"            runner = \"\${runnerFor pkgs}/bin/roc-build-runner\";",
				"            input_evidence = pkgs.writeText \"blueprint-input-evidence.json\" (builtins.toJSON {",
				"              format = 1; packages = [ ${Str.join_with(package_evidence, " ")} ]; files = [ ${Str.join_with(file_evidence, " ")} ];",
				"              sources = [ ${Str.join_with(source_evidence, " ")} ]; dependencies = [ ${Str.join_with(dependencies, " ")} ]; roc_packages = [ ${Str.join_with(bundles, " ")} ];",
				"              project = ${project}; tools = [ ${Str.join_with(tool_roots, " ")} ];",
				"            });",
				"            inputs_view = pkgs.linkFarm ${quote("blueprint-inputs-${build.name}")} ([ ${Str.join_with(inputs, " ")} ] ++ [ { name = \"blueprint-input-evidence\"; path = input_evidence; } ]);",
				"            artifacts_view = pkgs.linkFarm ${quote("blueprint-artifacts-${build.name}")} [ ${Str.join_with(dependencies, " ")} ];",
				"            tools_view = pkgs.linkFarm ${quote("blueprint-tools-${build.name}")} [ ${Str.join_with(tool_roots, " ")} ];",
				"          in derivation {",
				"            name = ${quote("blueprint-${build.name}")};",
				"            inherit system;",
				"            builder = runner;",
				"            args = [ ];",
				"            ROC_BUILD_RUNNER_WITNESS = \"/blueprint-isolation/witness\";",
				"            ROC_BUILD_RUNNER_READLINK = \"\${pkgs.coreutils}/bin/readlink\";",
				"            runnerSpec = builtins.toJSON {",
				"              schema_version = 1;",
				"              env = [ { name = \"BLUEPRINT_INPUTS\"; value = inputs_view; } { name = \"BLUEPRINT_ARTIFACTS\"; value = artifacts_view; } { name = \"BLUEPRINT_TOOLS\"; value = tools_view; } ];",
				"              project = ${project};",
				"              argv = [ ${argv} ];",
				"              output = ${quote(build.output)};",
				# Exactly the environment's tools: nothing implicit is on PATH.
				"              path = pkgs.lib.makeBinPath tools;",
				"              tools = tools_view;",
				"              inputs = inputs_view;",
				"              artifacts = artifacts_view;",
				"              readlink = \"\${pkgs.coreutils}/bin/readlink\";",
				"              chmod = \"\${pkgs.coreutils}/bin/chmod\";",
			]),
		).concat(lines(package_lines)).concat(
			lines([
				"            };",
				"            passAsFile = [ \"runnerSpec\" ];",
				"          };",
			]),
		)
	}

	## One locked bundle: the hash Roc looks for and its unpacked store path.
	roc_package_location : Spec.RocPackage -> Str
	roc_package_location = |entry|
		"{ name = ${quote(entry.name)}; path = inputs.${quote(entry.source)}.outPath; }"

	raw_attrs : Spec.Raw -> Try(List({ name : Str, value : Value }), Str)
	raw_attrs = |r| match r.value {
		Attrs(attrs) => Ok(attrs)
		_ => Err("raw nix value for \"${r.target}\" must be Attrs")
	}

	check_attr_names : Str, List(Str), List(Str) -> Try({}, Str)
	check_attr_names = |what, names, reserved| {
		var $seen = []
		for name in names {
			if reserved.contains(name) {
				return Err("${what} set \"${name}\", which the Nix provider writes itself")
			}
			if $seen.contains(name) {
				return Err("${what} set \"${name}\" more than once")
			}
			$seen = $seen.append(name)
		}
		Ok({})
	}

	## Render data only; interpolation and quotes cannot inject expressions.
	value_to_nix : Value -> Str
	value_to_nix = |value| match value {
		Str(s) => quote(s)
		Int(n) => if (n < 0) "(${n.to_str()})" else n.to_str()
		Bool(b) => if (b) "true" else "false"
		List([]) => "[ ]"
		List(items) => "[ ${Str.join_with(items.map(value_to_nix), " ")} ]"
		Attrs([]) => "{ }"
		Attrs(attrs) => {
			fields = attrs.map(|a| "${quote(a.name)} = ${value_to_nix(a.value)};")
			"{ ${Str.join_with(fields, " ")} }"
		}
	}

	## A validated Spec's tool names always parse; an unparsed name stays one
	## attribute, so Nix reports it rather than a different package.
	tool_path : Str -> List(Str)
	tool_path = |name| Native.nix_path(name) ?? [name]

	attr_path : List(Str) -> Str
	attr_path = |path| Str.join_with(path.map(quote), ".")

	lines : List(Str) -> Str
	lines = |items| items.fold("", |acc, line| acc.concat(line).concat("\n"))

	quote : Str -> Str
	quote = |value| {
		escaped = value
			.replace_each("\\", "\\\\")
			.replace_each("\"", "\\\"")
			.replace_each("\${", "\\\${")
			.replace_each("\n", "\\n")
			.replace_each("\r", "\\r")
			.replace_each("\t", "\\t")
		"\"${escaped}\""
	}
}

import "tests/sample.spec.scm" as sample_wire : Str
import "tests/full.spec.scm" as full_wire : Str
import "tests/sample.golden.nix" as sample_golden : Str
import "tests/full.golden.nix" as full_golden : Str

# The simple fixture covers scoped overlays, dotted attributes and aliases.
expect Spec.parse(sample_wire).map_err(|_| "invalid fixture")
	.map_ok(NixProvider.render) == Ok(Ok(sample_golden))

# The full fixture covers multiple sources, task-only environments and Raw data.
expect Spec.parse(full_wire).map_err(|_| "invalid fixture")
	.map_ok(NixProvider.render) == Ok(Ok(full_golden))

# Quotes, interpolation and control characters stay literal data.
expect NixProvider.value_to_nix(Value.Str("a\"b\\c\${d}\n\r\t")) ==
	"\"a\\\"b\\\\c\\\${d}\\n\\r\\t\""

# Nested data and negative numbers remain valid Nix expressions.
expect NixProvider.value_to_nix(
	Value.List([
		Value.Int(1),
		Value.Int(-2),
		Value.Attrs([{ name: "a b", value: Value.List([Value.Bool(True)]) }]),
	]),
) == "[ 1 (-2) { \"a b\" = [ true ]; } ]"

# Empty aggregate data and booleans preserve their native Nix values.
expect [Value.List([]), Value.Attrs([]), Value.Bool(False)]
	.map(NixProvider.value_to_nix) == ["[ ]", "{ }", "false"]

# Ordinary dollars without interpolation need no escaping.
expect NixProvider.value_to_nix(Value.Str("$x \$ {y}")) == "\"$x \$ {y}\""

# Focused Spec values exercise the public renderer without a CLI or effects.
TestSpec : {
	systems : List(Str),
	sources : List(Spec.Source),
	inputs : List(Spec.Input),
	environments : List(Spec.Environment),
	shells : List(Spec.Shell),
	tasks : List(Spec.Task),
	requires_ : List(Str),
	raw : List(Spec.Raw),
	extensions : List(Spec.Extension),
}

base : Spec.Environment
base = { name: "dev", parents: [], tools: [], overlays: [] }

## The one source most fixtures take their tools and their builder from. Its
## name is not special: it is declared, like any other.
unstable : Spec.Source
unstable = { name: "default", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-unstable" } }

simple : TestSpec
simple = {
	systems: ["x86_64-linux"],
	sources: [unstable],
	inputs: [],
	environments: [base],
	shells: [{ name: "default", environment: "dev" }],
	tasks: [],
	requires_: [],
	raw: [],
	extensions: [],
}

mk : TestSpec -> Spec
mk = |t| Spec.{
	resolvers: [{ provider: "nix", inputs: t.inputs.map(|input| input.name) }],
	executors: [],
	build_executors: [],
	source_files: [],
	build_files: [],
	format: Spec.current_format,
	name: "test",
	systems: t.systems,
	sources: t.sources,
	inputs: t.inputs,
	environments: t.environments,
	system_tools: [],
	commands: [],
	configured_tools: [],
	roc_packages: [],
	programs: [],
	environment_programs: [],
	expects: [],
	shells: t.shells,
	tasks: t.tasks,
	build_sources: [],
	builds: [],
	workflows: [],
	requires_: t.requires_,
	raw: t.raw,
	extensions: t.extensions,
}

rejects : TestSpec, Str -> Bool
rejects = |t, fragment| match NixProvider.render(mk(t)) {
	Err(message) => message.contains(fragment)
	Ok(_) => False
}

foreign : Spec.Environment
foreign = {
	..base,
	name: "foreign",
	tools: [{ source: "guix", name: "python@3:out" }],
}

mixed : TestSpec
mixed = {
	..simple,
	sources: [unstable, { name: "guix", provider: { name: "guix", version: 1, ref: "channels" } }],
	environments: [base, foreign],
}

# An environment with no tool takes mkShell from the first Nix source the
# project declares, whatever that is called.
expect match NixProvider.render(mk(simple)) {
	Ok(text) => text.contains(
		"\"default\".url = \"github:NixOS/nixpkgs/nixos-unstable\";",
	) and text.contains("in extra: sets.\"default\".mkShell")
	Err(_) => False
}
expect match NixProvider.render(mk({ ..simple, sources: [{ name: "guix", provider: { name: "guix", version: 1, ref: "channels" } }, stable, unstable] })) {
	Ok(text) => text.contains("\"stable\".url = \"github:NixOS/nixpkgs/nixos-24.05\";") and text.contains("in extra: sets.\"stable\".mkShell") and !text.contains("\"default\".url")
	Err(_) => False
}

# With no Nix source declared there is nothing to build such an environment
# with, and nothing is invented: asked for it alone, the provider refuses,
# and it has no file to show for the project.
expect NixProvider.render_environment(mk({ ..simple, sources: [] }), "dev") == Err("environment dev has no tool of a Nix source, and Blueprint.roc declares no Nix source to build it with")
expect NixProvider.render_environment(mk({ ..simple, sources: [{ name: "guix", provider: { name: "guix", version: 1, ref: "channels" } }] }), "dev") == Err("environment dev has no tool of a Nix source, and Blueprint.roc declares no Nix source to build it with")

# A rendering of the whole of such a project leaves the environment and its
# shell out: what remains is what Nix has to lock, here an overlay. A build
# is never left out: Nix cannot build it, and that is said.
expect {
	locking = mk({ ..simple, sources: [], inputs: [{ name: "roc", url: "github:roc-lang/roc-overlay" }], tasks: [{ name: "check", environment: "dev", run: ["true"] }] })
	building = { ..locking, requires_: ["builds"], executors: [{ name: "native", provider: "nix", source: "" }], build_executors: [{ build: "app", executor: "native" }], builds: [{ name: "app", environment: "dev", inputs: [], needs: [], run: ["true"], output: "out" }] }
	NixProvider.whole(locking) == [] and NixProvider.whole(mk(simple)) == ["dev"] and NixProvider.whole(building) == ["dev"]
		and NixProvider.render(locking).map_ok(|text| text.contains("mkShell") or text.contains("\"default\"")) == Ok(False)
		and NixProvider.update_files(locking, "x86_64-linux", TestData.layout).map_ok(|files| files.map(|file| file.contents.contains("\"roc\" = { url = \"github:roc-lang/roc-overlay\"; flake = true; };"))) == Ok([True])
		and NixProvider.render(building) == Err("environment dev has no tool of a Nix source, and Blueprint.roc declares no Nix source to build it with")
}
expect (NixProvider.provider.render)(mk({ ..simple, sources: [] })) == Ok([]) and (NixProvider.provider.render)(mk(simple)).map_ok(|files| files.map(|file| file.path)) == Ok(["flake.nix"])
expect NixProvider.builder_source(mk({ ..simple, sources: [{ name: "guix", provider: { name: "guix", version: 1, ref: "channels" } }, stable, unstable] })) == ["stable"] and NixProvider.builder_source(mk({ ..simple, sources: [] })) == []

# `nix develop` takes its own bash from the input named nixpkgs: the flake
# gives that name to its first Nix source, after the inputs it declares.
expect match NixProvider.render(mk(simple)) {
	Ok(text) => text.contains(
		"  inputs = {\n    \"default\".url = \"github:NixOS/nixpkgs/nixos-unstable\";\n    \"nixpkgs\".follows = \"default\";\n  };\n",
	)
	Err(_) => False
}

alias_environment : Str, List(Str) -> Spec.Environment
alias_environment = |name, sources| { ..base, name, tools: sources.map(|source| { source, name: "git" }) }

alias_lines : TestSpec -> Try(List(Str), Str)
alias_lines = |t| Ok(NixProvider.render(mk(t))?.split_on("\n").keep_if(|line| line.contains("follows") or line.contains("\"nixpkgs\"")))

stable : Spec.Source
stable = { name: "stable", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-24.05" } }

# The first rendered package source is followed, in the order of
# Blueprint.roc and whatever its name: one called `default` is not preferred.
# An overlay or other input is never followed.
expect {
	both = {
		..simple,
		sources: [stable, unstable],
		inputs: [{ name: "roc", url: "github:roc-lang/roc-overlay" }],
		environments: [{ ..alias_environment("dev", ["default", "stable"]), overlays: ["roc"] }],
	}
	only_named = {
		..simple,
		sources: [stable, { name: "older", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-23.11" } }],
		environments: [alias_environment("dev", ["older", "stable"])],
	}
	alias_lines(both) == Ok(["    \"nixpkgs\".follows = \"stable\";"])
		and alias_lines(only_named) == Ok(["    \"nixpkgs\".follows = \"stable\";"])
}

# Inspection renders only the sources an environment uses, so the alias
# follows one of those: never an input this flake does not declare.
expect {
	project = mk({
		..simple,
		sources: [stable, unstable],
		environments: [alias_environment("dev", ["stable"]), alias_environment("plain", ["default"])],
		shells: [{ name: "default", environment: "dev" }, { name: "plain", environment: "plain" }],
	})
	lines_of = |name| Ok(NixProvider.render_environment(project, name)?.split_on("\n").keep_if(|line| line.contains("follows")))
	lines_of("dev") == Ok(["    \"nixpkgs\".follows = \"stable\";"])
		and lines_of("plain") == Ok(["    \"nixpkgs\".follows = \"default\";"])
}

# A project that declares an input named nixpkgs keeps it, whatever its kind:
# no second declaration of that name is written and nothing follows.
expect {
	as_source = {
		..simple,
		sources: [unstable, { name: "nixpkgs", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-24.05" } }],
		environments: [alias_environment("dev", ["default", "nixpkgs"])],
	}
	as_overlay = {
		..simple,
		inputs: [{ name: "nixpkgs", url: "github:example/overlay" }],
		environments: [{ ..base, overlays: ["nixpkgs"] }],
	}
	as_input = { ..simple, inputs: [{ name: "nixpkgs", url: "github:example/flake" }] }
	alias_lines(as_source) == Ok(["    \"nixpkgs\".url = \"github:NixOS/nixpkgs/nixos-24.05\";", "            \"nixpkgs\" = import inputs.\"nixpkgs\" { inherit system overlays; };", "            sets.\"nixpkgs\".\"git\""])
		and alias_lines(as_overlay) == Ok(["    \"nixpkgs\".url = \"github:example/overlay\";", "          overlays = [ inputs.\"nixpkgs\".overlays.default ];"])
		and alias_lines(as_input) == Ok(["    \"nixpkgs\".url = \"github:example/flake\";"])
}

# The rule itself: package sources only, the first declared, none when the
# name is taken or there is no Nix package source.
expect Locks.shell_source([{ name: "assets", kind: "source" }, { name: "stable", kind: "packages" }, { name: "default", kind: "packages" }]) == Ok("stable")
expect Locks.shell_source([{ name: "roc", kind: "overlay" }, { name: "stable", kind: "packages" }, { name: "older", kind: "packages" }]) == Ok("stable")
expect Locks.shell_source([{ name: "default", kind: "packages" }, { name: "nixpkgs", kind: "source" }]) == Err(NoAlias)
expect Locks.shell_source([{ name: "default", kind: "overlay" }, { name: "utils", kind: "flake" }, { name: "assets", kind: "source" }]) == Err(NoAlias)
expect Locks.shell_source([]) == Err(NoAlias)

# Tasks need stable entries even when no alias refers to their environment.
expect match NixProvider.render(
	mk({
		..simple,
		shells: [],
		tasks: [{ name: "check", environment: "dev", run: ["git", "--version"] }],
	}),
) {
	Ok(text) => text.contains("\"blueprint-env-dev\" = environments.\"dev\"")
	Err(_) => False
}

# Unused Guix declarations must not block the project's Nix shell/task closure.
expect NixProvider.render(mk(mixed)).is_ok()

# Selecting the foreign environment fails instead of overriding its provider.
expect NixProvider.render_environment(mk(mixed), "foreign").is_err()

# A selected Nix environment works even when another shell needs Guix.
expect {
	project = mk({
		..mixed,
		shells: simple.shells.append({ name: "foreign", environment: "foreign" }),
	})
	NixProvider.render(project).is_err()
		and NixProvider.render_environment(project, "dev").is_ok()
}

# Inherited stacks stay ordered, deduplicated and scoped to the chosen env.
expect {
	parent = { ..base, name: "base", overlays: ["base"] }
	child = { ..base, parents: ["base"], overlays: ["base", "patch"] }
	stacked = {
		..simple,
		inputs: [
			{ name: "base", url: "github:example/base" },
			{ name: "patch", url: "github:example/patch" },
		],
		environments: [parent, child],
	}
	inherited = NixProvider.render_environment(mk(stacked), "dev")
	inline = NixProvider.render_environment(
		mk({
			..stacked,
			environments: [parent, { ..child, parents: [] }],
		}),
		"dev",
	)
	inherited == inline and match inherited {
		Ok(text) => text.contains(
			"overlays = [ inputs.\"base\".overlays.default "
				.concat("inputs.\"patch\".overlays.default ];"),
		)
		Err(_) => False
	} and match NixProvider.render_environment(mk(stacked), "base") {
		Ok(text) => !text.contains("inputs.\"patch\".overlays.default")
		Err(_) => False
	}
}

# Unknown requests fail before a caller can generate files or invoke Nix.
expect NixProvider.render_environment(mk(simple), "missing").is_err()

# Supported Nix output shapes are explicit; a system with no tools needs none.
expect NixProvider.render(
	mk({
		..simple,
		systems: NixProvider.supported_systems,
	}),
).is_ok() and NixProvider.render(mk({ ..simple, systems: ["riscv64-linux"] })).is_ok()

# Native missing attributes survive rendering and fail later in Nix itself.
expect match NixProvider.render(
	mk({
		..simple,
		environments: [
			{
				..base,
				tools: [{ source: "default", name: "missingNativePackage" }],
			},
		],
	}),
) {
	Ok(text) => text.contains("sets.\"default\".\"missingNativePackage\"")
		and !text.contains("builtins.filter") and !text.contains("availableOn")
	Err(_) => False
}

# Target-specific tools are selected by the declared System; other targets
# never evaluate their package attributes.
expect {
	project = {
		..mk(simple),
		systems: ["x86_64-linux", "aarch64-darwin"],
		requires_: ["system-tools"],
		system_tools: [{ environment: "dev", system: "x86_64-linux", tools: [{ source: "default", name: "wayland" }] }],
	}
	match NixProvider.render(project) {
		Ok(text) => text.contains("if system == \"x86_64-linux\" then [ sets.\"default\".\"wayland\" ] else []") and !text.contains("builtins.filter")
		Err(_) => False
	}
}

# Scoped-only environments still have a shell builder on other Systems: the
# source of their first tool, not the project's first source.
expect {
	project = {
		..mk(simple),
		systems: ["x86_64-linux", "aarch64-darwin"],
		sources: [unstable, stable],
		environments: [{ ..base, tools: [] }],
		requires_: ["system-tools"],
		system_tools: [{ environment: "dev", system: "x86_64-linux", tools: [{ source: "stable", name: "jq" }] }],
	}
	match NixProvider.render(project) {
		Ok(text) => !text.contains("\"default\" = import inputs.\"default\"") and
			text.contains("\"stable\" = import inputs.\"stable\"") and
				text.contains("in extra: sets.\"stable\".mkShell")
		Err(_) => False
	}
}

# A command adds only a launcher for the tool's main program, and its source
# joins the environment's package sets even when no plain tool uses it.
expect {
	project = {
		..mk(simple),
		sources: [{ name: "stable", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-24.05" } }],
		requires_: ["commands"],
		commands: [{ environment: "dev", name: "roc-stable", tool: { source: "stable", name: "rocpkgs.nightly-2026-09-10-a670e34" } }],
	}
	match NixProvider.render(project) {
		Ok(text) => text.contains("(sets.\"stable\".writeShellScriptBin \"roc-stable\" ''exec \${sets.\"stable\".lib.getExe sets.\"stable\".\"rocpkgs\".\"nightly-2026-09-10-a670e34\"} \"$@\"'')") and
			text.contains("\"stable\" = import inputs.\"stable\"")
		Err(_) => False
	}
}

# A quoted segment is one attribute, however many dots it holds.
expect {
	project = {
		..mk(simple),
		sources: [{ name: "stable", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-24.05" } }],
		requires_: ["commands"],
		commands: [{ environment: "dev", name: "zig", tool: { source: "stable", name: "zigpkgs.\"0.16.0\"" } }],
	}
	match NixProvider.render(project) {
		Ok(text) => text.contains("sets.\"stable\".lib.getExe sets.\"stable\".\"zigpkgs\".\"0.16.0\"}")
		Err(_) => False
	}
}

expect NixProvider.render({ ..mk(simple), commands: [{ environment: "dev", name: "vcs", tool: { source: "default", name: "git" } }] }).is_err()

# A configured tool is the package's own override applied to data: strings
# stay strings whatever they hold, and its source joins the package sets.
expect {
	options = Value.Attrs([
		{ name: "targets", value: Value.List([Value.Str("x86_64-unknown-linux-musl"), Value.Str("aarch64-unknown-linux-musl")]) },
		{ name: "extensions", value: Value.List([Value.Str("rust-src\"; } // builtins.abort \"\${x}")]) },
	])
	project = {
		..mk(simple),
		sources: [{ name: "stable", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-24.05" } }],
		requires_: ["configured-tools"],
		configured_tools: [{ environment: "dev", tool: { source: "stable", name: "rust-bin.stable.\"1.95.0\".default" }, options }],
	}
	match NixProvider.render(project) {
		Ok(text) => text.contains("            (sets.\"stable\".\"rust-bin\".\"stable\".\"1.95.0\".\"default\".override { \"targets\" = [ \"x86_64-unknown-linux-musl\" \"aarch64-unknown-linux-musl\" ]; \"extensions\" = [ \"rust-src\\\"; } // builtins.abort \\\"\\\${x}\" ]; })\n") and
			text.contains("\"stable\" = import inputs.\"stable\"")
		Err(_) => False
	}
}

expect NixProvider.render({ ..mk(simple), configured_tools: [{ environment: "dev", tool: { source: "default", name: "git" }, options: Value.Attrs([]) }] }).is_err()

# A build's PATH takes the same configured package as the environment's shell.
expect {
	entry = { environment: "builder", tool: { source: "default", name: "zig" }, options: Value.Attrs([{ name: "debug", value: Value.Bool(True) }]) }
	build = { name: "app", environment: "builder", inputs: [], needs: [], run: ["true"], output: "out" }
	rendered = NixProvider.render_build(build, { name: "builder", parents: [], tools: [], overlays: [] }, [], [], [entry, { ..entry, environment: "other" }], [], [], "x86_64-linux", [])
	rendered.split_on("(sets.\"default\".\"zig\".override { \"debug\" = true; })").len() == 4
}

# A tool name that is not a Nix attribute path is refused before any effects.
expect NixProvider.render(
	mk({
		..simple,
		environments: [
			{
				..base,
				tools: [{ source: "default", name: "python@3:out" }],
			},
		],
	}),
).is_err()

# Native numeric-leading attributes are quoted, not rejected as identifiers.
expect match NixProvider.render(
	mk({
		..simple,
		environments: [{ ..base, tools: [{ source: "default", name: "7zip" }] }],
	}),
) {
	Ok(text) => text.contains("sets.\"default\".\"7zip\"")
	Err(_) => False
}

# Unknown capability requirements cannot disappear during direct rendering.
expect rejects({ ..simple, requires_: ["future-build"] }, "future-build")

# Unsupported Custom blocks retain the clear extension diagnostic.
expect rejects(
	{
		..simple,
		extensions: [{ kind: "service", name: "db", value: Value.Attrs([]) }],
	},
	"does not support extensions",
)

# Raw targeting another provider stays inert, regardless of its value shape.
expect NixProvider.render(
	mk({
		..simple,
		raw: [{ backend: "guix", target: "bogus", value: Value.Int(1) }],
	}),
).is_ok()

# Nix Raw targets must be either the flake or a declared shell alias.
expect rejects(
	{
		..simple,
		raw: [{ backend: "nix", target: "bogus", value: Value.Attrs([]) }],
	},
	"unknown raw nix target",
) and rejects(
	{
		..simple,
		raw: [{ backend: "nix", target: "shell:nope", value: Value.Attrs([]) }],
	},
	"names no shell",
)

# Shell Raw must be attribute data, not a string of Nix expressions.
expect rejects(
	{
		..simple,
		raw: [{ backend: "nix", target: "shell:default", value: Value.Str("x") }],
	},
	"must be Attrs",
)

# Raw cannot overwrite generated packages or flake devShells.
expect rejects(
	{
		..simple,
		raw: [
			{
				backend: "nix",
				target: "shell:default",
				value: Value.Attrs([
					{ name: "packages", value: Value.List([]) },
				]),
			},
		],
	},
	"set \"packages\"",
) and rejects(
	{
		..simple,
		raw: [
			{
				backend: "nix",
				target: "flake",
				value: Value.Attrs([
					{ name: "devShells", value: Value.Attrs([]) },
				]),
			},
		],
	},
	"set \"devShells\"",
)

# Duplicate Raw attributes across entries produce a diagnostic, not invalid Nix.
expect {
	raw = {
		backend: "nix",
		target: "shell:default",
		value: Value.Attrs([
			{ name: "FOO", value: Value.Str("bar") },
		]),
	}
	rejects({ ..simple, raw: [raw, raw] }, "more than once")
}

# Shell aliases cannot collide with stable task environment output names.
expect NixProvider.render(
	mk({
		..simple,
		shells: [{ name: "blueprint-env-dev", environment: "dev" }],
	}),
).is_err()

import TestData
import "tests/local.nix-lock.json" as native_lock : Str

plan_locks : Try(Locks, Str)
plan_locks = resolved(TestData.project(TestData.data), native_lock)

# An update of everything is a bare `nix flake update` over the staged flake.
expect {
	project = TestData.project(TestData.data)
	root = TestData.layout.generated_root
	match (NixProvider.provider.resolve)(project, "x86_64-linux", TestData.layout, All) {
		Ok(all) => all.argv == ["nix", "flake", "update", "--flake", "path:${root}"] and all.files.map(|file| file.path) == ["${root}/flake.nix"]
		Err(_) => False
	}
}

# Native references encode path bytes; filesystem destinations stay literal.
expect {
	layout = { ..TestData.layout, generated_root: "/generated a [b]/雪" }
	resolved_plan = (NixProvider.provider.resolve)(TestData.project(TestData.data), "x86_64-linux", layout, All)?
	resolved_plan.argv == ["nix", "flake", "update", "--flake", "path:/generated%20a%20%5Bb%5D/%E9%9B%AA"]
		and resolved_plan.native_lock == "/generated a [b]/雪/flake.lock"
}

# A named update stages the Lock's native lock for Nix to keep the other pins
# from, and names each local input once, asked for or not.
expect {
	project = TestData.project(TestData.data)
	root = TestData.layout.generated_root
	lock = Locks.to_lock(plan_locks?)
	asked = (NixProvider.provider.resolve)(project, "x86_64-linux", TestData.layout, Named(["default"], lock))?
	both = (NixProvider.provider.resolve)(project, "x86_64-linux", TestData.layout, Named(["assets", "default"], lock))?
	asked.argv == ["nix", "flake", "update", "default", "assets", "--flake", "path:${root}"]
		and both.argv == ["nix", "flake", "update", "assets", "default", "--flake", "path:${root}"]
		and asked.files.map(|file| file.path) == ["${root}/flake.nix", "${root}/flake.lock"]
		and asked.native_lock == "${root}/flake.lock"
}

# A name Blueprint.roc does not declare is refused before any effect, and so
# is a Lock resolved for other inputs.
expect {
	project = TestData.project(TestData.data)
	lock = Locks.to_lock(plan_locks?)
	renamed = { ..project, build_sources: [{ name: "other", ref: "path:./assets" }] }
	(NixProvider.provider.resolve)(project, "x86_64-linux", TestData.layout, Named(["assets", "nope"], lock)) == Err("no input or program named nope; Blueprint.roc declares the inputs default, assets and no program")
		and (NixProvider.provider.resolve)(renamed, "x86_64-linux", TestData.layout, Named(["other"], lock)).is_err()
}

## Resolve fixture pins as the Core would: native lock, then tree digests.
resolved : Spec, Str -> Try(Locks, Str)
resolved = |project, text| match Locks.from_nix(project, TestData.layout, text) {
	Ok(locks) => locks.with_trees(TestData.layout, [{ path: "/project/assets", digest: assets_tree }])
	Err(e) => Err(e)
}

assets_tree : Str
assets_tree = "sha256:1111111111111111111111111111111111111111111111111111111111111111"

plan_fixture : Request -> Try(Steps, Str)
plan_fixture = |request| {
	locks = plan_locks?
	NixProvider.plan(
		TestData.project(TestData.data),
		request,
		"x86_64-linux",
		TestData.layout,
		locks,
	)
}

# Preflight rejects the same requested closures without needing lock data.
expect {
	project = mk({
		..mixed,
		shells: simple.shells.append({ name: "foreign", environment: "foreign" }),
	})
	NixProvider.preflight(
		project,
		Request.Shell("default"),
		"x86_64-linux",
		TestData.layout,
	).is_ok()
		and NixProvider.preflight(
			project,
			Request.Shell("foreign"),
			"x86_64-linux",
			TestData.layout,
		).is_err()
}

# Unsupported declarations take precedence over absent requested targets.
expect NixProvider.preflight(
	mk({ ..simple, systems: ["riscv64-linux"] }),
	Request.Shell("default"),
	"x86_64-linux",
	TestData.layout,
) == Err("target x86_64-linux is not declared by the project")

# A build plans dependency-first artifacts and exact, immutable sandbox argv.
expect match plan_fixture(Request.Build("app")) {
	Ok({ steps: [plan] }) => plan.action == Build("app") and plan.artifacts == [
		{
			name: "library",
			provider: "nix",
			installable: "path:/generated#packages.x86_64-linux.library",
			output: "dist/library",
			dependencies: [],
		},
		{
			name: "app",
			provider: "nix",
			installable: "path:/generated#packages.x86_64-linux.app",
			output: "dist/app",
			dependencies: ["library"],
		},
	] and plan.argv == [
		"nix",
		"build",
		"--no-link",
		"--print-out-paths",
		"--no-update-lock-file",
		"--no-write-lock-file",
		"--builders",
		"",
		"--option",
		"sandbox",
		"true",
		"--option",
		"sandbox-fallback",
		"false",
		"--option",
		"extra-sandbox-paths",
		"/blueprint-isolation/witness=@blueprint-isolation-source@/witness",
		"path:/generated#packages.x86_64-linux.app",
	]
	_ => False
}

# Evaluation is pure: neither the build nor its preparation asks for --impure.
expect match plan_fixture(Request.Build("app")) {
	Ok({ steps: [plan] }) => !plan.argv.contains("--impure")
		and NixProvider.build_prepare_argv(plan).map_ok(|argv| !argv.contains("--impure") and argv.contains("allow-import-from-derivation")) == Ok(Bool.True)
	_ => False
}

# Inputs are verified before each fresh observation of the caller. Only then
# does the host locate, copy and hash what Nix reads as locked paths: the
# compiler archive and each build's selected project files, one record each.
expect match plan_fixture(Request.Build("app")) {
	Ok({ steps: [plan] }) => plan.operations == [
		VerifyTree({ path: "/project/assets", digest: assets_tree }),
		SourceFile(Runner.compiler),
		Isolation({ directory: "/tmp", placeholder: "@blueprint-isolation-source@" }),
		LocalSystem("x86_64-linux"),
		Measure({ target: SourceFile(Runner.compiler.sha256), argv: ["nix", "hash", "path"], marker: "@blueprint-source-record-${Runner.compiler.sha256}@", record: "{\"path\":@path@,\"narHash\":@identity@}" }),
		Measure({ target: Snapshot("library"), argv: ["nix", "hash", "path"], marker: "@blueprint-project-record-library@", record: "{\"path\":@path@,\"narHash\":@identity@}" }),
		Measure({ target: Snapshot("app"), argv: ["nix", "hash", "path"], marker: "@blueprint-project-record-app@", record: "{\"path\":@path@,\"narHash\":@identity@}" }),
		Present([{ program: "nix", because: "build app runs in the Nix sandbox" }]),
	] and plan.files.map(|file| (file.path, if (file.path.ends_with(".json")) file.contents else "")) == [
		("/generated/flake.nix", ""),
		("/generated/flake.lock", ""),
		("/generated/source-file-${Runner.compiler.sha256}.json", "@blueprint-source-record-${Runner.compiler.sha256}@"),
		("/generated/project-library.json", "@blueprint-project-record-library@"),
		("/generated/project-app.json", "@blueprint-project-record-app@"),
	]
	_ => False
}

# An original file a build uses is staged, then measured with the others.
# Generation measures nothing and starts nothing: its record says only where
# the file is.
expect {
	upstream = { name: "upstream", url: "https://example.test/upstream.tar.gz", sha256: "a".repeat(64) }
	declared = TestData.project({ ..TestData.data, requires_: TestData.data.requires_.append("source-files"), builds: TestData.data.builds.map(|build| if (build.name == "library") { ..build, inputs: build.inputs.append("upstream") } else build) })
	project = { ..declared, source_files: [upstream] }
	locks = plan_locks?
	measured = |request| NixProvider.plan(project, request, "x86_64-linux", TestData.layout, locks).map_ok(
		|steps| steps.steps.map(
			|step| (
				step.operations.keep_if(
					|operation| match operation {
						SourceFile(_) | Measure(_) => True
						_ => False
					},
				),
				step.files.keep_if(|file| file.path == "/generated/source-file-${upstream.sha256}.json").map(|file| file.contents),
			),
		),
	)
	measured(Request.Build("library")) == Ok([
		(
			[
				SourceFile(upstream),
				SourceFile(Runner.compiler),
				Measure({ target: SourceFile(upstream.sha256), argv: ["nix", "hash", "path"], marker: "@blueprint-source-record-${upstream.sha256}@", record: "{\"path\":@path@,\"narHash\":@identity@}" }),
				Measure({ target: SourceFile(Runner.compiler.sha256), argv: ["nix", "hash", "path"], marker: "@blueprint-source-record-${Runner.compiler.sha256}@", record: "{\"path\":@path@,\"narHash\":@identity@}" }),
				Measure({ target: Snapshot("library"), argv: ["nix", "hash", "path"], marker: "@blueprint-project-record-library@", record: "{\"path\":@path@,\"narHash\":@identity@}" }),
			],
			["@blueprint-source-record-${upstream.sha256}@"],
		),
	])
		and measured(Request.Generate) == Ok([([SourceFile(upstream)], ["{\"path\":@blueprint-source-file-${upstream.sha256}@}"])])
}

# Exact argv stays JSON data; immutable input farms and a versioned runner
# depend only on selected project bytes and the pinned package set.
expect match plan_fixture(Request.Build("app")) {
	Ok({ steps: [plan] }) => match plan.files.first() {
		Ok(file) => file.contents.contains("\"\" \"two words\" \"line\\nbreak\" \"$HOME\"")
			and file.contents.contains("path = artifacts.\"library\";")
			and file.contents.contains("path = inputs.\"assets\";")
			and file.contents.contains("builder = runner;")
			and file.contents.contains("name = \"blueprint-build-runner-v1\";")
			and file.contents.contains("path = pkgs.lib.makeBinPath tools;")
			and !file.contents.contains("@blueprint-caller")
			and !file.contents.contains("outputHash")
		_ => False
	}
	_ => False
}

# A build reads its project, and the runner its compiler, as locked paths
# through records beside the flake: never an absolute path of the caller's,
# and no filter of Nix's own. The host selects the files.
expect {
	planned = NixProvider.render_source(Planned)
	planned.contains("projectFor = record: let project = builtins.fromJSON (builtins.readFile record); in (builtins.fetchTree { type = \"path\"; path = project.path; narHash = project.narHash; }).outPath;")
		and planned.contains("compilerArchive = (let record = builtins.fromJSON (builtins.readFile ./source-file-${Runner.compiler.sha256}.json); file = (builtins.fetchTree { type = \"path\"; path = record.path; narHash = record.narHash; }).outPath; in assert builtins.hashFile \"sha256\" file == \"${Runner.compiler.sha256}\"; file);")
		and !planned.contains("builtins.path")
		and !planned.contains("filter")
}

# The build plan's flake reads no absolute path itself; the host's selection
# leaves out VCS names, caller roots, the authority and local inputs.
# Inspection and non-build requests render builds that cannot run.
expect match (plan_fixture(Request.Build("app")), plan_fixture(Request.Generate)) {
	(Ok({ steps: [build] }), Ok({ steps: [generate] })) => match (build.files.first(), generate.files.first()) {
		(Ok(planned), Ok(inert)) =>
			planned.contents.contains("project = projectFor ./project-app.json;")
				and planned.contents.contains("project = projectFor ./project-library.json;")
				and !planned.contents.contains("/. + ")
				and !planned.contents.contains("builtins.path")
				and inert.contents.contains("projectFor = _: builtins.throw")
				and inert.contents.contains("isolation = builtins.throw")
				and inert.contents.contains("runner = builtins.throw")
				and !inert.contents.contains("@blueprint-caller")
				and (NixProvider.provider.build_exclusions)(TestData.project(TestData.data), TestData.layout) == Ok([".git", ".hg", ".svn", ".jj", "/work", "/generated", "/authority/inputs.lock", "/project/assets"])
		_ => False
	}
	_ => False
}

# Caller placeholders are ordinary argv bytes now, never substituted in recipes.
expect ["@blueprint-caller-mnt-namespace@", "@blueprint-caller-net-namespace@", "@blueprint-caller-executable@"].all(
	|placeholder| NixProvider.preflight(TestData.project({ ..TestData.data, builds: [{ ..TestData.library, run: ["python3", placeholder] }] }), Request.Build("library"), "x86_64-linux", TestData.layout).is_ok(),
)

# Task extras preserve empty arguments, controls and option-looking literals.
expect match plan_fixture(
	Request.Run(
		"check",
		["", "two words", "--flag", "a\nb"],
	),
) {
	Ok({ steps: [plan] }) => plan.action == Run("check") and plan.argv == [
		"nix",
		"develop",
		"--no-update-lock-file",
		"--no-write-lock-file",
		"path:/generated#devShells.x86_64-linux.blueprint-env-builder",
		"--command",
		"python3",
		"check.py",
		"configured argument",
		"",
		"two words",
		"--flag",
		"a\nb",
	] and plan.artifacts.is_empty()
		and plan.operations == [VerifyTree({ path: "/project/assets", digest: assets_tree }), Present([{ program: "nix", because: "environment builder takes default#python3 from the Nix source default" }])] and plan.files.len() == 2
	_ => False
}

# Aliases use the caller target, never the host's implicit default output shape.
expect match plan_fixture(Request.Shell("default")) {
	Ok({ steps: [plan] }) => plan.action == Shell("default") and plan.argv == [
		"nix",
		"develop",
		"--no-update-lock-file",
		"--no-write-lock-file",
		"path:/generated#devShells.x86_64-linux.default",
	]
		and plan.artifacts.is_empty()
	_ => False
}

# A staged plan declares every input, so its alias does not depend on the
# request: a task in an environment that uses only `stable` still follows
# the project's first source, and the working lock carries the matching edge.
expect {
	data = {
		..TestData.data,
		sources: [unstable, stable],
		environments: [TestData.builder, alias_environment("pinned", ["stable"])],
		tasks: TestData.data.tasks.append({ name: "pinned", environment: "pinned", run: ["git"] }),
	}
	project = TestData.project(data)
	native = native_lock.replace_each("\"assets\": \"assets\"", "\"assets\": \"assets\", \"stable\": \"stable\"").replace_each(
		"\"default\": {",
		"\"stable\": { \"locked\": { \"lastModified\": 1, \"narHash\": \"sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=\", \"owner\": \"NixOS\", \"repo\": \"nixpkgs\", \"rev\": \"4975466d324710c576dc11ad614684e6bd8cad8e\", \"type\": \"github\" }, \"original\": { \"owner\": \"NixOS\", \"ref\": \"nixos-24.05\", \"repo\": \"nixpkgs\", \"type\": \"github\" } },\n    \"default\": {",
	)
	locks = resolved(project, native)?
	plan = NixProvider.plan(project, Request.Run("pinned", []), "x86_64-linux", TestData.layout, locks)?
	match plan.steps.first().map_ok(|step| step.files) {
		Ok([flake, lock]) => flake.contents.contains("    \"stable\" = { url = \"github:NixOS/nixpkgs/nixos-24.05\"; flake = true; };\n    \"assets\" = { url = \"path:/project/assets\"; flake = false; };\n    \"nixpkgs\".follows = \"default\";\n  };\n")
			and lock.path == "/generated/flake.lock" and lock.contents.contains("\"nixpkgs\":[\"default\"]")
		_ => False
	}
}
# Roc packages: `packages` has one bundle, `scripts` inherits it and adds
# another, and a build runs in `scripts`. `reports` has a third, which only a
# task uses, and `builder` has none.
roc_project : Spec
roc_project = {
	..TestData.project({
		..TestData.data,
		environments: [
			TestData.builder,
			{ name: "packages", parents: [], tools: [], overlays: [] },
			{ name: "scripts", parents: ["packages"], tools: [], overlays: [] },
			{ name: "reports", parents: [], tools: [], overlays: [] },
		],
		shells: [{ name: "default", environment: "builder" }, { name: "scripts", environment: "scripts" }],
		tasks: TestData.data.tasks.concat([{ name: "script", environment: "scripts", run: ["roc", "main.roc"] }, { name: "report", environment: "reports", run: ["roc", "report.roc"] }]),
		build_sources: [
			{ name: "assets", ref: "path:./assets" },
			{ name: "roc-abc", ref: "tarball+https://example.test/abc.tar.zst" },
			{ name: "roc-def", ref: "tarball+https://example.test/def.tar.zst" },
			{ name: "roc-ghi", ref: "tarball+https://example.test/ghi.tar.zst" },
		],
		builds: [TestData.library, { ..TestData.library, name: "script", environment: "scripts" }],
		requires_: ["sources", "builds", "roc-packages"],
	}),
	resolvers: [{ provider: "nix", inputs: ["assets", "roc-abc", "roc-def"] }],
	roc_packages: [
		{ environment: "packages", name: "abc", source: "roc-abc" },
		{ environment: "scripts", name: "def", source: "roc-def" },
		{ environment: "reports", name: "ghi", source: "roc-ghi" },
	],
}

roc_plan : Request -> Try(Steps, Str)
roc_plan = |request| {
	node = |hash|
		"\"roc-${hash}\": { \"flake\": false, \"locked\": { \"narHash\": \"sha256-mhO52EWOvxHOyTFt0V1hM6Oo6mlpNo2PFlxQtcmCJBc=\", \"type\": \"tarball\", \"url\": \"https://example.test/${hash}.tar.zst\" }, \"original\": { \"type\": \"tarball\", \"url\": \"https://example.test/${hash}.tar.zst\" } },"
	native = native_lock
		.replace_each("    \"root\": {", "    ${node("abc")}\n    ${node("def")}\n    \"root\": {")
		.replace_each("\"nixpkgs\": [\"default\"]", "\"nixpkgs\": [\"default\"], \"roc-abc\": \"roc-abc\", \"roc-def\": \"roc-def\"")
	locks = resolved(roc_project, native)?
	NixProvider.plan(roc_project, request, "x86_64-linux", TestData.layout, locks)
}

# Nix locks a bundle only for a build, which has no network: the two a build's
# environment has are inputs, and the one a task alone uses is not. Nothing
# is resolved, staged or evaluated for that one.
expect Locks.inputs(roc_project).map_ok(|inputs| inputs.map(|input| input.name)) == Ok(["default", "assets", "roc-abc", "roc-def"])

# A task or a shell is given nothing of its Roc packages by this provider:
# the Core fetches them, the same with or without Nix. The step has no
# operation for them, its flake no output for them, and no input for a bundle
# no build uses.
expect [Request.Run("script", ["extra"]), Request.Shell("scripts"), Request.Run("report", []), Request.Run("check", []), Request.Shell("default")].all(
	|request|
		match roc_plan(request) {
			Ok({ steps: [plan] }) => {
				flake = plan.files.first().map_ok(|file| file.contents) ?? ""
				plan.operations.take_first(1) == [VerifyTree({ path: "/project/assets", digest: assets_tree })] and plan.operations.len() == 2
					and !flake.contains("blueprintRocPackages") and !flake.contains("roc_packages") and !flake.contains("roc-ghi")
					and flake.contains("    \"roc-abc\" = { url = \"tarball+https://example.test/abc.tar.zst\"; flake = false; };\n")
			}
			_ => False
		},
)
expect roc_plan(Request.Run("script", ["extra"])).map_ok(|plan| plan.steps.map(|step| step.argv.take_last(3))) == Ok([["roc", "main.roc", "extra"]])

# A build's specification names its environment's bundles and the `ln` that
# links them into the build's own cache, and a build whose environment has
# none keeps the specification it always had.
expect match (roc_plan(Request.Build("script")), roc_plan(Request.Build("library"))) {
	(Ok({ steps: [script] }), Ok({ steps: [library] })) => {
		with_packages = Str.join_with(
			[
				"              chmod = \"\${pkgs.coreutils}/bin/chmod\";",
				"              roc_packages = [ { name = \"abc\"; path = inputs.\"roc-abc\".outPath; } { name = \"def\"; path = inputs.\"roc-def\".outPath; } ];",
				"              ln = \"\${pkgs.coreutils}/bin/ln\";",
				"            };",
				"",
			],
			"\n",
		)
		without = "              chmod = \"\${pkgs.coreutils}/bin/chmod\";\n            };\n"
		contents = |step| step.files.first().map_ok(|file| file.contents) ?? ""
		contents(script).contains(with_packages) and !contents(script).contains(without)
			and contents(library).contains(without) and !contents(library).contains("              roc_packages =")
			and !contents(library).contains("              ln =")
	}
	_ => False
}

# Inspection renders the bundles a build locks, and no output of its own for
# Roc packages.
expect match NixProvider.render(roc_project) {
	Ok(text) => text.contains("    \"roc-abc\" = { url = \"tarball+https://example.test/abc.tar.zst\"; flake = false; };\n")
		and !text.contains("blueprintRocPackages") and !text.contains("roc-ghi")
		and !text.contains("shellHook")
	Err(_) => False
}

# A project whose Roc packages no build uses asks Nix for none of them.
expect Locks.inputs({ ..roc_project, builds: [TestData.library] }).map_ok(|inputs| inputs.map(|input| input.name)) == Ok(["default", "assets"])

# Generate produces no provider command or observation and never writes authority.
expect match plan_fixture(Request.Generate) {
	Ok({ steps: [plan] }) => plan.action == Generate
		and plan.argv.is_empty() and plan.operations.len() == 1
		and !plan.files.any(|file| file.path == TestData.layout.lock_path)
	_ => False
}

# Generate orders all builds dependency-first, sharing dependencies once even
# when consumers precede them and more than one root needs the same library.
expect match plan_locks {
	Ok(locks) => {
		project = TestData.project({
			..TestData.data,
			builds: [
				TestData.application,
				{ ..TestData.application, name: "other" },
				TestData.library,
			],
		})
		match NixProvider.plan(
			project,
			Request.Generate,
			"x86_64-linux",
			TestData.layout,
			locks,
		) {
			Ok({ steps: [plan] }) =>
				plan.artifacts.map(|artifact| artifact.name) ==
					["library", "app", "other"]
					and plan.artifacts.map(|artifact| artifact.dependencies) ==
						[[], ["library"], ["library"]]
			_ => False
		}
	}
	Err(_) => False
}

# Request selection never shrinks root inputs or causes an implicit relock.
expect match (
	plan_fixture(Request.Build("library")),
	plan_fixture(Request.Shell("default")),
) {
	(Ok({ steps: [build] }), Ok({ steps: [shell] })) => {
		build_lock = build.files.find_first(|f| f.path == "/generated/flake.lock")
		shell_lock = shell.files.find_first(|f| f.path == "/generated/flake.lock")
		build_lock == shell_lock and match shell.files.first() {
			Ok(file) => file.contents.contains(
				"\"assets\" = { url = \"path:/project/assets\"; "
					.concat("flake = false; };"),
			)
			Err(_) => False
		}
	}
	_ => False
}

# Unknown requests and NUL task extras fail before producing any effect recipe.
expect [
	Request.Shell("missing"),
	Request.Run("missing", []),
	Request.Build("missing"),
	Request.Run("check", [Str.from_utf8([0]) ?? ""]),
]
	.all(|request| plan_fixture(request).is_err())

# Unsupported features, targets and selected providers reject before effects.
expect match plan_locks {
	Ok(locks) => {
		bad = [
			{ ..TestData.data, requires_: ["sources", "builds", "future"] },
			{
				..TestData.data,
				sources: [{ name: "default", provider: { name: "guix", version: 1, ref: "channels" } }],
			},
		]
		bad.all(
			|data| NixProvider.plan(
				TestData.project(data),
				Request.Build("app"),
				"x86_64-linux",
				TestData.layout,
				locks,
			).is_err(),
		)
	}
	Err(_) => False
}

# The dependency closure includes each builder's provider requirements.
expect {
	foreign_builder = {
		..TestData.builder,
		name: "foreign",
		tools: [{ source: "guix", name: "python@3:out" }],
	}
	data = {
		..TestData.data,
		sources: [unstable, { name: "guix", provider: { name: "guix", version: 1, ref: "channels" } }],
		environments: [TestData.builder, foreign_builder],
		builds: [
			TestData.application,
			{ ..TestData.library, environment: "foreign" },
		],
	}
	project = TestData.project(data)
	match resolved(project, native_lock) {
		Ok(locks) => NixProvider.plan(
			project,
			Request.Shell("default"),
			"x86_64-linux",
			TestData.layout,
			locks,
		).is_ok()
			and NixProvider.plan(
				project,
				Request.Build("app"),
				"x86_64-linux",
				TestData.layout,
				locks,
			).is_err()
		Err(_) => False
	}
}

# Reordering declarations preserves authority identity; overlay order does not.
expect {
	url = "github:NixOS/nixpkgs/nixos-unstable"
	data = {
		..TestData.data,
		inputs: [
			{ name: "first", url },
			{ name: "second", url },
		],
		environments: [
			{ ..TestData.builder, overlays: ["first", "second"] },
			{ ..TestData.builder, name: "other" },
		],
	}
	native = native_lock.replace_each(
		"\"default\": \"default\"",
		"\"default\": \"default\", \"first\": \"default\", \"second\": \"default\"",
	)
	project = TestData.project(data)
	match resolved(project, native) {
		Ok(locks) => {
			reordered = TestData.project({
				..data,
				inputs: [
					{ name: "second", url },
					{ name: "first", url },
				],
				environments: [
					{ ..TestData.builder, name: "other" },
					{ ..TestData.builder, overlays: ["first", "second"] },
				],
			})
			reversed = TestData.project({
				..data,
				environments: [
					{ ..TestData.builder, overlays: ["second", "first"] },
					{ ..TestData.builder, name: "other" },
				],
			})
			NixProvider.plan(
				reordered,
				Request.Build("app"),
				"x86_64-linux",
				TestData.layout,
				locks,
			).is_ok()
				and NixProvider.plan(
					reversed,
					Request.Build("app"),
					"x86_64-linux",
					TestData.layout,
					locks,
				).is_err()
		}
		Err(_) => False
	}
}

# Out-of-tree roots work; overlapping sources, authority or generated files do not.
expect match plan_locks {
	Ok(locks) => {
		layouts = [
			Layout.{
				project_root: "/project",
				workspace: "/project/assets/work",
				generated_root: "/generated",
				lock_path: "/authority/lock",
			},
			Layout.{
				project_root: "/project",
				workspace: "/work",
				generated_root: "/authority/lock/nix",
				lock_path: "/authority/lock",
			},
			Layout.{
				project_root: "/project",
				workspace: "/work",
				generated_root: "/generated",
				lock_path: "/generated/flake.lock",
			},
			Layout.{
				project_root: "/project",
				workspace: "/work",
				generated_root: "/generated",
				lock_path: "/generated/flake.nix/lock",
			},
			Layout.{
				project_root: "/project",
				workspace: "/work/../unsafe",
				generated_root: "/generated",
				lock_path: "/authority/lock",
			},
		]
		layouts.all(
			|layout| NixProvider.plan(
				TestData.project(TestData.data),
				Request.Build("app"),
				"x86_64-linux",
				layout,
				locks,
			).is_err(),
		)
	}
	Err(_) => False
}

# File/directory conflicts fail in pure preflight and both update entry points,
# before lock reads, VerifyLocal or staging can have effects.
expect ["flake.nix", "flake.lock"].all(
	|file| {
		["", "/child"].all(
			|suffix| {
				layout = Layout.{
					project_root: "/project",
					workspace: "/generated/${file}${suffix}",
					generated_root: "/generated",
					lock_path: "/authority/inputs.lock",
				}
				project = TestData.project(TestData.data)
				NixProvider.preflight(
					project,
					Request.Build("app"),
					"x86_64-linux",
					layout,
				).is_err()
					and NixProvider.preflight(
						project,
						Request.Generate,
						"x86_64-linux",
						layout,
					).is_err()
					and NixProvider.local_checks(project, "x86_64-linux", layout).is_err()
					and NixProvider.update_files(project, "x86_64-linux", layout).is_err()
			},
		)
	},
)

# Containment alone is fine when the workspace does not collide with a file.
expect NixProvider.preflight(
	TestData.project(TestData.data),
	Request.Build("app"),
	"x86_64-linux",
	Layout.{
		project_root: "/project",
		workspace: "/generated/work",
		generated_root: "/generated",
		lock_path: "/authority/inputs.lock",
	},
).is_ok()

# Update exposes all local source paths for pre-effect consumer safety checks.
expect NixProvider.local_checks(
	TestData.project(TestData.data),
	"x86_64-linux",
	TestData.layout,
) == Ok(["/project/assets"])

# Explicit update files contain only derivatives, not a second lock authority.
expect match NixProvider.update_files(
	TestData.project(TestData.data),
	"x86_64-linux",
	TestData.layout,
) {
	Ok(files) => files.map(|file| file.path) == [
		"/generated/flake.nix",
	]
	Err(_) => False
}

# Shared workflow input uses the same supplied authority as atomic requests.
workflow_project : Spec
workflow_project = TestData.project(TestData.workflow_data)

workflow_plan : Request -> Try(Steps, Str)
workflow_plan = |request| NixProvider.plan(
	workflow_project,
	request,
	"x86_64-linux",
	TestData.layout,
	plan_locks?,
)

# The maximum repeated build sequence shares a large immutable recipe, not
# artifacts: all 4096 explicit operations still observe their own caller.
expect {
	var $payload = "x"
	while $payload.to_utf8().len() < 524288 {
		$payload = $payload.concat($payload)
	}
	var $steps = [BuildArtifact("library")]
	while $steps.len() < 4096 {
		$steps = $steps.concat($steps)
	}
	project = TestData.project({
		..TestData.workflow_data,
		builds: [{ ..TestData.library, run: ["true", $payload] }],
		workflows: [{ name: "large", steps: $steps }],
	})
	plan = NixProvider.plan(
		project,
		Request.Workflow("large"),
		"x86_64-linux",
		TestData.layout,
		plan_locks?,
	)?
	plan.steps.len() == 4096 and plan.steps.all(
		|step| step.action == Build("library")
			and step.artifacts.map(|artifact| artifact.name) == ["library"]
			and step.operations.keep_if(
				|operation| match operation {
					Isolation(_) => True
					_ => False
				},
			).len() == 1,
	) and match plan.steps.first() {
		Ok(step) => match step.files.first() {
			Ok(file) => file.contents.to_utf8().len() > 524288
			Err(_) => False
		}
		Err(_) => False
	}
}

# Sharing one task's templates must key on exact extras, including repetitions
# separated by different argv, empty strings, controls and literal shell text.
expect {
	extras = [
		["", "two words", "--literal", "a\nb", "$HOME"],
		["two", "words", "", "a\tb", "\\", "\""],
		[],
		["", "two words", "--literal", "a\nb", "$HOME"],
	]
	project = {
		..workflow_project,
		workflows: [
			{
				name: "argv",
				steps: extras.map(
					|extra| RunTask("check", extra),
				),
			},
		],
	}
	plan = NixProvider.plan(
		project,
		Request.Workflow("argv"),
		"x86_64-linux",
		TestData.layout,
		plan_locks?,
	)?
	prefix = [
		"nix",
		"develop",
		"--no-update-lock-file",
		"--no-write-lock-file",
		"path:/generated#devShells.x86_64-linux.blueprint-env-builder",
		"--command",
		"python3",
		"check.py",
		"configured argument",
	]
	plan.steps.map(|step| step.argv) == extras.map(|extra| prefix.concat(extra))
		and plan.steps.map(|step| step.action) == [
			Run("check"),
			Run("check"),
			Run("check"),
			Run("check"),
		]
}

# The allowance callers get is 16 MiB. The expects below hold its accounting
# with allowances of a few kilobytes, through the same code.
expect NixProvider.workflow_budget == 16 * 1024 * 1024

over_budget : Str
over_budget = "workflow plan exceeds 16 MiB of distinct rendered requests"

## What one request costs a workflow: its rendered flake and its argv.
request_bytes : Spec, Request -> Try(U64, Str)
request_bytes = |project, request| {
	prepared = NixProvider.prepare_atomic(Project.validate(project)?, request, "x86_64-linux", TestData.layout, Unlimited)?
	Ok(prepared.contents.to_utf8().len() + prepared.argv.fold(0, |n, arg| n + arg.to_utf8().len()))
}

within : Spec, Str, U64 -> Try({}, Str)
within = |project, workflow, allowance| {
	_ = NixProvider.prepare_within(project, Request.Workflow(workflow), "x86_64-linux", TestData.layout, allowance)?
	Ok({})
}

# Distinct requests add up, each counting every rendered system. The request
# that crosses the allowance is the one refused: three requests fit in exactly
# their own size, the fourth needs its own bytes too, to the byte.
expect {
	var $payload = "x"
	while $payload.to_utf8().len() < 1024 {
		$payload = $payload.concat($payload)
	}
	names = ["one", "two", "three", "four"]
	project = TestData.project({
		..TestData.workflow_data,
		systems: NixProvider.supported_systems,
		builds: names.map(
			|name| {
				..TestData.library,
				name,
				run: ["x", $payload],
			},
		),
		workflows: [
			{
				name: "below",
				steps: [
					BuildArtifact("one"),
					BuildArtifact("two"),
					BuildArtifact("three"),
				],
			},
			{ name: "over", steps: names.map(|name| BuildArtifact(name)) },
			{ name: "again", steps: names.concat(names).map(|name| BuildArtifact(name)) },
		],
	})
	one = request_bytes(project, Request.Build("one"))?
	four = request_bytes(project, Request.Build("four"))?
	three = one + request_bytes(project, Request.Build("two"))? + request_bytes(project, Request.Build("three"))?
	locks = plan_locks?
	below = NixProvider.plan_within(
		project,
		Request.Workflow("below"),
		"x86_64-linux",
		TestData.layout,
		locks,
		three,
	)?
	# The payload is rendered once for each of the four systems.
	one > 4 * 1024 and one < 64 * 1024
		and below.steps.len() == 3
		and within(project, "below", three) == Ok({})
		and within(project, "below", three - 1) == Err(over_budget)
		and within(project, "over", three) == Err(over_budget)
		and within(project, "over", three + four - 1) == Err(over_budget)
		and within(project, "over", three + four) == Ok({})
		# A repeated request is the same recipe and costs nothing more.
		and within(project, "again", three + four) == Ok({})
		and NixProvider.plan_within(
			project,
			Request.Workflow("over"),
			"x86_64-linux",
			TestData.layout,
			locks,
			three,
		).map_ok(|plan| plan.steps) == Err(over_budget)
}

# One valid atomic step can exceed the allowance through its dependency
# closure alone: every definition of the closure is charged as it is emitted.
expect {
	var $dependencies = []
	var $index = 0.U64
	while $index < 63 {
		$dependencies = $dependencies.append({
			..TestData.library,
			name: "dep-${$index.to_str()}",
			run: ["x", "payload"],
		})
		$index = $index + 1
	}
	project = TestData.project({
		..TestData.workflow_data,
		systems: NixProvider.supported_systems,
		builds: $dependencies.append({
			..TestData.library,
			name: "root",
			needs: $dependencies.map(|build| build.name),
		}),
		workflows: [{ name: "large", steps: [BuildArtifact("root")] }],
	})
	closure = request_bytes(project, Request.Build("root"))?
	leaf = request_bytes(project, Request.Build("dep-0"))?
	Project.validate(project).is_ok()
		and Project.build_closure(project, "root").map_ok(List.len) == Ok(64)
		# The closure is 64 definitions on four systems, not one.
		and closure > leaf
		and within(project, "large", closure) == Ok({})
		and within(project, "large", closure - 1) == Err(over_budget)
		and within(project, "large", leaf) == Err(over_budget)
		and NixProvider.plan_within(
			project,
			Request.Workflow("large"),
			"x86_64-linux",
			TestData.layout,
			plan_locks?,
			closure - 1,
		).map_ok(|plan| plan.steps) == Err(over_budget)
}

# A closure exactly at the allowance succeeds (even repeated); adding one
# byte to its last definition fails before returning any executable prefix.
expect {
	allowance = 65536
	var $payload = "x"
	while $payload.to_utf8().len() < allowance {
		$payload = $payload.concat($payload)
	}
	var $dependencies = []
	var $index = 0.U64
	while $index < 15 {
		$dependencies = $dependencies.append({
			..TestData.library,
			name: "dep-${$index.to_str()}",
			run: ["x", "payload"],
		})
		$index = $index + 1
	}
	project = Project.validate(
		TestData.project({
			..TestData.workflow_data,
			builds: $dependencies.append({
				..TestData.library,
				name: "root",
				run: ["x", ""],
				needs: $dependencies.map(|build| build.name),
			}),
			workflows: [
				{
					name: "limit",
					steps: [BuildArtifact("root"), BuildArtifact("root")],
				},
			],
		}),
	)?
	bytes = request_bytes(project, Request.Build("root"))?
	padding = Str.from_utf8($payload.to_utf8().take_first(allowance - bytes)) ?? ""
	at_limit = {
		..project,
		builds: project.builds.map(
			|build| if build.name == "root" {
				{ ..build, run: ["x", padding] }
			} else build,
		),
	}
	over_limit = {
		..at_limit,
		builds: at_limit.builds.map(
			|build| if build.name == "root" {
				{ ..build, run: ["x", padding.concat("x")] }
			} else build,
		),
	}
	locks = plan_locks?
	plan = NixProvider.plan_within(
		at_limit,
		Request.Workflow("limit"),
		"x86_64-linux",
		TestData.layout,
		locks,
		allowance,
	)?
	bytes < allowance and padding.to_utf8().len() == allowance - bytes
		and plan.steps.len() == 2 and plan.steps.all(
			|step| match step.files.first() {
				Ok(flake) => flake.contents.to_utf8().len()
					+ step.argv.fold(0, |n, arg| n + arg.to_utf8().len()) == allowance
				Err(_) => False
			},
		) and Project.validate(over_limit).is_ok()
		and within(at_limit, "limit", allowance) == Ok({})
		and within(over_limit, "limit", allowance) == Err(over_budget)
		and within(over_limit, "limit", allowance + 1) == Ok({})
		and NixProvider.plan_within(
			over_limit,
			Request.Workflow("limit"),
			"x86_64-linux",
			TestData.layout,
			locks,
			allowance,
		).map_ok(|sequence| sequence.steps) == Err(over_budget)
		# Callers reach the same accounting with the 16 MiB allowance.
		and NixProvider.preflight(over_limit, Request.Workflow("limit"), "x86_64-linux", TestData.layout) == Ok({})
}

# The shared renderer charges every actual byte, including escaped Raw,
# environment/system scaffolding and command argv: exact fits, one less fails.
expect {
	project = Project.validate({
		..workflow_project,
		systems: NixProvider.supported_systems,
		requires_: workflow_project.requires_.append("raw"),
		raw: [
			{
				backend: "nix",
				target: "flake",
				value: Value.Attrs([{ name: "note", value: Value.Str("é\n\\\"") }]),
			},
		],
	})?
	request = Request.Run("check", ["", "é\n\\\"", "--"])
	unlimited = NixProvider.prepare_atomic(
		project,
		request,
		"x86_64-linux",
		TestData.layout,
		Unlimited,
	)?
	bytes = unlimited.contents.to_utf8().len()
		+ unlimited.argv.fold(0, |n, arg| n + arg.to_utf8().len())
	NixProvider.prepare_atomic(
		project,
		request,
		"x86_64-linux",
		TestData.layout,
		Limited(bytes),
	) == Ok(unlimited) and NixProvider.prepare_atomic(
		project,
		request,
		"x86_64-linux",
		TestData.layout,
		Limited(bytes - 1),
	) == Err("workflow plan exceeds 16 MiB of distinct rendered requests")
}

# Nested workflows preserve order, repetitions, argv, files and operations
# exactly: each returned step equals its independently requested atomic plan.
expect {
	sequence = workflow_plan(Request.Workflow("ci"))?
	library = workflow_plan(Request.Build("library"))?
	edit = workflow_plan(
		Request.Run("check", ["", "two words", "--literal", "a\nb", "$HOME"]),
	)?
	check = workflow_plan(Request.Run("check", []))?
	bundle = workflow_plan(Request.Build("bundle"))?
	sequence.steps == library.steps.concat(edit.steps).concat(check.steps)
		.concat(bundle.steps).concat(check.steps).concat(bundle.steps)
		.concat(bundle.steps)
		and sequence.steps.map(|step| step.action) == [
			Build("library"),
			Run("check"),
			Run("check"),
			Build("bundle"),
			Run("check"),
			Build("bundle"),
			Build("bundle"),
		]
}

# Diamond dependencies occur once per build operation, not once per workflow.
# Every explicit build observes again, even consecutive builds of one name.
expect {
	sequence = workflow_plan(Request.Workflow("ci"))?
	sequence.steps.map(|step| step.artifacts.map(|artifact| artifact.name)) == [
		["library"],
		[],
		[],
		["library", "app", "other", "bundle"],
		[],
		["library", "app", "other", "bundle"],
		["library", "app", "other", "bundle"],
	] and sequence.steps.map(
		|step| step.operations.keep_if(
			|operation| match operation {
				Isolation(_) => True
				_ => False
			},
		).len(),
	) == [1, 0, 0, 1, 0, 1, 1]
}

# Each step reverifies local pins before staging; all derived locks are equal
# and none of the planned writes replaces the caller's authority.
expect {
	locks = plan_locks?
	before = Locks.encode(locks)
	sequence = workflow_plan(Request.Workflow("ci"))?
	atomic = workflow_plan(Request.Build("library"))?
	match atomic.steps {
		[library] => sequence.steps.all(
			|step| step.operations.first() == library.operations.first()
				and step.files.find_first(|file| file.path.ends_with("/flake.lock")) == library.files.find_first(|file| file.path.ends_with("/flake.lock"))
				and !step.files.any(
					|file| file.path == TestData.layout.lock_path,
				),
		) and Locks.encode(locks) == before
		_ => False
	}
}

# A selected task-only workflow ignores unrelated valid Guix environments.
# Selecting that environment later in a nested workflow rejects the whole plan.
expect {
	data = {
		..TestData.workflow_data,
		sources: [unstable, { name: "guix", provider: { name: "guix", version: 1, ref: "channels" } }],
		environments: [TestData.builder, foreign],
		tasks: TestData.data.tasks.append(
			{ name: "foreign", environment: "foreign", run: ["python"] },
		),
		workflows: TestData.workflow_data.workflows.concat([
			{
				name: "later",
				steps: [RunWorkflow("one"), RunWorkflow("foreign")],
			},
			{ name: "foreign", steps: [RunTask("foreign", [])] },
		]),
	}
	project = TestData.project(data)
	locks = resolved(project, native_lock)?
	first = NixProvider.plan(
		project,
		Request.Workflow("one"),
		"x86_64-linux",
		TestData.layout,
		locks,
	)?
	later = NixProvider.plan(
		project,
		Request.Workflow("later"),
		"x86_64-linux",
		TestData.layout,
		locks,
	)
	first.steps.map(|step| step.action) == [Run("check")]
		and later.is_err() and later.map_ok(|plan| plan.steps) == NixProvider.plan(
			project,
			Request.Run("foreign", []),
			"x86_64-linux",
			TestData.layout,
			locks,
		).map_ok(|plan| plan.steps)
		and NixProvider.preflight(
			project,
			Request.Workflow("later"),
			"x86_64-linux",
			TestData.layout,
		).is_err()
}

# A later build's transitive dependency provider is checked before returning
# even the valid first task, not just the explicitly named build environment.
expect {
	project = TestData.project({
		..TestData.workflow_data,
		sources: [unstable, { name: "guix", provider: { name: "guix", version: 1, ref: "channels" } }],
		environments: [TestData.builder, foreign],
		builds: [
			TestData.application,
			{ ..TestData.library, environment: "foreign" },
		],
		workflows: [
			{ name: "ci", steps: [RunTask("check", []), BuildArtifact("app")] },
		],
	})
	locks = resolved(project, native_lock)?
	first = NixProvider.plan(
		project,
		Request.Run("check", []),
		"x86_64-linux",
		TestData.layout,
		locks,
	)?
	later = NixProvider.plan(
		project,
		Request.Workflow("ci"),
		"x86_64-linux",
		TestData.layout,
		locks,
	)
	first.steps.map(|step| step.action) == [Run("check")]
		and later.is_err() and later.map_ok(|plan| plan.steps) == NixProvider.plan(
			project,
			Request.Build("app"),
			"x86_64-linux",
			TestData.layout,
			locks,
		).map_ok(|plan| plan.steps)
		and NixProvider.preflight(
			project,
			Request.Workflow("ci"),
			"x86_64-linux",
			TestData.layout,
		).is_err()
}

# Task-compatible target selection cannot hide a later unsupported build.
expect {
	project = { ..workflow_project, systems: ["aarch64-darwin"] }
	locks = plan_locks?
	NixProvider.plan(
		project,
		Request.Run("check", []),
		"aarch64-darwin",
		TestData.layout,
		locks,
	).is_ok() and NixProvider.plan(
		project,
		Request.Workflow("verify"),
		"aarch64-darwin",
		TestData.layout,
		locks,
	).map_ok(|plan| plan.steps) ==
		Err("sandboxed builds currently require target x86_64-linux")
		and NixProvider.preflight(
			project,
			Request.Workflow("verify"),
			"aarch64-darwin",
			TestData.layout,
		) == Err("sandboxed builds currently require target x86_64-linux")
}

# Missing or cyclic later build dependencies are whole-project failures,
# never partial plans that leave a valid first task available to execute.
expect {
	locks = plan_locks?
	[
		{ ..TestData.library, needs: ["missing"] },
		{ ..TestData.library, needs: ["app"] },
	].all(
		|library| {
			project = TestData.project({
				..TestData.workflow_data,
				builds: [TestData.application, library],
				workflows: [
					{
						name: "ci",
						steps: [RunTask("check", []), BuildArtifact("app")],
					},
				],
			})
			NixProvider.preflight(
				project,
				Request.Workflow("ci"),
				"x86_64-linux",
				TestData.layout,
			).is_err() and NixProvider.plan(
				project,
				Request.Workflow("ci"),
				"x86_64-linux",
				TestData.layout,
				locks,
			).is_err()
		},
	)
}

# A changed source needed by a later build rejects the supplied authority
# after successful pure preflight; planning cannot return a runnable prefix.
expect {
	project = {
		..workflow_project,
		build_sources: [{ name: "assets", ref: "path:./changed-assets" }],
	}
	NixProvider.preflight(
		project,
		Request.Workflow("verify"),
		"x86_64-linux",
		TestData.layout,
	) == Ok({}) and match NixProvider.plan(
		project,
		Request.Workflow("verify"),
		"x86_64-linux",
		TestData.layout,
		plan_locks?,
	) {
		Err(message) => message.contains("update")
		Ok(_) => False
	}
}

# Empty workflows, including nested empty expansion, return zero steps rather
# than an invented Generate request or a requirement to select an environment.
expect ["empty", "nothing"].all(
	|name| workflow_plan(Request.Workflow(name))
		.map_ok(|plan| plan.steps) == Ok([])
		and NixProvider.preflight(
			workflow_project,
			Request.Workflow(name),
			"x86_64-linux",
			TestData.layout,
		) == Ok({}),
)

# Empty expansion skips unrelated provider capability checks, not global
# required features, Raw, extensions, target declarations or semantic validity.
expect {
	project = TestData.project({
		..TestData.workflow_data,
		sources: [unstable, { name: "guix", provider: { name: "guix", version: 1, ref: "channels" } }],
		environments: [TestData.builder, foreign],
	})
	locks = resolved(project, native_lock)?
	NixProvider.plan(
		project,
		Request.Workflow("empty"),
		"x86_64-linux",
		TestData.layout,
		locks,
	).map_ok(|plan| plan.steps) == Ok([]) and [
		{
			..project,
			raw: [{ backend: "nix", target: "missing", value: Value.Attrs([]) }],
		},
		{
			..project,
			extensions: [{ kind: "service", name: "db", value: Value.Attrs([]) }],
		},
		{ ..project, tasks: [{ name: "bad", environment: "missing", run: ["x"] }] },
	].all(
		|invalid| NixProvider.preflight(
			invalid,
			Request.Workflow("empty"),
			"x86_64-linux",
			TestData.layout,
		).is_err() and NixProvider.plan(
			invalid,
			Request.Workflow("empty"),
			"x86_64-linux",
			TestData.layout,
			locks,
		).is_err(),
	)
}

# Keep all known markers so this no-op reaches provider feature preflight,
# rather than failing structural validation for missing build/workflow markers.
expect {
	project = {
		..workflow_project,
		requires_: workflow_project.requires_.append("future"),
	}
	Project.validate(project).is_ok() and NixProvider.preflight(
		project,
		Request.Workflow("empty"),
		"x86_64-linux",
		TestData.layout,
	) == Err("unsupported features: future") and NixProvider.plan(
		project,
		Request.Workflow("empty"),
		"x86_64-linux",
		TestData.layout,
		plan_locks?,
	).map_ok(|plan| plan.steps) == Err("unsupported features: future")
}

# No-op workflows still require a declared target, a safe caller layout and
# matching authority; absence of runnable steps never bypasses global checks.
expect {
	locks = plan_locks?
	unsafe = { ..TestData.layout, generated_root: "/authority/inputs.lock/nix" }
	changed = {
		..workflow_project,
		build_sources: [{ name: "assets", ref: "path:./changed-assets" }],
	}
	NixProvider.preflight(
		workflow_project,
		Request.Workflow("empty"),
		"aarch64-linux",
		TestData.layout,
	).is_err() and NixProvider.plan(
		workflow_project,
		Request.Workflow("empty"),
		"aarch64-linux",
		TestData.layout,
		locks,
	).is_err() and NixProvider.preflight(
		workflow_project,
		Request.Workflow("empty"),
		"x86_64-linux",
		unsafe,
	).is_err() and NixProvider.plan(
		workflow_project,
		Request.Workflow("empty"),
		"x86_64-linux",
		unsafe,
		locks,
	).is_err() and NixProvider.plan(
		changed,
		Request.Workflow("empty"),
		"x86_64-linux",
		TestData.layout,
		locks,
	).is_err()
}

# Unknown workflows, bad nested references, cycles and NUL extras are rejected
# through the provider boundary even when callers did not validate the Spec first.
expect {
	locks = plan_locks?
	workflow_plan(Request.Workflow("missing")).is_err() and [
		[RunWorkflow("missing")],
		[RunWorkflow("ci")],
		[RunTask("missing", [])],
		[BuildArtifact("missing")],
		[RunTask("check", [Str.from_utf8([0]) ?? ""])],
	].all(
		|steps| {
			project = { ..workflow_project, workflows: [{ name: "ci", steps }] }
			NixProvider.preflight(
				project,
				Request.Workflow("ci"),
				"x86_64-linux",
				TestData.layout,
			).is_err() and NixProvider.plan(
				project,
				Request.Workflow("ci"),
				"x86_64-linux",
				TestData.layout,
				locks,
			).is_err()
		},
	)
}

# The project of TestData, whose one environment also fetches a program.
fetching : Spec
fetching = {
	whole = TestData.project(TestData.data)
	{
		..whole,
		requires_: whole.requires_.concat(["programs", "expects"]),
		programs: [{ name: "tool", system: "x86_64-linux", urls: ["https://example.test/tool"], unpack: File, path: "" }],
		environment_programs: [{ environment: "builder", programs: ["tool"] }],
		expects: [{ environment: "builder", programs: ["git"] }],
	}
}

# Nix renders and plans its own part of an environment: what the environment
# fetches or expects is the Core's, and adds nothing to the flake or the plan.
expect {
	whole = TestData.project(TestData.data)
	locks = plan_locks?
	NixProvider.render(fetching).is_ok() and NixProvider.render(fetching) == NixProvider.render(whole)
		and [Request.Shell("default"), Request.Run("check", []), Request.Generate].all(
			|request| NixProvider.plan(fetching, request, "x86_64-linux", TestData.layout, locks).map_ok(|steps| steps.steps) == NixProvider.plan(whole, request, "x86_64-linux", TestData.layout, locks).map_ok(|steps| steps.steps),
		)
}

# A step that starts Nix says that the machine must have it, and why, so that
# one without it is told before anything happens. Generating files starts
# nothing.
expect {
	locks = plan_locks?
	last = |request| NixProvider.plan(TestData.project(TestData.data), request, "x86_64-linux", TestData.layout, locks).map_ok(|steps| steps.steps.map(|step| step.operations.last()))
	last(Request.Run("check", [])) == Ok([Ok(Present([{ program: "nix", because: "environment builder takes default#python3 from the Nix source default" }]))])
		and last(Request.Build("app")).map_ok(|steps| steps.last()) == Ok(Ok(Ok(Present([{ program: "nix", because: "build app runs in the Nix sandbox" }]))))
		and NixProvider.plan(TestData.project(TestData.data), Request.Generate, "x86_64-linux", TestData.layout, locks).map_ok(
			|steps| steps.steps.any(
				|step| step.operations.any(
					|operation|
						match operation {
							Present(_) => True
							_ => False
						},
				),
			),
		) == Ok(False)
}

expect NixProvider.realises({ name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-unstable" }) and !NixProvider.realises({ name: "guix", version: 1, ref: "https://git.savannah.gnu.org/git/guix.git" }) and !NixProvider.realises({ name: "", version: 0, ref: "" })
expect (NixProvider.provider.realises)({ name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-unstable" }) and !(NixProvider.provider.realises)({ name: "", version: 0, ref: "" })

# An update says the machine must have Nix, and why: the first thing declared
# that only Nix resolves. A named update asks the same.
expect {
	project = TestData.project(TestData.data)
	(NixProvider.provider.resolve)(project, "x86_64-linux", TestData.layout, All).map_ok(|resolution| resolution.present) == Ok([{ program: "nix", because: "Blueprint.roc declares the Nix source default, which Nix resolves" }])
		and NixProvider.resolving({ ..project, sources: [], environments: [], shells: [], tasks: [], builds: [], inputs: [{ name: "roc", url: "github:roc-lang/roc-overlay" }] }) == "Blueprint.roc declares the input roc, which Nix resolves"
		and NixProvider.resolving({ ..project, sources: [], environments: [], shells: [], tasks: [], builds: [] }) == "Blueprint.roc declares the source assets, which Nix locks"
}

# Each build reads its own project record; which files it selects is the
# host's to copy, not the recipe's.
expect {
	selected = NixProvider.render_build(TestData.library, { name: "builder", parents: [], tools: [{ source: "nix", name: "glibc" }], overlays: [] }, [], [], [], [], [], "x86_64-linux", [])
	selected.contains("project = projectFor ./project-library.json;") and
		selected.contains("name = \"nix#glibc\"; path = sets.\"nix\".\"glibc\";")
}

# Native flags/result schema never enter the consumer's build report path.
expect {
	step = { action: Build("app"), files: [], argv: ["nix", "build", "--print-out-paths", "example#app"], artifacts: [], operations: [] }
	NixProvider.build_argv(step, { rebuild: True }) == Ok(["nix", "build", "example#app", "--json", "--rebuild"])
}
expect NixProvider.build_result("[{\"drvPath\":\"/nix/store/recipe.drv\",\"outputs\":{\"out\":\"/nix/store/result\"}}]") == Ok({ build_identity: "/nix/store/recipe.drv", outputs: [{ name: "out", path: "/nix/store/result" }], metadata: [{ name: "derivation", value: Value.Str("/nix/store/recipe.drv") }] })
expect NixProvider.build_result("[]").is_err()
expect NixProvider.build_result("[{\"drvPath\":\"/nix/store/recipe.drv\",\"outputs\":{\"out\":\"/nix/store/result\"}}]\n/nix/store/result\n").is_err()

# Reproduction material contains selected pins only, not the whole lock or
# the final build identity. Original file hashes remain file identities.
expect {
	selected = { name: "upstream", url: "https://example.test/source.tar.gz", sha256: "a".repeat(64) }
	unrelated = { name: "unused", url: "https://example.test/other.tar.gz", sha256: "b".repeat(64) }
	build = { name: "copy", environment: "builder", inputs: ["upstream"], needs: [], run: ["cp", "input", "out"], output: "out" }
	rendered = NixProvider.render_build(build, { name: "builder", parents: [], tools: [{ source: "nix", name: "coreutils" }], overlays: [] }, [], [], [], [], [selected, unrelated], "x86_64-linux", [])
	rendered.contains("blueprint-input-evidence") and rendered.contains(selected.sha256)
		and !rendered.contains(unrelated.sha256) and !rendered.contains("build_identity")
		and rendered.contains("inputs.\"nix\".narHash")
}

# Preparation is evaluation-only and execution cannot reselect mutable source.
expect {
	step = { action: Build("app"), argv: ["nix", "build", "--no-link", "--print-out-paths", "example#app"], files: [], operations: [], artifacts: [{ provider: "nix", name: "app", installable: "example#app", output: "out", dependencies: [] }] }
	prepared = { build_identity: "/nix/store/captured.drv", outputs: [{ name: "out", path: "/nix/store/result" }] }
	NixProvider.build_prepare_argv(step) == Ok(["nix", "derivation", "show", "example#app", "--option", "allow-import-from-derivation", "false"])
		and NixProvider.build_execute_argv(step, prepared, { rebuild: False }) == Ok(["nix", "build", "--no-link", "/nix/store/captured.drv^*", "--json"])
		and NixProvider.build_prepared("{\"/nix/store/captured.drv\":{\"outputs\":{\"out\":{\"path\":\"/nix/store/result\"}}}}") == Ok(prepared)
		and NixProvider.build_prepared("{}").is_err()
		and NixProvider.build_prepared("{\"/tmp/not-store.drv\":{\"outputs\":{}}}").is_err()
		and NixProvider.build_prepared("{\"/nix/store/captured.drv\":{\"outputs\":{\"out\":{}}}}").is_err()
}

# Executor bootstrap ownership is independent of the package supplying tools.
expect {
	build = { name: "copy", environment: "builder", inputs: [], needs: [], run: ["cp", "input", "out"], output: "out" }
	rendered = NixProvider.render_build(build, { name: "builder", parents: [], tools: [{ source: "tools", name: "coreutils" }], overlays: [] }, [], [], [], [], [], "x86_64-linux", ["bootstrap"])
	rendered.contains("pkgs = sets.\"bootstrap\";")
		and rendered.contains("sets.\"tools\".\"coreutils\"")
		and rendered.contains("inputs.\"bootstrap\".narHash")
}

# Actual Nix 2.34 schema: one recipe inside a versioned envelope, with
# basename paths. Never choose arbitrarily among multiple requested recipes.
expect {
	prepared = { build_identity: "/nix/store/captured.drv", outputs: [{ name: "out", path: "/nix/store/result" }] }
	NixProvider.build_prepared("{\"version\":4,\"derivations\":{\"captured.drv\":{\"outputs\":{\"out\":{\"path\":\"result\"}}}}}") == Ok(prepared)
		and NixProvider.build_prepared("{\"version\":5,\"derivations\":{}}").is_err()
		and NixProvider.build_prepared("{\"version\":4,\"derivations\":{}}").is_err()
		and NixProvider.build_prepared("{\"version\":4,\"derivations\":{\"one.drv\":{},\"two.drv\":{}}}").is_err()
		and NixProvider.build_prepared("{\"version\":4,\"derivations\":{\"../captured.drv\":{\"outputs\":{\"out\":{\"path\":\"result\"}}}}}").is_err()
		and NixProvider.build_prepared("{\"version\":4,\"derivations\":{\"captured.drv\":{\"outputs\":{\"out\":{\"path\":\"../result\"}}}}}").is_err()
}

# Entering an environment as data: the shell's installable is printed, not
# entered, and only what Nix would export reaches the caller.
expect {
	step = { action: Shell("default"), argv: ["nix", "develop", "--no-update-lock-file", "--no-write-lock-file", "path:/p/.blueprint#devShells.x86_64-linux.default"], files: [], operations: [], artifacts: [] }
	NixProvider.activation_argv(step) == Ok(["nix", "print-dev-env", "--json", "--no-update-lock-file", "--no-write-lock-file", "path:/p/.blueprint#devShells.x86_64-linux.default"])
		and NixProvider.activation_argv({ ..step, argv: ["nix", "build", "x"] }).is_err()
}
expect NixProvider.activation("{\"variables\":{\"PATH\":{\"type\":\"exported\",\"value\":\"/nix/store/a-git/bin:/nix/store/b-zig/bin\"},\"NIX_CFLAGS\":{\"type\":\"exported\",\"value\":\"-O2\"},\"HOME\":{\"type\":\"exported\",\"value\":\"/homeless\"},\"local\":{\"type\":\"var\",\"value\":\"x\"},\"fn\":{\"type\":\"function\"}}}") == Ok({ path: [{ directory: "/nix/store/a-git/bin", origin: "nix" }, { directory: "/nix/store/b-zig/bin", origin: "nix" }], variables: [{ name: "NIX_CFLAGS", value: "-O2", origin: "nix" }] })
expect NixProvider.activation("{}").is_err() and NixProvider.activation("not json").is_err()

# Project systems retain Windows for fetched programs; Nix outputs use only
# supported systems. Scoped tools survive inherited environment normalization.
mixed_systems : Spec
mixed_systems = {
	..mk(simple),
	systems: ["x86_64-linux", "x86_64-windows"],
	requires_: ["system-tools"],
	environments: [{ ..base, name: "parent", tools: [] }, { ..base, tools: [], parents: ["parent"] }],
	system_tools: [{ environment: "parent", system: "x86_64-linux", tools: [{ source: "default", name: "git" }] }],
}

expect {
	text = NixProvider.render(mixed_systems)?
	text.contains("\"x86_64-linux\" = let") and !text.contains("\"x86_64-windows\" = let")
		and text.contains("sets.\"default\".\"git\"")
		and NixProvider.preflight(mixed_systems, Request.Shell("default"), "x86_64-linux", TestData.layout).is_ok()
		and NixProvider.update_files(mixed_systems, "x86_64-linux", TestData.layout).is_ok()
}

# A declared but unused Nix source does not turn Windows into a Nix system.
expect NixProvider.render({ ..mixed_systems, environments: [{ ..base, tools: [] }], system_tools: [] }).is_ok()

# Global tools really apply to Windows, so full rendering refuses them. A
# selected Unix operation must not validate unrelated Windows capabilities.
expect {
	project = { ..mk(simple), systems: mixed_systems.systems, environments: [{ ..base, tools: [{ source: "default", name: "git" }] }] }
	NixProvider.render(project) == Err("unsupported Nix target x86_64-windows")
		and NixProvider.preflight(project, Request.Shell("default"), "x86_64-linux", TestData.layout).is_ok()
		and NixProvider.preflight(project, Request.Shell("default"), "x86_64-windows", TestData.layout) == Err("unsupported Nix target x86_64-windows")
}

# A Windows-scoped tool cannot be silently discarded or replaced by PATH.
expect {
	project = { ..mixed_systems, system_tools: [{ environment: "parent", system: "x86_64-windows", tools: [{ source: "default", name: "git" }] }] }
	NixProvider.render(project) == Err("unsupported Nix target x86_64-windows")
		and NixProvider.preflight(project, Request.Shell("default"), "x86_64-windows", TestData.layout).is_err()
}

# Provider-owned builds render only their executor's supported domain, even
# when the same project locks portable downloads for macOS and Windows.
expect {
	project = { ..TestData.project(TestData.data), systems: ["x86_64-linux", "aarch64-darwin", "x86_64-windows"], tasks: [], shells: [] }
	text = NixProvider.render(project)?
	outputs = text.split_on("      packages = {").last()?
	outputs.contains("\"x86_64-linux\" = let artifacts")
		and !outputs.contains("\"aarch64-darwin\" = let artifacts")
		and !outputs.contains("\"x86_64-windows\" = let artifacts")
		and ["aarch64-darwin", "x86_64-windows"].all(|target| NixProvider.preflight(project, Request.Build("app"), target, TestData.layout) == Err("sandboxed builds currently require target x86_64-linux"))
}

# A Unix-only project's generated bytes remain stable when adding provider-free
# Windows support. The global Systems declaration itself stays authoritative.
expect {
	project = { ..mixed_systems, systems: ["x86_64-linux"] }
	NixProvider.render(mixed_systems) == NixProvider.render(project)
		and mixed_systems.systems == ["x86_64-linux", "x86_64-windows"]
}
