# Shared normalization, reference checks and bounded graph expansion.
import Spec
import Value

## Shared pure semantic boundary. Validation observes neither PATH nor the host.
## It normalizes defaults and inheritance, and is safe to repeat on emitted Spec.
Project :: [].{
	ProviderName : [Nix, Guix]

	## Order by UTF-8 bytes, for declaration-order-independent output.
	bytewise : Str, Str -> [Before, Same, After]
	bytewise = |a, b| {
		left = a.to_utf8()
		right = b.to_utf8()
		var $i = 0
		while $i < left.len() and $i < right.len() {
			l = left.get($i) ?? 0
			r = right.get($i) ?? 0
			if l < r {
				return Before
			}
			if l > r {
				return After
			}
			$i = $i + 1
		}
		if left.len() < right.len() Before else if left.len() > right.len() After else Same
	}

	valid_name : Str -> Bool
	valid_name = |name| !name.is_empty() and name.to_utf8().all(|b| letter(b) or (b >= '0' and b <= '9') or b == '-' or b == '_')

	valid_task_name : Str -> Bool
	valid_task_name = |name| !name.is_empty() and name.split_on(".").all(valid_name)

	## A file name on PATH: no separators, and no leading dash or dot.
	valid_command_name : Str -> Bool
	valid_command_name = |name| {
		bytes = name.to_utf8()
		first_ok = match bytes.first() {
			Ok(b) => b != '-' and b != '.'
			Err(_) => False
		}
		first_ok and bytes.all(|b| letter(b) or (b >= '0' and b <= '9') or b == '-' or b == '_' or b == '.' or b == '+')
	}

	letter : U8 -> Bool
	letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')

	clean : Str -> Bool
	clean = |text| !text.is_empty() and text.to_utf8().all(|b| b > 32 and b != 127)

	## Generic syntax only. Provider grammar is checked once intent is known.
	tool : Str -> Try(Spec.Tool, Str)
	tool = |text| {
		(source, name) = match text.split_on("#") {
			[suffix] => ("default", suffix)
			[prefix, suffix] => (prefix, suffix)
			_ => return Err("invalid tool reference: ${text}")
		}
		if !valid_name(source) or !clean(name) {
			return Err("invalid tool reference: ${text}")
		}
		Ok({ source, name })
	}

	## The attributes a Nix tool name selects, in order. Segments are separated
	## by dots; a segment in double quotes is one attribute whose name may
	## itself contain dots, as in `zigpkgs."0.16.0"`.
	nix_path : Str -> Try(List(Str), [BadNixPath])
	nix_path = |name| {
		parts = name.split_on("\"")
		if parts.len() % 2 == 0 {
			return Err(BadNixPath)
		}
		last = parts.len() - 1
		var $segments = []
		var $index = 0
		for part in parts {
			after = $index > 0
			before = $index < last
			if $index % 2 == 1 {
				if !nix_quoted(part) {
					return Err(BadNixPath)
				}
				$segments = $segments.append(part)
			} else if part == "" {
				# Nothing may be missing between two quoted segments, and a
				# name is never empty.
				if after == before {
					return Err(BadNixPath)
				}
			} else if part == "." {
				if !(after and before) {
					return Err(BadNixPath)
				}
			} else {
				if (after and !part.starts_with(".")) or (before and !part.ends_with(".")) {
					return Err(BadNixPath)
				}
				leading = if after part.drop_prefix(".") else part
				inner = if before leading.drop_suffix(".") else leading
				plain = inner.split_on(".")
				if !plain.all(nix_identifier) {
					return Err(BadNixPath)
				}
				$segments = $segments.concat(plain)
			}
			$index = $index + 1
		}
		Ok($segments)
	}

	nix_identifier : Str -> Bool
	nix_identifier = |part| {
		bytes = part.to_utf8()
		!bytes.is_empty() and bytes.all(|b| letter(b) or (b >= '0' and b <= '9') or b == '_' or b == '-' or b == '\'')
	}

	nix_quoted : Str -> Bool
	nix_quoted = |part| {
		bytes = part.to_utf8()
		!bytes.is_empty() and bytes.all(|b| letter(b) or (b >= '0' and b <= '9') or b == '_' or b == '-' or b == '.' or b == '+')
	}

	## Deliberately conservative native grammars: Nix attribute paths of
	## identifiers and quoted segments; Guix package[@version][:output]
	## specifications. No translation or probing.
	check_tool : ProviderName, Str -> Try({}, Str)
	check_tool = |provider, name| {
		valid = match provider {
			Nix => nix_path(name).is_ok()
			Guix => {
				parts = name.split_on(":")
				spec = parts.first() ?? ""
				versions = spec.split_on("@")
				parts.len() <= 2 and versions.len() <= 2 and parts.drop_first(1).all(valid_name) and versions.all(|part| !part.is_empty() and part.to_utf8().all(|b| letter(b) or (b >= '0' and b <= '9') or b == '-' or b == '_' or b == '.' or b == '+'))
			}
		}
		if valid Ok({}) else Err("invalid ${if provider == Nix "Nix" else "Guix"} tool: ${name}")
	}

	check_names : List(Str), Str -> Try({}, Str)
	check_names = |names, kind| {
		var $seen = []
		for name in names {
			if !(if kind == "Task" valid_task_name(name) else valid_name(name)) {
				return Err("invalid name for ${kind}: ${name}")
			}
			if $seen.contains(name) {
				return Err("Duplicate${kind}: ${name}")
			}
			$seen = $seen.append(name)
		}
		Ok({})
	}

	valid_ref : Str -> Bool
	valid_ref = |url| clean(url) and ["github:", "gitlab:", "sourcehut:", "flake:", "git+", "path:", "file:", "https://", "http://", "tarball+"].any(|prefix| url.starts_with(prefix) and !url.drop_prefix(prefix).is_empty())

	## A download URL names its bytes by itself: `https://<host>/<path>`, with
	## no credentials, query or fragment, and no empty, `.` or `..` segment.
	## `http://127.0.0.1`, with or without a port, is one too: nothing leaves
	## the machine, and it is how a test serves a download.
	valid_download_url : Str -> Bool
	valid_download_url = |url| {
		rest = if url.starts_with("https://") {
			url.drop_prefix("https://")
		} else if url.starts_with("http://127.0.0.1:") or url.starts_with("http://127.0.0.1/") {
			url.drop_prefix("http://")
		} else {
			return False
		}
		if rest.to_utf8().any(|b| b <= 32 or b >= 127 or b == '@' or b == '?' or b == '#' or b == '\\') {
			return False
		}
		match rest.split_on("/") {
			[authority, .. as segments] => {
				(host, port) = match authority.split_on(":") {
					[name] => (name, "0")
					[name, number] => (name, number)
					_ => return False
				}
				label = |part| {
					bytes = part.to_utf8()
					!bytes.is_empty() and bytes.first() != Ok('-') and bytes.last() != Ok('-') and bytes.all(|b| letter(b) or (b >= '0' and b <= '9') or b == '-')
				}
				host.split_on(".").all(label)
					and !port.is_empty() and port.to_utf8().len() <= 5 and port.to_utf8().all(|b| b >= '0' and b <= '9')
						and !segments.is_empty() and segments.all(|part| !part.is_empty() and part != "." and part != "..")
			}
			_ => False
		}
	}

	## Lexical containment only; the executor must also reject escaping symlinks.
	## Spaces are valid path bytes. Empty, dot and parent segments are not.
	valid_output : Str -> Bool
	valid_output = |path| !path.is_empty() and !path.contains("\\") and !path.contains(":") and path.to_utf8().all(|b| b >= 32 and b != 127) and path.split_on("/").all(|part| !part.is_empty() and part != "." and part != "..")

	## Local locked sources must be project-relative subtrees, not the project
	## root or machine-specific absolute paths. Remote references are not fetched.
	valid_build_source_ref : Str -> Bool
	valid_build_source_ref = |ref| {
		if ref.starts_with("path:") {
			path = ref.drop_prefix("path:").drop_prefix("./")
			return clean(ref) and valid_output(path) and !path.contains("?") and !path.contains("#")
		}
		clean(ref) and ["github:", "gitlab:", "sourcehut:", "git+https://", "git+http://", "git+ssh://", "https://", "http://", "tarball+https://", "tarball+http://"].any(|prefix| ref.starts_with(prefix) and !ref.drop_prefix(prefix).is_empty())
	}

	## Shared argv boundary for tasks and builds; arguments are never shell-split.
	check_argv : List(Str), Str -> Try({}, Str)
	check_argv = |argv, name| {
		if argv.is_empty() or (argv.first() ?? "").is_empty() {
			return Err("empty argv: ${name}")
		}
		if argv.len() > 4096 or argv.fold(0, |size, arg| size + arg.to_utf8().len()) > 1048576 {
			return Err("argv exceeds 4096 arguments or 1 MiB: ${name}")
		}
		if argv.any(|arg| arg.to_utf8().contains(0)) {
			return Err("NUL in argv: ${name}")
		}
		Ok({})
	}

	validate : Spec -> Try(Spec, Str)
	validate = |spec| {
		if spec.format.major != Spec.current_format.major {
			return Err("unsupported Spec major")
		}
		if spec.name.is_empty() or spec.name.to_utf8().any(|b| b < 32 or b == 127) {
			return Err("invalid name for project")
		}
		if spec.systems.is_empty() {
			return Err("no systems")
		}
		for system in spec.systems {
			parts = system.split_on("-")
			if parts.len() != 2 or !parts.all(|part| !part.is_empty() and part.to_utf8().all(|b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_')) {
				return Err("invalid system: ${system}")
			}
		}
		declared_systems = unique(spec.systems)
		if spec.builds.len() > 1024 or spec.build_sources.len() > 1024 {
			return Err("builds or build sources exceed 1024 declarations")
		}
		if spec.builds.fold(0, |count, build| count + build.needs.len() + build.inputs.len()) > 8192 {
			return Err("build graph exceeds 8192 references")
		}
		if spec.workflows.len() > 1024 {
			return Err("workflows exceed 1024 declarations")
		}
		if spec.workflows.fold(0, |n, workflow| n + workflow.steps.len()) > 8192 {
			return Err("workflow graph exceeds 8192 steps")
		}
		check_names(spec.workflows.map(|w| w.name), "Workflow")?
		check_names(spec.build_sources.map(|s| s.name), "BuildSource")?
		check_names(spec.builds.map(|b| b.name), "Build")?
		check_names(spec.sources.map(|s| s.name), "Source")?
		check_names(spec.inputs.map(|i| i.name), "Input")?
		check_names(spec.environments.map(|e| e.name), "Environment")?
		check_names(spec.shells.map(|s| s.name), "Shell")?
		check_names(spec.tasks.map(|t| t.name), "Task")?
		sources = if spec.sources.any(|s| s.name == "default") spec.sources else [{ name: "default", provider: Auto }].concat(spec.sources)
		for source in sources {
			if spec.inputs.any(|i| i.name == source.name) {
				return Err("DuplicateInput: ${source.name}")
			}
			match source.provider {
				Auto => {}
				NixPackages(url) => if !valid_ref(url) {
					return Err("invalid Nix source: ${source.name}")
				}
				GuixPackages(url) => if !clean(url) {
					return Err("invalid Guix source: ${source.name}")
				}
			}
		}
		for source in spec.build_sources {
			if sources.any(|s| s.name == source.name) or spec.inputs.any(|i| i.name == source.name) {
				return Err("DuplicateInput: ${source.name}")
			}
			if !valid_build_source_ref(source.ref) {
				return Err("invalid build source reference: ${source.name}")
			}
		}
		if !spec.build_sources.is_empty() and !spec.requires_.contains("sources") {
			return Err("build sources require feature: sources")
		}
		if !spec.builds.is_empty() and !spec.requires_.contains("builds") {
			return Err("builds require feature: builds")
		}
		if !spec.workflows.is_empty() and !spec.requires_.contains("workflows") {
			return Err("workflows require feature: workflows")
		}
		if !spec.system_tools.is_empty() and !spec.requires_.contains("system-tools") {
			return Err("system tools require feature: system-tools")
		}
		for entry in spec.system_tools {
			if !spec.environments.any(|e| e.name == entry.environment) {
				return Err("unknown environment for system tools: ${entry.environment}")
			}
			if !declared_systems.contains(entry.system) {
				return Err("undeclared system for system tools: ${entry.system}")
			}
			if spec.system_tools.keep_if(|other| other.environment == entry.environment and other.system == entry.system).len() > 1 {
				return Err("DuplicateToolsFor: environment ${entry.environment} on ${entry.system}")
			}
		}
		if !spec.commands.is_empty() and !spec.requires_.contains("commands") {
			return Err("commands require feature: commands")
		}
		for entry in spec.commands {
			if !spec.environments.any(|e| e.name == entry.environment) {
				return Err("unknown environment for command: ${entry.environment}")
			}
			if !valid_command_name(entry.name) {
				return Err("invalid command name: ${entry.name}")
			}
			if spec.commands.keep_if(|other| other.environment == entry.environment and other.name == entry.name).len() > 1 {
				return Err("DuplicateCommand: environment ${entry.environment}: ${entry.name}")
			}
		}
		if !spec.configured_tools.is_empty() and !spec.requires_.contains("configured-tools") {
			return Err("configured tools require feature: configured-tools")
		}
		for entry in spec.configured_tools {
			if !spec.environments.any(|e| e.name == entry.environment) {
				return Err("unknown environment for configured tool: ${entry.environment}")
			}
			if spec.configured_tools.keep_if(|other| other.environment == entry.environment and other.tool == entry.tool).len() > 1 {
				return Err("DuplicateToolWith: environment ${entry.environment}: ${entry.tool.name}")
			}
			check_options(entry)?
		}
		if !spec.roc_packages.is_empty() and !spec.requires_.contains("roc-packages") {
			return Err("Roc packages require feature: roc-packages")
		}
		for entry in spec.roc_packages {
			if !spec.environments.any(|e| e.name == entry.environment) {
				return Err("unknown environment for Roc package: ${entry.environment}")
			}
			if !valid_name(entry.name) {
				return Err("invalid Roc package name: ${entry.name}")
			}
			if !spec.build_sources.any(|s| s.name == entry.source) {
				return Err("unknown source for Roc package: ${entry.source}")
			}
			if spec.roc_packages.keep_if(|other| other.environment == entry.environment and other.name == entry.name).len() > 1 {
				return Err("DuplicateRocPackage: environment ${entry.environment}: ${entry.name}")
			}
		}
		for input in spec.inputs {
			if !valid_ref(input.url) {
				return Err("invalid input reference: ${input.name}")
			}
		}
		if !(spec.programs.is_empty() and spec.environment_programs.is_empty()) and !spec.requires_.contains("programs") {
			return Err("programs require feature: programs")
		}
		if !spec.expects.is_empty() and !spec.requires_.contains("expects") {
			return Err("expected tools require feature: expects")
		}
		var $programs = []
		for program in spec.programs {
			if !valid_command_name(program.name) {
				return Err("invalid program name: ${program.name}")
			}
			if !declared_systems.contains(program.system) {
				return Err("undeclared system for program ${program.name}: ${program.system}")
			}
			key = (program.name, program.system)
			if $programs.contains(key) {
				return Err("DuplicateProgram: ${program.name} on ${program.system}")
			}
			$programs = $programs.append(key)
			# `blueprint update <name>` names an input or a program, never both.
			if sources.any(|s| s.name == program.name) or spec.inputs.any(|i| i.name == program.name) or spec.build_sources.any(|s| s.name == program.name) {
				return Err("program ${program.name} has the name of a source or input")
			}
			if program.urls.is_empty() {
				return Err("program ${program.name} on ${program.system} has no URL")
			}
			# Alternates serve the same bytes, so each is held to the same rule.
			var $urls = []
			for url in program.urls {
				if !valid_download_url(url) {
					return Err("program ${program.name} on ${program.system}: \"${url}\" is not a download URL; expected https://<host>/<path> with no credentials, query or fragment")
				}
				if $urls.contains(url) {
					return Err("program ${program.name} on ${program.system} names \"${url}\" twice")
				}
				$urls = $urls.append(url)
			}
			match program.unpack {
				File => if !program.path.is_empty() {
					return Err("program ${program.name} on ${program.system}: a File is the program itself and has no path: ${program.path}")
				}
				_ => if !valid_output(program.path) {
					return Err("program ${program.name} on ${program.system}: invalid path in its archive: ${program.path}")
				}
			}
		}
		check_selections(spec.environments, spec.environment_programs, "program", "DuplicatePrograms")?
		check_selections(spec.environments, spec.expects, "expected tool", "DuplicateExpect")?
		var $environments = []
		var $system_tools = []
		var $commands = []
		var $configured_tools = []
		var $roc_packages = []
		var $environment_programs = []
		var $expects = []
		for env in spec.environments {
			resolved = resolve(spec.environments, env.name, [])?
			env_commands = resolve_commands(spec.environments, spec.commands, env.name, [])?
			$commands = $commands.concat(env_commands)
			env_configured = resolve_configured_tools(spec.environments, spec.configured_tools, env.name, [])?
			$configured_tools = $configured_tools.concat(env_configured)
			$roc_packages = $roc_packages.concat(resolve_roc_packages(spec.environments, spec.roc_packages, env.name, [])?)
			for system in declared_systems {
				tools_for_system = resolve_system_tools(spec.environments, spec.system_tools, env.name, system, [])?
				if !tools_for_system.is_empty() {
					$system_tools = $system_tools.append({ environment: env.name, system, tools: tools_for_system })
				}
			}
			plain_tools = resolved.tools.concat($system_tools.keep_if(|entry| entry.environment == env.name).fold([], |tools, entry| tools.concat(entry.tools)))
			all_tools = plain_tools.concat(env_commands.map(|entry| entry.tool)).concat(env_configured.map(|entry| entry.tool))
			for t in all_tools {
				parsed = tool("${t.source}#${t.name}")?
				source = sources.find_first(|s| s.name == parsed.source).map_err(|_| "unknown source: ${t.source}")?
				match source.provider {
					Auto => {}
					NixPackages(_) => {
						check_tool(Nix, t.name)?
					}
					GuixPackages(_) => {
						check_tool(Guix, t.name)?
					}
				}
			}
			# One package cannot be on PATH both as it is and with options.
			for entry in env_configured {
				if plain_tools.contains(entry.tool) {
					return Err("tool is both plain and configured in environment ${env.name}: ${entry.tool.name}")
				}
				if sources.any(|s| s.name == entry.tool.source and guix_source(s.provider)) {
					return Err("Guix does not support configured tools: ${entry.tool.name}")
				}
			}
			for overlay in resolved.overlays {
				if !spec.inputs.any(|i| i.name == overlay and i.kind == Overlay) {
					return Err("unknown overlay: ${overlay}")
				}
			}
			env_programs = resolve_selections(spec.environments, spec.environment_programs, env.name, [])?
			env_expects = resolve_selections(spec.environments, spec.expects, env.name, [])?
			# One name on PATH has one origin: fetched, launched by a package
			# provider, or the machine's own.
			for name in env_programs {
				if !spec.programs.any(|program| program.name == name) {
					return Err("environment ${env.name} selects program ${name}, which no Fetch declares")
				}
				if env_expects.contains(name) {
					return Err("environment ${env.name} has ${name} as both a program and an expected tool")
				}
				if env_commands.any(|entry| entry.name == name) {
					return Err("environment ${env.name} has ${name} as both a program and a Command")
				}
			}
			for name in env_expects {
				if env_commands.any(|entry| entry.name == name) {
					return Err("environment ${env.name} has ${name} as both an expected tool and a Command")
				}
			}
			if !env_programs.is_empty() {
				$environment_programs = $environment_programs.append({ environment: env.name, programs: env_programs })
			}
			if !env_expects.is_empty() {
				$expects = $expects.append({ environment: env.name, programs: env_expects })
			}
			$environments = $environments.append(resolved)
		}
		for shell in spec.shells {
			if !$environments.any(|e| e.name == shell.environment) {
				return Err("unknown environment: ${shell.environment}")
			}
		}
		for task in spec.tasks {
			if !$environments.any(|e| e.name == task.environment) {
				return Err("unknown environment: ${task.environment}")
			}
			check_argv(task.run, task.name)?
		}
		for build in spec.builds {
			if !$environments.any(|e| e.name == build.environment) {
				return Err("unknown environment: ${build.environment}")
			}
			check_argv(build.run, build.name)?
			if !valid_output(build.output) {
				return Err("invalid build output: ${build.name}: ${build.output}")
			}
			check_names(build.inputs, "BuildInput")?
			check_names(build.needs, "BuildDependency")?
			for input in build.inputs {
				if !spec.build_sources.any(|s| s.name == input) {
					return Err("unknown build source: ${input}")
				}
			}
		}
		var $done = []
		for build in spec.builds {
			$done = visit_build(spec.builds, build.name, [], $done)?
		}
		_ = workflow_graph(spec)?
		var $extensions = []
		for extension in spec.extensions {
			if !clean(extension.kind) or !clean(extension.name) {
				return Err("empty Custom kind or name")
			}
			key = (extension.kind, extension.name)
			if $extensions.contains(key) {
				return Err("DuplicateExtension: ${extension.kind}/${extension.name}")
			}
			$extensions = $extensions.append(key)
		}
		for raw in spec.raw {
			if !clean(raw.backend) or !clean(raw.target) {
				return Err("empty Raw provider or target")
			}
		}
		Ok(Spec.{ format: spec.format, name: spec.name, requires_: spec.requires_, systems: declared_systems, sources, inputs: spec.inputs, environments: $environments, system_tools: $system_tools, commands: $commands, configured_tools: $configured_tools, roc_packages: $roc_packages, programs: spec.programs, environment_programs: $environment_programs, expects: $expects, shells: spec.shells, tasks: spec.tasks, build_sources: spec.build_sources, builds: spec.builds, workflows: spec.workflows, extensions: spec.extensions, raw: spec.raw })
	}

	## Whole-project checks precede expansion, even for an empty request.
	## Only atomic typed steps escape; repeated effects stay repeated.
	workflow_steps : Spec, Str -> Try(List(Spec.AtomicStep), Str)
	workflow_steps = |spec, name| {
		project = validate(spec)?
		graph = workflow_graph(project)?
		expand_workflow(graph, name, [])
	}

	## Cache size and height, not expanded lists. Every declaration/edge is
	## visited once, including diamonds whose leaves contain no atomic steps.
	WorkflowVisit : {
		name : Str,
		height : U64,
		count : U64,
		argv_bytes : U64,
		steps : List(Spec.WorkflowStep),
	}

	workflow_graph : Spec -> Try(List(WorkflowVisit), Str)
	workflow_graph = |spec| {
		var $done = []
		for workflow in spec.workflows {
			$done = visit_workflow(spec.workflows, spec.tasks, spec.builds, workflow.name, [], $done)?
		}
		Ok($done)
	}

	visit_workflow : List(Spec.Workflow), List(Spec.Task), List(Spec.Build), Str, List(Str), List(WorkflowVisit) -> Try(List(WorkflowVisit), Str)
	visit_workflow = |workflows, tasks, builds, name, visiting, done| {
		if visiting.contains(name) {
			path = Str.join_with(visiting.append(name), " -> ")
			return Err("workflow cycle: ${path}")
		}
		if visiting.len() >= 128 {
			return Err("workflow dependencies exceed 128 levels")
		}
		match done.find_first(|entry| entry.name == name) {
			Ok(entry) => {
				if visiting.len() + entry.height > 128 {
					return Err("workflow dependencies exceed 128 levels")
				}
				return Ok(done)
			}
			Err(_) => {}
		}
		workflow = workflows.find_first(|w| w.name == name)
			.map_err(|_| "unknown workflow: ${name}")?
		var $done = done
		var $height = 1.U64
		var $count = 0.U64
		var $argv_bytes = 0.U64
		var $productive = []
		for step in workflow.steps {
			match step {
				RunTask(task_name, argv) => {
					task = tasks.find_first(|t| t.name == task_name)
						.map_err(|_| "unknown task: ${task_name}")?
					# Validate configured plus extra argv, without shell parsing.
					run = task.run.concat(argv)
					check_argv(run, task_name)?
					$productive = $productive.append(step)
					$count = $count + 1
					$argv_bytes = $argv_bytes + run.fold(0, |size, arg| size + arg.to_utf8().len())
				}
				BuildArtifact(build_name) => {
					if !builds.any(|b| b.name == build_name) {
						return Err("unknown build: ${build_name}")
					}
					$productive = $productive.append(step)
					$count = $count + 1
				}
				RunWorkflow(child) => {
					$done = visit_workflow(workflows, tasks, builds, child, visiting.append(name), $done)?
					entry = $done.find_first(|e| e.name == child)
						.map_err(|_| "unknown workflow: ${child}")?
					$height = if entry.height + 1 > $height {
						entry.height + 1
					} else {
						$height
					}
					if entry.count > 0 {
						$productive = $productive.append(step)
					}
					$count = $count + entry.count
					$argv_bytes = $argv_bytes + entry.argv_bytes
				}
			}
			# Reject while counting, before allocating any expanded output.
			if $count > 4096 {
				return Err("workflow expansion exceeds 4096 atomic steps")
			}
			if $argv_bytes > 1048576 {
				return Err("workflow expansion exceeds 1 MiB argv bytes")
			}
		}
		Ok($done.append({ name, height: $height, count: $count, argv_bytes: $argv_bytes, steps: $productive }))
	}

	## Validation filters zero-sized edges once, including empty diamonds.
	## Expansion visits at most output size * depth productive edges.
	expand_workflow : List(WorkflowVisit), Str, List(Spec.AtomicStep) -> Try(List(Spec.AtomicStep), Str)
	expand_workflow = |graph, name, steps| {
		entry = graph.find_first(|e| e.name == name)
			.map_err(|_| "unknown workflow: ${name}")?
		if entry.count == 0 {
			return Ok(steps)
		}
		var $steps = steps
		for step in entry.steps {
			match step {
				RunTask(task, argv) => {
					$steps = $steps.append(RunTask(task, argv))
				}
				BuildArtifact(build) => {
					$steps = $steps.append(BuildArtifact(build))
				}
				RunWorkflow(child) => {
					$steps = expand_workflow(graph, child, $steps)?
				}
			}
		}
		Ok($steps)
	}

	## Validate the whole project before returning the requested closure. Each
	## dependency appears once, before its consumers, in Needs declaration order.
	build_closure : Spec, Str -> Try(List(Spec.Build), Str)
	build_closure = |spec, name| {
		project = validate(spec)?
		done = visit_build(project.builds, name, [], [])?
		Ok(done.map(|entry| entry.build))
	}

	## Memoized DAG traversal avoids exponential diamond expansion. Height is
	## retained so memo hits cannot hide a path exceeding the 128-level bound.
	BuildVisit : { build : Spec.Build, height : U64 }
	visit_build : List(Spec.Build), Str, List(Str), List(BuildVisit) -> Try(List(BuildVisit), Str)
	visit_build = |builds, name, visiting, done| {
		if visiting.contains(name) {
			return Err("build cycle: ${Str.join_with(visiting.append(name), " -> ")}")
		}
		if visiting.len() >= 128 {
			return Err("build dependencies exceed 128 levels")
		}
		match done.find_first(|entry| entry.build.name == name) {
			Ok(entry) => {
				if visiting.len() + entry.height > 128 {
					return Err("build dependencies exceed 128 levels")
				}
				return Ok(done)
			}
			Err(_) => {}
		}
		build = builds.find_first(|b| b.name == name).map_err(|_| "unknown build: ${name}")?
		var $done = done
		var $height = 1.U64
		for need in build.needs {
			$done = visit_build(builds, need, visiting.append(name), $done)?
			dependency = $done.find_first(|entry| entry.build.name == need).map_err(|_| "unknown build: ${need}")?
			$height = if dependency.height + 1 > $height dependency.height + 1 else $height
		}
		Ok($done.append({ build, height: $height }))
	}

	## Bounded ancestry traversal also protects untrusted runtime Spec.
	resolve : List(Spec.Environment), Str, List(Str) -> Try(Spec.Environment, Str)
	resolve = |environments, name, visiting| {
		if visiting.contains(name) {
			return Err("environment cycle: ${Str.join_with(visiting.append(name), " -> ")}")
		}
		if visiting.len() >= 128 {
			return Err("environment inheritance exceeds 128 levels")
		}
		env = environments.find_first(|e| e.name == name).map_err(|_| "unknown environment: ${name}")?
		match env.parents {
			[] => Ok({ ..env, tools: unique(env.tools), overlays: unique(env.overlays) })
			[parent] => {
				base = resolve(environments, parent, visiting.append(name))?
				Ok({ name: env.name, parents: [], tools: unique(base.tools.concat(env.tools)), overlays: unique(base.overlays.concat(env.overlays)) })
			}
			_ => Err("environment ${name} has several parents")
		}
	}

	resolve_system_tools : List(Spec.Environment), List(Spec.SystemTools), Str, Str, List(Str) -> Try(List(Spec.Tool), Str)
	resolve_system_tools = |environments, entries, name, system, visiting| {
		if visiting.contains(name) or visiting.len() >= 128 {
			return Err("environment cycle or inheritance limit: ${name}")
		}
		env = environments.find_first(|e| e.name == name).map_err(|_| "unknown environment: ${name}")?
		own = entries.find_first(|entry| entry.environment == name and entry.system == system)
			.map_ok(|entry| entry.tools) ?? []
		match env.parents {
			[] => Ok(unique(own))
			[parent] => {
				inherited = resolve_system_tools(environments, entries, parent, system, visiting.append(name))?
				Ok(unique(inherited.concat(own)))
			}
			_ => Err("environment ${name} has several parents")
		}
	}

	## Commands inherit parent first. A child's command replaces an inherited
	## command of the same name, keeping the parent's position.
	resolve_commands : List(Spec.Environment), List(Spec.Command), Str, List(Str) -> Try(List(Spec.Command), Str)
	resolve_commands = |environments, entries, name, visiting| {
		if visiting.contains(name) or visiting.len() >= 128 {
			return Err("environment cycle or inheritance limit: ${name}")
		}
		env = environments.find_first(|e| e.name == name).map_err(|_| "unknown environment: ${name}")?
		own = entries.keep_if(|entry| entry.environment == name)
		match env.parents {
			[] => Ok(own)
			[parent] => {
				inherited = resolve_commands(environments, entries, parent, visiting.append(name))?
				kept = inherited.map(
					|entry| {
						replacement = own.find_first(|o| o.name == entry.name).map_ok(|o| o.tool) ?? entry.tool
						{ environment: name, name: entry.name, tool: replacement }
					},
				)
				Ok(kept.concat(own.keep_if(|o| !inherited.any(|entry| entry.name == o.name))))
			}
			_ => Err("environment ${name} has several parents")
		}
	}

	## Configured tools inherit parent first. A child configuring an inherited
	## tool replaces its options, keeping the parent's position.
	resolve_configured_tools : List(Spec.Environment), List(Spec.ConfiguredTool), Str, List(Str) -> Try(List(Spec.ConfiguredTool), Str)
	resolve_configured_tools = |environments, entries, name, visiting| {
		if visiting.contains(name) or visiting.len() >= 128 {
			return Err("environment cycle or inheritance limit: ${name}")
		}
		env = environments.find_first(|e| e.name == name).map_err(|_| "unknown environment: ${name}")?
		own = entries.keep_if(|entry| entry.environment == name)
		match env.parents {
			[] => Ok(own)
			[parent] => {
				inherited = resolve_configured_tools(environments, entries, parent, visiting.append(name))?
				kept = inherited.map(
					|entry| {
						replacement = own.find_first(|o| o.tool == entry.tool).map_ok(|o| o.options) ?? entry.options
						{ environment: name, tool: entry.tool, options: replacement }
					},
				)
				Ok(kept.concat(own.keep_if(|o| !inherited.any(|entry| entry.tool == o.tool))))
			}
			_ => Err("environment ${name} has several parents")
		}
	}

	## Options are named values, each name once: what any provider can pass
	## to a package as data.
	check_options : Spec.ConfiguredTool -> Try({}, Str)
	check_options = |entry|
		match entry.options {
			Attrs(options) => {
				var $seen = []
				for option in options {
					if !clean(option.name) {
						return Err("invalid option name for tool ${entry.tool.name}: ${option.name}")
					}
					if $seen.contains(option.name) {
						return Err("DuplicateOption: tool ${entry.tool.name}: ${option.name}")
					}
					$seen = $seen.append(option.name)
				}
				Ok({})
			}
			_ => Err("options of tool ${entry.tool.name} must be Attrs")
		}

	guix_source : Spec.Provider -> Bool
	guix_source = |provider|
		match provider {
			GuixPackages(_) => True
			_ => False
		}

	## Roc packages inherit parent first. A name is a content hash, so a child
	## repeating an inherited package adds nothing.
	resolve_roc_packages : List(Spec.Environment), List(Spec.RocPackage), Str, List(Str) -> Try(List(Spec.RocPackage), Str)
	resolve_roc_packages = |environments, entries, name, visiting| {
		if visiting.contains(name) or visiting.len() >= 128 {
			return Err("environment cycle or inheritance limit: ${name}")
		}
		env = environments.find_first(|e| e.name == name).map_err(|_| "unknown environment: ${name}")?
		own = entries.keep_if(|entry| entry.environment == name)
		match env.parents {
			[] => Ok(own)
			[parent] => {
				inherited = resolve_roc_packages(environments, entries, parent, visiting.append(name))?
					.map(|entry| { ..entry, environment: name })
				Ok(inherited.concat(own.keep_if(|o| !inherited.any(|entry| entry.name == o.name))))
			}
			_ => Err("environment ${name} has several parents")
		}
	}

	## What an environment selects by name, programs or expected tools: at
	## most one list for each environment, of names a file on PATH can have.
	check_selections : List(Spec.Environment), List({ environment : Str, programs : List(Str) }), Str, Str -> Try({}, Str)
	check_selections = |environments, entries, kind, duplicate| {
		var $seen = []
		for entry in entries {
			if !environments.any(|e| e.name == entry.environment) {
				return Err("unknown environment for ${kind}: ${entry.environment}")
			}
			if $seen.contains(entry.environment) {
				return Err("${duplicate}: environment ${entry.environment}")
			}
			$seen = $seen.append(entry.environment)
			for name in entry.programs {
				if !valid_command_name(name) {
					return Err("invalid ${kind} name in environment ${entry.environment}: ${name}")
				}
			}
		}
		Ok({})
	}

	## Selected programs and expected tools inherit parent first. A name is
	## one file on PATH, so a child repeating an inherited name adds nothing.
	resolve_selections : List(Spec.Environment), List({ environment : Str, programs : List(Str) }), Str, List(Str) -> Try(List(Str), Str)
	resolve_selections = |environments, entries, name, visiting| {
		if visiting.contains(name) or visiting.len() >= 128 {
			return Err("environment cycle or inheritance limit: ${name}")
		}
		env = environments.find_first(|e| e.name == name).map_err(|_| "unknown environment: ${name}")?
		own = entries.find_first(|entry| entry.environment == name).map_ok(|entry| entry.programs) ?? []
		match env.parents {
			[] => Ok(unique(own))
			[parent] => {
				inherited = resolve_selections(environments, entries, parent, visiting.append(name))?
				Ok(unique(inherited.concat(own)))
			}
			_ => Err("environment ${name} has several parents")
		}
	}

	## What one environment needs on one System, by who supplies it. `tools`
	## are a package provider's: the environment's own, those it declares for
	## this System, and the tools behind its commands and configured tools.
	## `programs` are the selected programs that exist for the System, and
	## `unavailable` the names of those that do not. `expects` are the
	## programs the machine must have. `bundles` are its Roc packages, each
	## with the URL its bundle is downloaded from.
	Use : {
		tools : List(Spec.Tool),
		programs : List(Spec.Program),
		unavailable : List(Str),
		expects : List(Str),
		bundles : List({ name : Str, url : Str }),
	}

	## Takes a validated Spec, whose inheritance is already flattened. It
	## observes nothing: whether a tool or a URL exists is found out later.
	environment_use : Spec, Str, Str -> Try(Use, Str)
	environment_use = |project, name, system| {
		environment = project.environments.find_first(|e| e.name == name).map_err(|_| "unknown environment: ${name}")?
		tools = unique(
			environment.tools
				.concat(project.system_tools.keep_if(|entry| entry.environment == name and entry.system == system).fold([], |all, entry| all.concat(entry.tools)))
				.concat(project.commands.keep_if(|entry| entry.environment == name).map(|entry| entry.tool))
				.concat(project.configured_tools.keep_if(|entry| entry.environment == name).map(|entry| entry.tool)),
		)
		selected = project.environment_programs.find_first(|entry| entry.environment == name).map_ok(|entry| entry.programs) ?? []
		var $programs = []
		var $unavailable = []
		for program in selected {
			match project.programs.find_first(|entry| entry.name == program and entry.system == system) {
				Ok(entry) => {
					$programs = $programs.append(entry)
				}
				Err(_) => {
					$unavailable = $unavailable.append(program)
				}
			}
		}
		var $bundles = []
		for entry in project.roc_packages.keep_if(|declared| declared.environment == name) {
			source = project.build_sources.find_first(|declared| declared.name == entry.source)
				.map_err(|_| "unknown source of Roc package ${entry.name}: ${entry.source}")?
			url = source.ref.drop_prefix("tarball+")
			# The name is the hash of the bundle's bytes, which is what makes
			# a download of it checkable.
			if !valid_name(entry.name) or !source.ref.starts_with("tarball+https://") or !url.ends_with("/${entry.name}.tar.zst") {
				return Err("Roc package ${entry.name} is not a bundle that can be downloaded: ${source.ref}")
			}
			$bundles = $bundles.append({ name: entry.name, url })
		}
		Ok({
			tools,
			programs: $programs,
			unavailable: $unavailable,
			expects: project.expects.find_first(|entry| entry.environment == name).map_ok(|entry| entry.programs) ?? [],
			bundles: $bundles,
		})
	}

	## Check only the requested environment's normalized dependency closure.
	## This models Guix shell capability without implementing a Guix executor.
	check_environment : Spec, ProviderName, Str -> Try({}, Str)
	check_environment = |spec, provider, name| {
		project = validate(spec)?
		env = project.environments.find_first(|e| e.name == name).map_err(|_| "unknown environment: ${name}")?
		if provider == Guix and !env.overlays.is_empty() {
			return Err("Guix does not support overlays in environment ${name}")
		}
		# An empty environment still uses the default provider's environment builder.
		configured = project.configured_tools.keep_if(|entry| entry.environment == name)
		if provider == Guix and !configured.is_empty() {
			return Err("Guix does not support configured tools in environment ${name}")
		}
		all_tools = env.tools.concat(project.system_tools.keep_if(|entry| entry.environment == name).fold([], |tools, entry| tools.concat(entry.tools))).concat(project.commands.keep_if(|entry| entry.environment == name).map(|entry| entry.tool)).concat(configured.map(|entry| entry.tool))
		source_names = if all_tools.is_empty() ["default"] else unique(all_tools.map(|t| t.source))
		for source_name in source_names {
			source = project.sources.find_first(|s| s.name == source_name).map_err(|_| "unknown source: ${source_name}")?
			match (provider, source.provider) {
				(Nix, GuixPackages(_)) => return Err("source ${source.name} requires Guix, not Nix")
				(Guix, NixPackages(_)) => return Err("source ${source.name} requires Nix, not Guix")
				_ => {}
			}
		}
		for t in all_tools {
			check_tool(provider, t.name)?
		}
		Ok({})
	}

	unique : List(a) -> List(a) where [a.is_eq : a, a -> Bool]
	unique = |items| items.fold([], |acc, item| if acc.contains(item) acc else acc.append(item))
}

expect Project.tool("git") == Ok({ source: "default", name: "git" })
expect Project.tool("stable#python@3.12:out") == Ok({ source: "stable", name: "python@3.12:out" })
expect Project.tool("bad##git").is_err()
expect Project.tool("git\n").is_err()
expect Project.check_tool(Nix, "python3Packages.requests").is_ok()
expect Project.check_tool(Nix, "7zip").is_ok() and Project.check_tool(Nix, "2bwm").is_ok()
expect Project.check_tool(Nix, "python@3").is_err()
expect Project.nix_path("python3Packages.requests") == Ok(["python3Packages", "requests"])
expect Project.nix_path("zigpkgs.\"0.16.0\"") == Ok(["zigpkgs", "0.16.0"])
expect Project.nix_path("zigpkgs.brew.\"0.16.0\".out") == Ok(["zigpkgs", "brew", "0.16.0", "out"])
expect Project.nix_path("\"0.16.0\"") == Ok(["0.16.0"])
expect Project.nix_path("a.\"1.0\".\"2.0\"") == Ok(["a", "1.0", "2.0"])
expect Project.check_tool(Nix, "zigpkgs.\"0.16.0\"").is_ok()
expect Project.check_tool(Nix, "zigpkgs.0.16.0").is_ok()
expect Project.check_tool(Nix, "zigpkgs\"0.16.0\"").is_err()
expect Project.check_tool(Nix, "zigpkgs.\"0.16.0").is_err()
expect Project.check_tool(Nix, "zigpkgs.\"\"").is_err()
expect Project.check_tool(Nix, "\"a\"\"b\"").is_err()
expect Project.check_tool(Nix, "\"a\"..\"b\"").is_err()
expect Project.check_tool(Nix, "a.\"b\".").is_err()
expect Project.check_tool(Nix, "a.\"b c\"").is_err()
expect Project.check_tool(Nix, "").is_err()
expect Project.check_tool(Guix, "python@3.12:out").is_ok()
expect Project.check_tool(Guix, "git::out").is_err()
expect Project.check_tool(Guix, "g++@12.3:lib").is_ok()

# These fixtures use the public Spec and validation boundary, not resolve internals.
fixture : List(Spec.Environment) -> Spec
fixture = |environments| Spec.{
	format: Spec.current_format,
	name: "semantic tests",
	requires_: [],
	systems: ["x86_64-linux"],
	sources: [
		{ name: "nix", provider: NixPackages("github:NixOS/nixpkgs/nixos-unstable") },
		{ name: "guix", provider: GuixPackages("https://git.savannah.gnu.org/git/guix.git") },
	],
	inputs: [
		{ name: "first", url: "github:example/first", kind: Overlay },
		{ name: "second", url: "github:example/second", kind: Overlay },
		{ name: "data", url: "github:example/data", kind: Flake },
	],
	environments,
	system_tools: [],
	commands: [],
	configured_tools: [],
	roc_packages: [],
	programs: [],
	environment_programs: [],
	expects: [],
	shells: [],
	tasks: [],
	build_sources: [],
	builds: [],
	workflows: [],
	extensions: [],
	raw: [],
}

base : Spec.Environment
base = { name: "base", parents: [], tools: [{ source: "default", name: "git" }], overlays: ["first"] }

child : Spec.Environment
child = { name: "dev", parents: ["base"], tools: [{ source: "default", name: "python3" }, { source: "default", name: "git" }], overlays: ["first", "second"] }

# Declaration order is irrelevant; inheritance order is not. First wins.
expect Project.validate(fixture([child, base])) == Project.validate(
	fixture([
		{ name: "dev", parents: [], tools: [{ source: "default", name: "git" }, { source: "default", name: "python3" }], overlays: ["first", "second"] },
		base,
	]),
)

# An explicitly empty child inherits; an independent empty env stays empty.
expect match Project.validate(fixture([base, { ..child, tools: [], overlays: [] }, { name: "empty", parents: [], tools: [], overlays: [] }])) {
	Ok(spec) => spec.environments == [base, { ..base, name: "dev" }, { name: "empty", parents: [], tools: [], overlays: [] }]
	Err(_) => False
}

# Validation can be repeated by frontend, loader, and provider without changes.
expect match Project.validate(fixture([base, child])) {
	Ok(spec) => Project.validate(spec) == Ok(spec) and Spec.parse(spec.to_str()) == Ok(spec) and spec.sources.first() == Ok({ name: "default", provider: Auto })
	Err(_) => False
}

expect Project.validate(fixture([base, base])) == Err("DuplicateEnvironment: base")
expect Project.validate(fixture([child])) == Err("unknown environment: base")
expect Project.validate(fixture([{ ..base, parents: ["base"] }])).is_err()
expect Project.validate(fixture([{ ..base, parents: ["dev"] }, child])).is_err()
expect Project.validate(fixture([base, { ..child, parents: ["base", "base"] }])).is_err()
expect Project.validate(fixture([{ ..base, tools: [{ source: "missing", name: "git" }] }])) == Err("unknown source: missing")
expect Project.validate(fixture([{ ..base, overlays: ["missing"] }])) == Err("unknown overlay: missing")
expect Project.validate(fixture([{ ..base, overlays: ["data"] }])) == Err("unknown overlay: data")
expect Project.validate(fixture([{ ..base, tools: [{ source: "default", name: "git#extra" }] }])).is_err()
expect Project.validate(fixture([{ ..base, name: "bad/name" }])).is_err()

# Explicit providers validate grammar statically; Auto waits for selection.
expect Project.validate(fixture([{ ..base, tools: [{ source: "nix", name: "python@3" }] }])).is_err()
expect Project.validate(fixture([{ ..base, overlays: [], tools: [{ source: "guix", name: "python@" }] }])).is_err()
expect {
	spec = fixture([{ ..base, overlays: [], tools: [{ source: "default", name: "python@3:out" }] }])
	Project.validate(spec).is_ok() and Project.check_environment(spec, Guix, "base").is_ok() and Project.check_environment(spec, Nix, "base").is_err()
}

# An unused overlay/foreign source is not a global provider requirement.
expect {
	spec = fixture([base, { name: "plain", parents: [], overlays: [], tools: [{ source: "guix", name: "git" }] }])
	Project.check_environment(spec, Nix, "base").is_ok() and Project.check_environment(spec, Guix, "plain").is_ok() and Project.check_environment(spec, Nix, "plain").is_err() and Project.check_environment(spec, Guix, "base").is_err()
}

# Capabilities belong to the request, even with an explicit source constraint.
expect {
	spec = fixture([{ ..base, tools: [{ source: "guix", name: "git" }] }, { ..child, parents: [], overlays: [] }])
	Project.validate(spec).is_ok() and Project.check_environment(spec, Nix, "dev").is_ok() and Project.check_environment(spec, Guix, "base").is_err() and Project.check_environment(spec, Nix, "base").is_err()
}
expect Project.check_environment(fixture([{ ..base, overlays: [], tools: [{ source: "nix", name: "git" }] }]), Guix, "base").is_err()
expect Project.check_environment(fixture([base]), Nix, "missing").is_err()

# System-specific tools inherit parent first and remain explicit intent.
expect {
	spec = {
		..fixture([base, { ..child, overlays: [] }]),
		requires_: ["system-tools"],
		systems: ["x86_64-linux", "aarch64-darwin"],
		system_tools: [
			{ environment: "base", system: "x86_64-linux", tools: [{ source: "default", name: "wayland" }] },
			{ environment: "dev", system: "x86_64-linux", tools: [{ source: "default", name: "alsa-lib" }, { source: "default", name: "wayland" }] },
		],
	}
	match Project.validate(spec) {
		Ok(valid) => valid.system_tools == [
			{ environment: "base", system: "x86_64-linux", tools: [{ source: "default", name: "wayland" }] },
			{ environment: "dev", system: "x86_64-linux", tools: [{ source: "default", name: "wayland" }, { source: "default", name: "alsa-lib" }] },
		] and Project.validate(valid) == Ok(valid) and Project.validate({ ..spec, systems: ["x86_64-linux", "aarch64-darwin", "x86_64-linux"] }) == Ok(valid)
		Err(_) => False
	}
}

expect {
	entry = { environment: "base", system: "x86_64-linux", tools: [{ source: "default", name: "wayland" }] }
	spec = { ..fixture([base]), system_tools: [entry] }
	Project.validate(spec) == Err("system tools require feature: system-tools") and
		Project.validate({ ..spec, requires_: ["system-tools"], system_tools: [entry, entry] }) == Err("DuplicateToolsFor: environment base on x86_64-linux") and
			Project.validate({ ..spec, requires_: ["system-tools"], system_tools: [{ ..entry, system: "aarch64-darwin" }] }) == Err("undeclared system for system tools: aarch64-darwin") and
				Project.validate({ ..spec, requires_: ["system-tools"], system_tools: [{ ..entry, tools: [{ source: "missing", name: "wayland" }] }] }) == Err("unknown source: missing")
}

# Runtime callers must not bypass validation by constructing Spec directly.
expect Project.validate(Spec.empty("empty")).is_err()
expect !Project.valid_name("unsafe/name") and !Project.valid_name("line\nbreak")
expect Project.valid_task_name("check.fmt") and !Project.valid_task_name("check..fmt")

build_fixture : List(Spec.Build) -> Spec
build_fixture = |builds| Spec.{
	format: Spec.current_format,
	name: "build tests",
	requires_: ["sources", "builds"],
	systems: ["x86_64-linux"],
	sources: [],
	inputs: [],
	environments: [{ name: "builder", parents: [], tools: [], overlays: [] }],
	system_tools: [],
	commands: [],
	configured_tools: [],
	roc_packages: [],
	programs: [],
	environment_programs: [],
	expects: [],
	shells: [],
	tasks: [],
	build_sources: [{ name: "assets", ref: "path:./assets" }],
	builds,
	workflows: [],
	extensions: [],
	raw: [],
}

library : Spec.Build
library = { name: "library", environment: "builder", inputs: ["assets"], needs: [], run: ["python3", "build.py", "", "two words", "\"quoted\"", "$HOME", "line\nbreak"], output: "dist/library" }

application : Spec.Build
application = { ..library, name: "app", needs: ["library"], output: "dist/app" }

# Public codec/semantic round trip preserves exact argv, source and artifact data.
expect {
	spec = build_fixture([application, library])
	match Project.validate(spec) {
		Ok(project) => Spec.parse(project.to_str()) == Ok(project) and Project.validate(project) == Ok(project) and project.builds == [application, library]
		Err(_) => False
	}
}
expect Project.build_closure(build_fixture([application, library]), "app") == Ok([library, application])
expect Project.build_closure(build_fixture([application, library]), "library") == Ok([library])
expect Project.build_closure(build_fixture([library]), "missing") == Err("unknown build: missing")
expect {
	left = { ..library, name: "left", needs: ["library"] }
	right = { ..library, name: "right", needs: ["library"] }
	diamond = { ..application, needs: ["left", "right"] }
	Project.build_closure(build_fixture([diamond, right, left, library]), "app") == Ok([library, left, right, diamond])
}
expect Project.validate(build_fixture([library, library])) == Err("DuplicateBuild: library")
expect Project.validate(build_fixture([{ ..library, name: "bad/name" }])).is_err()
expect Project.validate(build_fixture([{ ..library, environment: "missing" }])) == Err("unknown environment: missing")
expect Project.validate(build_fixture([{ ..library, inputs: ["missing"] }])) == Err("unknown build source: missing")
expect Project.validate(build_fixture([{ ..library, inputs: ["assets", "assets"] }])).is_err()
expect Project.validate(build_fixture([{ ..library, needs: ["missing"] }])) == Err("unknown build: missing")
expect Project.validate(build_fixture([library, { ..application, needs: ["library", "library"] }])).is_err()
expect Project.validate(build_fixture([{ ..library, needs: ["library"] }])) == Err("build cycle: library -> library")
expect Project.validate(build_fixture([application, { ..library, needs: ["app"] }])).is_err()
# Even an unrequested malformed build is rejected before returning a closure.
expect Project.build_closure(build_fixture([library, { ..application, needs: ["app"] }]), "library").is_err()
expect Project.validate(build_fixture([{ ..library, run: [] }])) == Err("empty argv: library")
expect Project.validate(build_fixture([{ ..library, run: [""] }])) == Err("empty argv: library")
expect Project.validate(build_fixture([{ ..library, run: ["cmd", Str.from_utf8([0]) ?? ""] }])) == Err("NUL in argv: library")
expect ["", "/absolute", ".", "..", "./artifact", "dist/../escape", "dist//file", "dist/", "C:/file", "dist\\file", "line\nbreak"].all(|output| Project.validate(build_fixture([{ ..library, output }])).is_err())
expect Project.validate(build_fixture([{ ..library, output: "dist/my artifact" }])).is_ok()
# Commands inherit parent first; a child replaces a same-named command in place.
expect {
	git = { source: "default", name: "git" }
	spec = {
		..fixture([base, { ..child, overlays: [] }]),
		requires_: ["commands"],
		commands: [
			{ environment: "base", name: "vcs", tool: git },
			{ environment: "base", name: "py", tool: git },
			{ environment: "dev", name: "py", tool: { source: "default", name: "python3" } },
			{ environment: "dev", name: "roc-stable", tool: { source: "nix", name: "rocpkgs.nightly" } },
		],
	}
	match Project.validate(spec) {
		Ok(valid) => valid.commands == [
			{ environment: "base", name: "vcs", tool: git },
			{ environment: "base", name: "py", tool: git },
			{ environment: "dev", name: "vcs", tool: git },
			{ environment: "dev", name: "py", tool: { source: "default", name: "python3" } },
			{ environment: "dev", name: "roc-stable", tool: { source: "nix", name: "rocpkgs.nightly" } },
		]
		Err(_) => False
	}
}

expect {
	entry = { environment: "base", name: "vcs", tool: { source: "default", name: "git" } }
	spec = { ..fixture([base]), commands: [entry] }
	Project.validate(spec) == Err("commands require feature: commands") and
		Project.validate({ ..spec, requires_: ["commands"], commands: [entry, entry] }) == Err("DuplicateCommand: environment base: vcs") and
			Project.validate({ ..spec, requires_: ["commands"], commands: [{ ..entry, environment: "missing" }] }) == Err("unknown environment for command: missing") and
				Project.validate({ ..spec, requires_: ["commands"], commands: [{ ..entry, tool: { source: "missing", name: "git" } }] }) == Err("unknown source: missing") and
					Project.validate({ ..spec, requires_: ["commands"], commands: [{ ..entry, tool: { source: "nix", name: "python@3" } }] }).is_err()
}

expect ["roc-stable", "python3.12", "g++", "_x"].all(Project.valid_command_name)
expect ["", "-rf", ".hidden", "bin/roc", "two words", "a\nb", "$(x)", "a\"b"].all(|name| !Project.valid_command_name(name))

# Roc packages inherit parent first and need their locked source declared.
expect {
	http = { name: "roc-http", ref: "tarball+https://example.test/http.tar.zst" }
	cli = { name: "roc-cli", ref: "tarball+https://example.test/cli.tar.zst" }
	spec = {
		..fixture([base, { ..child, overlays: [] }]),
		requires_: ["sources", "roc-packages"],
		build_sources: [http, cli],
		roc_packages: [
			{ environment: "base", name: "http", source: "roc-http" },
			{ environment: "dev", name: "cli", source: "roc-cli" },
			{ environment: "dev", name: "http", source: "roc-http" },
		],
	}
	entry = { environment: "base", name: "http", source: "roc-http" }
	valid = match Project.validate(spec) {
		Ok(project) => project.roc_packages == [
			entry,
			{ environment: "dev", name: "http", source: "roc-http" },
			{ environment: "dev", name: "cli", source: "roc-cli" },
		] and Project.validate(project) == Ok(project)
		Err(_) => False
	}
	valid and
		Project.validate({ ..spec, requires_: ["sources"] }) == Err("Roc packages require feature: roc-packages") and
			Project.validate({ ..spec, roc_packages: [entry, entry] }) == Err("DuplicateRocPackage: environment base: http") and
				Project.validate({ ..spec, roc_packages: [{ ..entry, environment: "missing" }] }) == Err("unknown environment for Roc package: missing") and
					Project.validate({ ..spec, roc_packages: [{ ..entry, source: "missing" }] }) == Err("unknown source for Roc package: missing") and
						Project.validate({ ..spec, roc_packages: [{ ..entry, name: "../escape" }] }) == Err("invalid Roc package name: ../escape")
}

expect ["path:./assets", "path:assets", "github:example/assets", "git+https://example.test/assets.git", "https://example.test/assets.tar.gz"].all(Project.valid_build_source_ref)
expect ["", "flake:nixpkgs", "path:.", "path:./", "path:/absolute", "path:../escape", "path:./assets/../escape", "path:assets?dir=../escape", "file:/absolute", "git+file:///absolute", "github:", "https://", "path:line\nbreak"].all(|ref| !Project.valid_build_source_ref(ref))

# Independent direct-Spec fixtures test missing feature markers and source checks.
build_source_fixture : List(Spec.BuildSource), List(Str) -> Spec
build_source_fixture = |build_sources, requires_| {
	spec = build_fixture([library])
	Spec.{ format: spec.format, name: spec.name, requires_, systems: spec.systems, sources: spec.sources, inputs: spec.inputs, environments: spec.environments, system_tools: spec.system_tools, commands: spec.commands, configured_tools: spec.configured_tools, roc_packages: spec.roc_packages, programs: spec.programs, environment_programs: spec.environment_programs, expects: spec.expects, shells: spec.shells, tasks: spec.tasks, build_sources, builds: spec.builds, workflows: spec.workflows, extensions: spec.extensions, raw: spec.raw }
}
expect Project.validate(build_source_fixture([{ name: "assets", ref: "path:./assets" }], ["builds"])) == Err("build sources require feature: sources")
expect Project.validate(build_source_fixture([{ name: "assets", ref: "path:./assets" }], ["sources"])) == Err("builds require feature: builds")
expect Project.validate(build_source_fixture([{ name: "assets", ref: "path:../escape" }], ["sources", "builds"])).is_err()
expect Project.validate(build_source_fixture([{ name: "default", ref: "path:./assets" }], ["sources", "builds"])) == Err("DuplicateInput: default")
expect Project.validate(build_source_fixture([{ name: "assets", ref: "path:./assets" }, { name: "assets", ref: "path:./other" }], ["sources", "builds"])) == Err("DuplicateBuildSource: assets")
expect Project.validate(build_source_fixture([{ name: "bad/name", ref: "path:./assets" }], ["sources", "builds"])).is_err()

# Increasing-order declarations exercise cached heights, not just active ancestry.
chain_fixture : U64 -> List(Spec.Build)
chain_fixture = |count| {
	var $builds = []
	var $index = 0.U64
	while $index < count {
		name = $index.to_str()
		needs = if $index == 0 [] else [($index - 1).to_str()]
		$builds = $builds.append({ ..library, name, needs })
		$index = $index + 1
	}
	$builds
}
expect Project.validate(build_fixture(chain_fixture(128))).is_ok()
expect Project.validate(build_fixture(chain_fixture(129))) == Err("build dependencies exceed 128 levels")
expect Project.validate(build_fixture(chain_fixture(129).fold([], |acc, build| [build].concat(acc)))) == Err("build dependencies exceed 128 levels")
expect Project.validate(build_fixture(chain_fixture(1025))) == Err("builds or build sources exceed 1024 declarations")
expect {
	many = chain_fixture(1024)
	names = many.map(|build| build.name)
	Project.validate(build_fixture(many.map(|build| { ..build, needs: names }))) == Err("build graph exceeds 8192 references")
}
expect {
	var $argv = ["cmd"]
	while $argv.len() <= 4096 {
		$argv = $argv.append("")
	}
	Project.validate(build_fixture([{ ..library, run: $argv }])).is_err()
}
expect {
	var $argument = "x"
	while $argument.to_utf8().len() < 1048576 {
		$argument = $argument.concat($argument)
	}
	Project.validate(build_fixture([{ ..library, run: ["cmd", $argument] }])).is_err()
}
expect {
	build_sources = chain_fixture(1025).map(|build| { name: build.name, ref: "path:./assets" })
	Project.validate(build_source_fixture(build_sources, ["sources", "builds"])) == Err("builds or build sources exceed 1024 declarations")
}

# Public workflow fixtures include both atomic kinds and a dotted task name.
workflow_fixture : List(Spec.Workflow) -> Spec
workflow_fixture = |workflows| workflow_features(workflows, ["workflows"])

workflow_features : List(Spec.Workflow), List(Str) -> Spec
workflow_features = |workflows, features| Spec.{
	format: Spec.current_format,
	name: "workflow tests",
	requires_: ["sources", "builds"].concat(features),
	systems: ["x86_64-linux"],
	sources: [],
	inputs: [],
	environments: [{ name: "builder", parents: [], tools: [], overlays: [] }],
	system_tools: [],
	commands: [],
	configured_tools: [],
	roc_packages: [],
	programs: [],
	environment_programs: [],
	expects: [],
	shells: [],
	tasks: [{ name: "check.all", environment: "builder", run: ["cmd"] }],
	build_sources: [{ name: "assets", ref: "path:./assets" }],
	builds: [library],
	workflows,
	extensions: [],
	raw: [],
}

# Flat steps keep literal extras separate from configured task argv.
expect {
	argv = ["", "two words", "\"quoted\"", "$HOME", "line\nbreak", "--flag"]
	leaf = { name: "leaf", steps: [RunTask("check.all", argv)] }
	spec = workflow_fixture([
		{ name: "ci", steps: [RunWorkflow("leaf"), BuildArtifact("library"), RunWorkflow("leaf"), BuildArtifact("library")] },
		leaf,
	])
	Project.workflow_steps(spec, "ci") == Ok([
		RunTask("check.all", argv),
		BuildArtifact("library"),
		RunTask("check.all", argv),
		BuildArtifact("library"),
	])
}

# Forward references and shared diamonds retain declaration order/repetitions.
expect {
	spec = workflow_fixture([
		{ name: "root", steps: [RunWorkflow("left"), RunWorkflow("right")] },
		{ name: "right", steps: [BuildArtifact("library"), RunWorkflow("leaf")] },
		{ name: "left", steps: [RunWorkflow("leaf"), RunTask("check.all", ["L"])] },
		{ name: "leaf", steps: [RunTask("check.all", ["shared"])] },
	])
	Project.workflow_steps(spec, "root") == Ok([
		RunTask("check.all", ["shared"]),
		RunTask("check.all", ["L"]),
		BuildArtifact("library"),
		RunTask("check.all", ["shared"]),
	])
}

# All workflow tags and unusual argument bytes survive semantic normalization.
expect {
	spec = workflow_fixture([
		{ name: "ci", steps: [RunWorkflow("leaf"), BuildArtifact("library")] },
		{ name: "leaf", steps: [RunTask("check.all", ["", "\n", "é"])] },
	])
	match Project.validate(spec) {
		Ok(project) => Spec.parse(project.to_str()) == Ok(project) and
			Project.validate(project) == Ok(project)
		Err(_) => False
	}
}

# Empty workflows are valid no-ops, not missing requests.
expect Project.workflow_steps(
	workflow_fixture([
		{ name: "empty", steps: [] },
	]),
	"empty",
) == Ok([])

# A missing workflow must be an explicit failure, including on empty projects.
expect Project.workflow_steps(workflow_fixture([]), "missing") ==
	Err("unknown workflow: missing")

# Runtime Spec receives the same workflow-name checks as typed quotes.
expect Project.validate(
	workflow_fixture([
		{ name: "bad/name", steps: [] },
	]),
) == Err("invalid name for Workflow: bad/name")

# Duplicate workflow identities cannot silently choose the first declaration.
expect Project.validate(
	workflow_fixture([
		{ name: "ci", steps: [] },
		{ name: "ci", steps: [] },
	]),
) == Err("DuplicateWorkflow: ci")

# Populated optional workflow data always requires its capability marker.
expect Project.validate(
	workflow_features(
		[
			{ name: "ci", steps: [] },
		],
		[],
	),
) == Err("workflows require feature: workflows")

# Each reference kind has its own namespace; no command parsing or guessing.
expect [RunTask("library", []), BuildArtifact("check.all"), RunWorkflow("check.all")].all(|step|
	Project.validate(workflow_fixture([{ name: "ci", steps: [step] }])).is_err())

# Direct cycles fail at the shared boundary before any expansion.
expect Project.validate(
	workflow_fixture([
		{ name: "ci", steps: [RunWorkflow("ci")] },
	]),
) == Err("workflow cycle: ci -> ci")

# Even an unused indirect cycle invalidates a requested valid workflow.
expect Project.workflow_steps(
	workflow_fixture([
		{ name: "safe", steps: [RunTask("check.all", [])] },
		{ name: "a", steps: [RunWorkflow("b")] },
		{ name: "b", steps: [RunWorkflow("a")] },
	]),
	"safe",
) == Err("workflow cycle: a -> b -> a")

# Unused unknown references also invalidate an otherwise valid request.
expect Project.workflow_steps(
	workflow_fixture([
		{ name: "safe", steps: [] },
		{ name: "broken", steps: [RunTask("absent", [])] },
	]),
	"safe",
) == Err("unknown task: absent")

# Workflow extras may be empty strings, but never contain a NUL byte.
expect Project.validate(
	workflow_fixture([
		{ name: "ci", steps: [RunTask("check.all", [Str.from_utf8([0]) ?? ""])] },
	]),
) == Err("NUL in argv: check.all")

# Count configured argv together with extras, so a caller cannot bypass limits.
expect {
	var $argv = []
	while $argv.len() < 4096 {
		$argv = $argv.append("")
	}
	Project.validate(
		workflow_fixture([
			{ name: "ci", steps: [RunTask("check.all", $argv)] },
		]),
	).is_err()
}

# Graph fixtures can stress depth or doubling without huge source literals.
workflow_chain : U64, Bool, List(Spec.WorkflowStep) -> List(Spec.Workflow)
workflow_chain = |count, double, leaf| {
	var $workflows = []
	var $index = 0.U64
	while $index < count {
		steps = if $index == 0 leaf else {
			step = RunWorkflow(($index - 1).to_str())
			if double [step, step] else [step]
		}
		$workflows = $workflows.append({ name: $index.to_str(), steps })
		$index = $index + 1
	}
	$workflows
}

# A legal 128-level empty diamond must not perform exponential expansion.
expect Project.workflow_steps(workflow_fixture(workflow_chain(128, True, [])), "127") == Ok([])

# Empty subgraphs interleaved with atomic steps cannot erase those effects.
expect {
	workflows = workflow_chain(120, True, []).append({
		name: "mixed",
		steps: [RunWorkflow("119"), RunTask("check.all", []), RunWorkflow("119"), BuildArtifact("library")],
	})
	Project.workflow_steps(workflow_fixture(workflows), "mixed") ==
		Ok([RunTask("check.all", []), BuildArtifact("library")])
}

# Productive expansion is valid at the exact depth boundary too.
expect {
	workflows = workflow_chain(128, False, [RunTask("check.all", [])])
	Project.workflow_steps(workflow_fixture(workflows), "127") ==
		Ok([RunTask("check.all", [])])
}

# Cached heights must not hide excessive depth in declaration-order traversal.
expect Project.validate(workflow_fixture(workflow_chain(129, False, []))) ==
	Err("workflow dependencies exceed 128 levels")

# Reverse declaration order exercises the active-stack depth bound as well.
expect Project.validate(
	workflow_fixture(
		workflow_chain(129, False, [])
			.fold([], |acc, workflow| [workflow].concat(acc)),
	),
) ==
	Err("workflow dependencies exceed 128 levels")

# A compact shared DAG at the exact expansion limit retains all repetitions.
expect match Project.workflow_steps(workflow_fixture(workflow_chain(13, True, [RunTask("check.all", [])])), "12") {
	Ok(steps) => steps.len() == 4096 and
		steps.all(|step| step == RunTask("check.all", []))
	Err(_) => False
}

# Exponential nonempty DAGs are rejected by counts before allocating output.
expect Project.validate(workflow_fixture(workflow_chain(14, True, [RunTask("check.all", [])]))) ==
	Err("workflow expansion exceeds 4096 atomic steps")

# Bounds apply to unrequested workflows as well, including empty declarations.
expect Project.validate(workflow_fixture(workflow_chain(1025, False, []))) ==
	Err("workflows exceed 1024 declarations")

# The total declared-step budget bounds wide graphs independently of depth.
expect {
	var $steps = []
	while $steps.len() <= 8192 {
		$steps = $steps.append(RunWorkflow("empty"))
	}
	Project.validate(
		workflow_fixture([
			{ name: "empty", steps: [] },
			{ name: "wide", steps: $steps },
		]),
	) == Err("workflow graph exceeds 8192 steps")
}

# Repetition has an argv-byte budget independent of the atomic-step count.
expect {
	var $arg = "x"
	while $arg.to_utf8().len() < 524288 {
		$arg = $arg.concat($arg)
	}
	Project.validate(
		workflow_fixture([
			{ name: "leaf", steps: [RunTask("check.all", [$arg])] },
			{ name: "twice", steps: [RunWorkflow("leaf"), RunWorkflow("leaf")] },
		]),
	) == Err("workflow expansion exceeds 1 MiB argv bytes")
}

# Each declaration namespace rejects a repeated name with its own message.
expect {
	shell = { name: "default", environment: "base" }
	task = { name: "check", environment: "base", run: ["git"] }
	spec = fixture([base])
	Project.validate({ ..spec, shells: [shell, shell] }) == Err("DuplicateShell: default") and
		Project.validate({ ..spec, tasks: [task, task] }) == Err("DuplicateTask: check") and
			Project.validate({ ..spec, sources: [{ name: "default", provider: Auto }, { name: "default", provider: Auto }] }) == Err("DuplicateSource: default") and
				Project.validate({ ..spec, inputs: [{ name: "tools", url: "github:example/tools", kind: Flake }, { name: "tools", url: "github:example/overlay", kind: Overlay }] }) == Err("DuplicateInput: tools")
}

# Package sources, flake inputs and build sources share one input namespace.
expect {
	spec = fixture([base])
	assets = { name: "assets", ref: "path:./assets" }
	Project.validate({ ..spec, sources: [{ name: "data", provider: Auto }] }) == Err("DuplicateInput: data") and
		Project.validate({ ..spec, requires_: ["sources"], build_sources: [{ ..assets, name: "data" }] }) == Err("DuplicateInput: data") and
			Project.validate({ ..spec, requires_: ["sources"], build_sources: [{ ..assets, name: "nix" }] }) == Err("DuplicateInput: nix") and
				Project.validate({ ..spec, requires_: ["sources"], build_sources: [assets] }).is_ok()
}

# A shell or task must use a declared environment, and a task a nonempty argv.
expect {
	spec = fixture([base])
	task = { name: "check", environment: "base", run: ["git"] }
	Project.validate({ ..spec, shells: [{ name: "default", environment: "missing" }] }) == Err("unknown environment: missing") and
		Project.validate({ ..spec, tasks: [{ ..task, environment: "missing" }] }) == Err("unknown environment: missing") and
			Project.validate({ ..spec, tasks: [{ ..task, run: [] }] }) == Err("empty argv: check") and
				Project.validate({ ..spec, tasks: [{ ..task, run: [""] }] }) == Err("empty argv: check") and
					Project.validate({ ..spec, tasks: [task] }).is_ok()
}

# The project name is free text, but not empty or a control character.
expect Project.validate({ ..fixture([base]), name: "" }) == Err("invalid name for project")
expect Project.validate({ ..fixture([base]), name: "line\nbreak" }) == Err("invalid name for project")
expect Project.validate({ ..fixture([base]), name: Str.from_utf8([127]) ?? "" }) == Err("invalid name for project")
expect Project.validate({ ..fixture([base]), systems: [] }) == Err("no systems")

# A cycle is reported with the path that closes it, whatever its length.
expect Project.validate(fixture([{ ..base, parents: ["base"] }])) == Err("environment cycle: base -> base")
expect {
	environment = |name, parent| { name, parents: [parent], tools: [], overlays: [] }
	Project.validate(fixture([environment("one", "two"), environment("two", "three"), environment("three", "one")])) == Err("environment cycle: one -> two -> three -> one")
}

# Naming the default source explicitly changes nothing.
expect {
	spec = fixture([base])
	Project.validate({ ..spec, sources: [{ name: "default", provider: Auto }].concat(spec.sources) }) == Project.validate(spec)
}

# A flake input is not a package source, and explicit providers name their grammar.
expect Project.validate(fixture([{ ..base, tools: [{ source: "data", name: "git" }] }])) == Err("unknown source: data")
expect Project.validate(fixture([{ ..base, tools: [{ source: "nix", name: "python@3" }] }])) == Err("invalid Nix tool: python@3")
expect Project.validate(fixture([{ ..base, overlays: [], tools: [{ source: "guix", name: "python@" }] }])) == Err("invalid Guix tool: python@")
expect Project.validate({ ..fixture([base]), requires_: ["commands"], commands: [{ environment: "base", name: "bin/vcs", tool: { source: "default", name: "git" } }] }) == Err("invalid command name: bin/vcs")

rust : Spec.Tool
rust = { source: "nix", name: "rust-bin.stable.\"1.95.0\".default" }

rust_targets : List(Str) -> Value
rust_targets = |names| Value.Attrs([{ name: "targets", value: Value.List(names.map(|name| Value.Str(name))) }])

# A child inherits a configured tool and replaces its options in place.
expect {
	spec = {
		..fixture([{ ..base, tools: [], overlays: [] }, { name: "dev", parents: ["base"], tools: [], overlays: [] }, { name: "ci", parents: ["base"], tools: [], overlays: [] }]),
		requires_: ["configured-tools"],
		configured_tools: [
			{ environment: "base", tool: rust, options: rust_targets(["a"]) },
			{ environment: "dev", tool: rust, options: rust_targets(["b"]) },
			{ environment: "dev", tool: { source: "nix", name: "zig" }, options: Value.Attrs([]) },
		],
	}
	match Project.validate(spec) {
		Ok(valid) => valid.configured_tools == [
			{ environment: "base", tool: rust, options: rust_targets(["a"]) },
			{ environment: "dev", tool: rust, options: rust_targets(["b"]) },
			{ environment: "dev", tool: { source: "nix", name: "zig" }, options: Value.Attrs([]) },
			{ environment: "ci", tool: rust, options: rust_targets(["a"]) },
		]
			and Project.check_environment(spec, Nix, "ci").is_ok()
				and Project.check_environment(spec, Guix, "ci") == Err("Guix does not support configured tools in environment ci")
		Err(_) => False
	}
}

expect {
	entry = { environment: "base", tool: rust, options: rust_targets(["a"]) }
	spec = { ..fixture([{ ..base, tools: [], overlays: [] }]), configured_tools: [entry] }
	featured = { ..spec, requires_: ["configured-tools"] }
	Project.validate(spec) == Err("configured tools require feature: configured-tools") and
		Project.validate({ ..featured, configured_tools: [entry, entry] }) == Err("DuplicateToolWith: environment base: ${rust.name}") and
			Project.validate({ ..featured, configured_tools: [{ ..entry, environment: "missing" }] }) == Err("unknown environment for configured tool: missing") and
				Project.validate({ ..featured, configured_tools: [{ ..entry, tool: { source: "missing", name: "git" } }] }) == Err("unknown source: missing") and
					Project.validate({ ..featured, configured_tools: [{ ..entry, tool: { source: "nix", name: "python@3" } }] }).is_err() and
						Project.validate({ ..featured, configured_tools: [{ ..entry, options: Value.List([]) }] }) == Err("options of tool ${rust.name} must be Attrs") and
							Project.validate({ ..featured, configured_tools: [{ ..entry, options: Value.Attrs([{ name: "targets", value: Value.Int(1) }, { name: "targets", value: Value.Int(2) }]) }] }) == Err("DuplicateOption: tool ${rust.name}: targets") and
								Project.validate({ ..featured, configured_tools: [{ ..entry, tool: { source: "guix", name: "git" } }] }) == Err("Guix does not support configured tools: git")
}

# A tool the environment already has as it is cannot also be configured,
# whether its own or inherited.
expect {
	plain = { ..base, overlays: [], tools: [rust] }
	Project.validate({ ..fixture([plain]), requires_: ["configured-tools"], configured_tools: [{ environment: "base", tool: rust, options: rust_targets([]) }] }) == Err("tool is both plain and configured in environment base: ${rust.name}") and
		Project.validate({ ..fixture([plain, { name: "dev", parents: ["base"], tools: [], overlays: [] }]), requires_: ["configured-tools"], configured_tools: [{ environment: "dev", tool: rust, options: rust_targets([]) }] }) == Err("tool is both plain and configured in environment dev: ${rust.name}")
}

# Build references name build sources and builds only, each at most once.
expect Project.validate(build_fixture([{ ..library, inputs: ["default"] }])) == Err("unknown build source: default")
expect Project.validate(build_fixture([{ ..library, inputs: ["assets", "assets"] }])) == Err("DuplicateBuildInput: assets")
expect Project.validate(build_fixture([library, { ..application, needs: ["library", "library"] }])) == Err("DuplicateBuildDependency: library")
expect Project.validate(build_fixture([{ ..library, output: "dist/../escape" }])) == Err("invalid build output: library: dist/../escape")
expect Project.validate(build_source_fixture([{ name: "assets", ref: "path:../escape" }], ["sources", "builds"])) == Err("invalid build source reference: assets")
expect Project.validate(build_fixture([{ ..library, inputs: [] }])).is_ok()
expect {
	spec = workflow_fixture([])
	helper = { name: "helper", environment: "builder", run: ["cmd"] }
	Project.validate({ ..spec, tasks: [helper], builds: [{ ..library, needs: ["helper"] }] }) == Err("unknown build: helper")
}

# A workflow step of each kind names what it could not find.
expect Project.validate(workflow_fixture([{ name: "ci", steps: [RunTask("library", [])] }])) == Err("unknown task: library")
expect Project.validate(workflow_fixture([{ name: "ci", steps: [BuildArtifact("missing")] }])) == Err("unknown build: missing")
expect Project.validate(workflow_fixture([{ name: "ci", steps: [RunWorkflow("missing")] }])) == Err("unknown workflow: missing")

# A download URL is https with a host and a path, and nothing that makes the
# same bytes reachable under another name or with a secret.
expect
	[
		"https://example.test/tool",
		"https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_x86_64-2026-10-04-130536d.tar.gz",
		"https://example.test:8443/a/b%20c/tool-1.0+x86_64.zip",
		"https://xn--bcher-kva.example/tool",
		"http://127.0.0.1:8080/tool",
		"http://127.0.0.1/tool",
	].all(Project.valid_download_url)
expect
	[
		"",
		"https://",
		"https://example.test",
		"https://example.test/",
		"https:///tool",
		"https://example.test/a/",
		"https://example.test//tool",
		"https://example.test/a/../tool",
		"https://example.test/./tool",
		"http://example.test/tool",
		"http://localhost/tool",
		"http://127.0.0.1.example.test/tool",
		"http://127.0.0.10/tool",
		"http://127.0.0.1",
		"ftp://example.test/tool",
		"file:///tmp/tool",
		"path:./tool",
		"https://user@example.test/tool",
		"https://user:secret@example.test/tool",
		"https://example.test/tool?token=1",
		"https://example.test/tool#sha256",
		"https://example.test/a b",
		"https://example.test/tool\n",
		"https://example.test\\tool",
		"https://example.test:port/tool",
		"https://example.test:123456/tool",
		"https://example.test:/tool",
		"https://-example.test/tool",
		"https://example..test/tool",
		"https://[::1]/tool",
		"https://exämple.test/tool",
		" https://example.test/tool",
	].all(|url| !Project.valid_download_url(url))

linux_tool : Spec.Program
linux_tool = { name: "tool", system: "x86_64-linux", urls: ["https://example.test/tool-x86_64-linux"], unpack: File, path: "" }

linux_roc : Spec.Program
linux_roc = { name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/roc.tar.gz"], unpack: TarGz, path: "roc_nightly/roc" }

# Two environments without tools or overlays, the second extending the first.
fetching : Spec
fetching = {
	..fixture([{ ..base, tools: [], overlays: [] }, { name: "dev", parents: ["base"], tools: [], overlays: [] }]),
	requires_: ["programs", "expects", "commands"],
	systems: ["x86_64-linux", "aarch64-darwin"],
	programs: [linux_tool, { ..linux_tool, system: "aarch64-darwin", urls: ["https://example.test/tool-aarch64-darwin", "https://mirror.example.test/tool-aarch64-darwin"] }, linux_roc],
}

# Selected programs and expected tools inherit parent first, each name once,
# and an environment that ends with none has no entry. Normalizing again
# changes nothing.
expect {
	spec = {
		..fetching,
		environment_programs: [{ environment: "dev", programs: ["tool", "roc-stable", "tool"] }, { environment: "base", programs: ["roc-stable"] }],
		expects: [{ environment: "dev", programs: ["gh", "git", "gh"] }],
	}
	match Project.validate(spec) {
		Ok(project) => project.environment_programs == [{ environment: "base", programs: ["roc-stable"] }, { environment: "dev", programs: ["roc-stable", "tool"] }]
			and project.expects == [{ environment: "dev", programs: ["gh", "git"] }]
				and project.programs == spec.programs
					and Project.validate(project) == Ok(project)
						and Spec.parse(project.to_str()) == Ok(project)
		Err(_) => False
	}
}

# A declared program nothing selects is valid, and so is an empty selection.
expect Project.validate(fetching).map_ok(|project| project.environment_programs) == Ok([])
expect Project.validate({ ..fetching, environment_programs: [{ environment: "base", programs: [] }], expects: [{ environment: "base", programs: [] }] }).map_ok(|project| (project.environment_programs, project.expects)) == Ok(([], []))

# An older consumer is told by name; without the marker the Spec is refused.
expect
	Project.validate({ ..fetching, requires_: ["expects"] }) == Err("programs require feature: programs") and
		Project.validate({ ..fetching, programs: [], requires_: [], environment_programs: [{ environment: "base", programs: [] }] }) == Err("programs require feature: programs") and
			Project.validate({ ..fetching, requires_: ["programs"], expects: [{ environment: "base", programs: ["git"] }] }) == Err("expected tools require feature: expects")

# Each program is one download for one declared System, under a command name.
expect
	Project.validate({ ..fetching, programs: [linux_tool, linux_tool] }) == Err("DuplicateProgram: tool on x86_64-linux") and
		Project.validate({ ..fetching, programs: [{ ..linux_tool, system: "riscv64-linux" }] }) == Err("undeclared system for program tool: riscv64-linux") and
			Project.validate({ ..fetching, programs: [{ ..linux_tool, name: "bin/tool" }] }) == Err("invalid program name: bin/tool") and
				Project.validate({ ..fetching, programs: [{ ..linux_tool, name: "-tool" }] }) == Err("invalid program name: -tool") and
					Project.validate({ ..fetching, programs: [{ ..linux_tool, name: "" }] }) == Err("invalid program name: ")

# The URL rule names the program, the System and the URL it refuses.
expect
	Project.validate({ ..fetching, programs: [{ ..linux_roc, system: "aarch64-darwin", urls: ["http://x/roc.tar.gz"] }] }) == Err("program roc-stable on aarch64-darwin: \"http://x/roc.tar.gz\" is not a download URL; expected https://<host>/<path> with no credentials, query or fragment") and
		Project.validate({ ..fetching, programs: [{ ..linux_tool, urls: ["https://token@example.test/tool"] }] }).is_err() and
			Project.validate({ ..fetching, programs: [{ ..linux_tool, urls: ["http://127.0.0.1:4000/tool"] }] }).is_ok()

# An archive names the program inside it; a File is the program.
expect
	Project.validate({ ..fetching, programs: [{ ..linux_roc, path: "" }] }) == Err("program roc-stable on x86_64-linux: invalid path in its archive: ") and
		Project.validate({ ..fetching, programs: [{ ..linux_roc, path: "../roc" }] }) == Err("program roc-stable on x86_64-linux: invalid path in its archive: ../roc") and
			Project.validate({ ..fetching, programs: [{ ..linux_roc, path: "/usr/bin/roc" }] }) == Err("program roc-stable on x86_64-linux: invalid path in its archive: /usr/bin/roc") and
				Project.validate({ ..fetching, programs: [{ ..linux_roc, unpack: Zip, path: "roc/roc.exe" }, { ..linux_tool, unpack: TarXz, path: "bin/tool" }] }).is_ok() and
					Project.validate({ ..fetching, programs: [{ ..linux_tool, path: "tool" }] }) == Err("program tool on x86_64-linux: a File is the program itself and has no path: tool")

# A program shares no name with a source, an input or a build source, so that
# `blueprint update <name>` means one thing.
expect
	["nix", "default", "first", "data"].all(|name| Project.validate({ ..fetching, programs: [{ ..linux_tool, name }] }) == Err("program ${name} has the name of a source or input")) and
		Project.validate({ ..fetching, requires_: ["programs", "sources"], build_sources: [{ name: "assets", ref: "path:./assets" }], programs: [{ ..linux_tool, name: "assets" }] }) == Err("program assets has the name of a source or input")

# A selection names its environment once, with names a file on PATH can have.
expect
	Project.validate({ ..fetching, environment_programs: [{ environment: "missing", programs: ["tool"] }] }) == Err("unknown environment for program: missing") and
		Project.validate({ ..fetching, expects: [{ environment: "missing", programs: ["git"] }] }) == Err("unknown environment for expected tool: missing") and
			Project.validate({ ..fetching, environment_programs: [{ environment: "dev", programs: ["tool"] }, { environment: "dev", programs: [] }] }) == Err("DuplicatePrograms: environment dev") and
				Project.validate({ ..fetching, expects: [{ environment: "dev", programs: ["git"] }, { environment: "dev", programs: ["gh"] }] }) == Err("DuplicateExpect: environment dev") and
					Project.validate({ ..fetching, expects: [{ environment: "dev", programs: ["git", "/usr/bin/gh"] }] }) == Err("invalid expected tool name in environment dev: /usr/bin/gh") and
						Project.validate({ ..fetching, environment_programs: [{ environment: "dev", programs: ["../tool"] }] }) == Err("invalid program name in environment dev: ../tool")

# A selected program is a declared one, whichever environment selects it.
expect
	Project.validate({ ..fetching, environment_programs: [{ environment: "dev", programs: ["roc-stable", "zig"] }] }) == Err("environment dev selects program zig, which no Fetch declares") and
		Project.validate({ ..fetching, programs: [], environment_programs: [{ environment: "base", programs: ["roc-stable"] }] }) == Err("environment base selects program roc-stable, which no Fetch declares")

# One name on PATH has one origin, in the environment and in what it inherits.
expect {
	command = { environment: "base", name: "roc-stable", tool: { source: "default", name: "rocpkgs.nightly" } }
	Project.validate({ ..fetching, environment_programs: [{ environment: "dev", programs: ["tool"] }], expects: [{ environment: "dev", programs: ["tool"] }] }) == Err("environment dev has tool as both a program and an expected tool") and
		Project.validate({ ..fetching, environment_programs: [{ environment: "dev", programs: ["tool"] }], expects: [{ environment: "base", programs: ["tool"] }] }) == Err("environment dev has tool as both a program and an expected tool") and
			Project.validate({ ..fetching, commands: [command], environment_programs: [{ environment: "base", programs: ["roc-stable"] }] }) == Err("environment base has roc-stable as both a program and a Command") and
				Project.validate({ ..fetching, commands: [command], environment_programs: [{ environment: "dev", programs: ["roc-stable"] }] }) == Err("environment dev has roc-stable as both a program and a Command") and
					Project.validate({ ..fetching, commands: [command], expects: [{ environment: "dev", programs: ["roc-stable"] }] }) == Err("environment dev has roc-stable as both an expected tool and a Command") and
					# A child's Command meets the tool its parent expects.
						Project.validate({ ..fetching, commands: [{ ..command, environment: "dev" }], environment_programs: [{ environment: "base", programs: ["tool"] }], expects: [{ environment: "base", programs: ["roc-stable"] }] }) == Err("environment dev has roc-stable as both an expected tool and a Command") and
						# Unrelated environments may take one name from different origins.
							Project.validate({ ..fixture([{ ..base, tools: [], overlays: [] }, { name: "other", parents: [], tools: [], overlays: [] }]), requires_: ["programs", "expects", "commands"], programs: [linux_roc], commands: [{ ..command, environment: "other" }], environment_programs: [{ environment: "base", programs: ["roc-stable"] }] }).is_ok()
}

# What an environment needs is split by who supplies it, for one System: a
# provider's tools from every way of declaring one, the programs that exist
# there, the names of those that do not, what the machine must have, and each
# Roc bundle with its URL. Inherited selections come first.
expect {
	git = { source: "default", name: "git" }
	zig = { source: "nix", name: "zigpkgs.\"0.16.0\"" }
	spec = {
		..fetching,
		requires_: ["programs", "expects", "commands", "system-tools", "configured-tools", "roc-packages", "sources"],
		environments: [{ ..base, tools: [git], overlays: [] }, { name: "dev", parents: ["base"], tools: [zig, git], overlays: [] }],
		system_tools: [
			{ environment: "dev", system: "x86_64-linux", tools: [{ source: "default", name: "wayland" }] },
			{ environment: "dev", system: "aarch64-darwin", tools: [{ source: "default", name: "libiconv" }] },
		],
		commands: [{ environment: "base", name: "py", tool: { source: "default", name: "python3" } }],
		configured_tools: [{ environment: "dev", tool: rust, options: rust_targets([]) }],
		environment_programs: [{ environment: "base", programs: ["roc-stable"] }, { environment: "dev", programs: ["tool"] }],
		expects: [{ environment: "dev", programs: ["gh"] }],
		build_sources: [{ name: "roc-abc", ref: "tarball+https://example.test/releases/1.0/abc.tar.zst" }],
		roc_packages: [{ environment: "base", name: "abc", source: "roc-abc" }],
	}
	project = Project.validate(spec)?
	darwin_tool = { ..linux_tool, system: "aarch64-darwin", urls: ["https://example.test/tool-aarch64-darwin", "https://mirror.example.test/tool-aarch64-darwin"] }
	bundles = [{ name: "abc", url: "https://example.test/releases/1.0/abc.tar.zst" }]
	Project.environment_use(project, "dev", "x86_64-linux") == Ok({
		tools: [git, zig, { source: "default", name: "wayland" }, { source: "default", name: "python3" }, rust],
		programs: [linux_roc, linux_tool],
		unavailable: [],
		expects: ["gh"],
		bundles,
	})
		and Project.environment_use(project, "dev", "aarch64-darwin") == Ok({
			tools: [git, zig, { source: "default", name: "libiconv" }, { source: "default", name: "python3" }, rust],
			programs: [darwin_tool],
			unavailable: ["roc-stable"],
			expects: ["gh"],
			bundles,
		})
			and Project.environment_use(project, "base", "x86_64-linux") == Ok({ tools: [git, { source: "default", name: "python3" }], programs: [linux_roc], unavailable: [], expects: [], bundles })
				and Project.environment_use(project, "missing", "x86_64-linux") == Err("unknown environment: missing")
}

# An environment that declares nothing needs nothing, from anyone.
expect Project.validate(fetching).map_ok(|project| Project.environment_use(project, "dev", "x86_64-linux")) == Ok(Ok({ tools: [], programs: [], unavailable: [], expects: [], bundles: [] }))

# A Roc package is downloaded over HTTPS from a file of its own name, or the
# environment cannot be planned at all.
expect
	["tarball+http://example.test/abc.tar.zst", "tarball+https://example.test/other.tar.zst", "https://example.test/abc.tar.zst", "github:example/abc.tar.zst"].all(
		|ref|
			match Project.validate({ ..fetching, requires_: ["programs", "roc-packages", "sources"], build_sources: [{ name: "roc-abc", ref }], roc_packages: [{ environment: "base", name: "abc", source: "roc-abc" }] }) {
				Ok(project) => Project.environment_use(project, "dev", "x86_64-linux") == Err("Roc package abc is not a bundle that can be downloaded: ${ref}")
				Err(_) => False
			},
	)
