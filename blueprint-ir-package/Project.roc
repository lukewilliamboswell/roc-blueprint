import Ir

## Shared pure semantic boundary. Validation observes neither PATH nor the host.
## It normalizes defaults and inheritance, and is safe to repeat on emitted IR.
Project :: [].{
	Backend : [Nix, Guix]

	valid_name : Str -> Bool
	valid_name = |name| !name.is_empty() and name.to_utf8().all(|b| letter(b) or (b >= '0' and b <= '9') or b == '-' or b == '_')

	valid_task_name : Str -> Bool
	valid_task_name = |name| !name.is_empty() and name.split_on(".").all(valid_name)

	letter : U8 -> Bool
	letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')

	clean : Str -> Bool
	clean = |text| !text.is_empty() and text.to_utf8().all(|b| b > 32 and b != 127)

	## Generic syntax only. Provider grammar is checked once intent is known.
	tool : Str -> Try(Ir.Tool, Str)
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

	## Deliberately conservative native grammars: Nix dotted identifiers;
	## Guix package[@version][:output] specifications. No translation or probing.
	check_tool : Backend, Str -> Try({}, Str)
	check_tool = |backend, name| {
		valid = match backend {
			Nix => name.split_on(".").all(
				|part| {
					bytes = part.to_utf8()
					!bytes.is_empty() and bytes.all(|b| letter(b) or (b >= '0' and b <= '9') or b == '_' or b == '-' or b == '\'')
				},
			)
			Guix => {
				parts = name.split_on(":")
				spec = parts.first() ?? ""
				versions = spec.split_on("@")
				parts.len() <= 2 and versions.len() <= 2 and parts.drop_first(1).all(valid_name) and versions.all(|part| !part.is_empty() and part.to_utf8().all(|b| letter(b) or (b >= '0' and b <= '9') or b == '-' or b == '_' or b == '.' or b == '+'))
			}
		}
		if valid Ok({}) else Err("invalid ${if backend == Nix "Nix" else "Guix"} tool: ${name}")
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

	validate : Ir -> Try(Ir, Str)
	validate = |ir| {
		if ir.format.major != Ir.current_format.major {
			return Err("unsupported IR major")
		}
		if ir.name.is_empty() or ir.name.to_utf8().any(|b| b < 32 or b == 127) {
			return Err("invalid name for project")
		}
		if ir.systems.is_empty() {
			return Err("no systems")
		}
		for system in ir.systems {
			parts = system.split_on("-")
			if parts.len() != 2 or !parts.all(|part| !part.is_empty() and part.to_utf8().all(|b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '_')) {
				return Err("invalid system: ${system}")
			}
		}
		if ir.builds.len() > 1024 or ir.build_sources.len() > 1024 {
			return Err("builds or build sources exceed 1024 declarations")
		}
		if ir.builds.fold(0, |count, build| count + build.needs.len() + build.inputs.len()) > 8192 {
			return Err("build graph exceeds 8192 references")
		}
		check_names(ir.build_sources.map(|s| s.name), "BuildSource")?
		check_names(ir.builds.map(|b| b.name), "Build")?
		check_names(ir.sources.map(|s| s.name), "Source")?
		check_names(ir.inputs.map(|i| i.name), "Input")?
		check_names(ir.environments.map(|e| e.name), "Environment")?
		check_names(ir.shells.map(|s| s.name), "Shell")?
		check_names(ir.tasks.map(|t| t.name), "Task")?
		sources = if ir.sources.any(|s| s.name == "default") ir.sources else [{ name: "default", provider: Auto }].concat(ir.sources)
		for source in sources {
			if ir.inputs.any(|i| i.name == source.name) {
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
		for source in ir.build_sources {
			if sources.any(|s| s.name == source.name) or ir.inputs.any(|i| i.name == source.name) {
				return Err("DuplicateInput: ${source.name}")
			}
			if !valid_build_source_ref(source.ref) {
				return Err("invalid build source reference: ${source.name}")
			}
		}
		if !ir.build_sources.is_empty() and !ir.requires_.contains("sources") {
			return Err("build sources require feature: sources")
		}
		if !ir.builds.is_empty() and !ir.requires_.contains("builds") {
			return Err("builds require feature: builds")
		}
		for input in ir.inputs {
			if !valid_ref(input.url) {
				return Err("invalid input reference: ${input.name}")
			}
		}
		var $environments = []
		for env in ir.environments {
			resolved = resolve(ir.environments, env.name, [])?
			for t in resolved.tools {
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
			for overlay in resolved.overlays {
				if !ir.inputs.any(|i| i.name == overlay and i.kind == Overlay) {
					return Err("unknown overlay: ${overlay}")
				}
			}
			$environments = $environments.append(resolved)
		}
		for shell in ir.shells {
			if !$environments.any(|e| e.name == shell.environment) {
				return Err("unknown environment: ${shell.environment}")
			}
		}
		for task in ir.tasks {
			if !$environments.any(|e| e.name == task.environment) {
				return Err("unknown environment: ${task.environment}")
			}
			check_argv(task.run, task.name)?
		}
		for build in ir.builds {
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
				if !ir.build_sources.any(|s| s.name == input) {
					return Err("unknown build source: ${input}")
				}
			}
		}
		var $done = []
		for build in ir.builds {
			$done = visit_build(ir.builds, build.name, [], $done)?
		}
		var $extensions = []
		for extension in ir.extensions {
			if !clean(extension.kind) or !clean(extension.name) {
				return Err("empty Custom kind or name")
			}
			key = (extension.kind, extension.name)
			if $extensions.contains(key) {
				return Err("DuplicateExtension: ${extension.kind}/${extension.name}")
			}
			$extensions = $extensions.append(key)
		}
		for raw in ir.raw {
			if !clean(raw.backend) or !clean(raw.target) {
				return Err("empty Raw backend or target")
			}
		}
		Ok(Ir.{ format: ir.format, name: ir.name, requires_: ir.requires_, systems: unique(ir.systems), sources, inputs: ir.inputs, environments: $environments, shells: ir.shells, tasks: ir.tasks, build_sources: ir.build_sources, builds: ir.builds, extensions: ir.extensions, raw: ir.raw })
	}

	## Validate the whole project before returning the requested closure. Each
	## dependency appears once, before its consumers, in Needs declaration order.
	build_closure : Ir, Str -> Try(List(Ir.Build), Str)
	build_closure = |ir, name| {
		project = validate(ir)?
		done = visit_build(project.builds, name, [], [])?
		Ok(done.map(|entry| entry.build))
	}

	## Memoized DAG traversal avoids exponential diamond expansion. Height is
	## retained so memo hits cannot hide a path exceeding the 128-level bound.
	BuildVisit : { build : Ir.Build, height : U64 }
	visit_build : List(Ir.Build), Str, List(Str), List(BuildVisit) -> Try(List(BuildVisit), Str)
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

	## Bounded ancestry traversal also protects untrusted runtime IR.
	resolve : List(Ir.Environment), Str, List(Str) -> Try(Ir.Environment, Str)
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

	## Check only the requested environment's normalized dependency closure.
	## This models Guix shell capability without implementing a Guix executor.
	check_environment : Ir, Backend, Str -> Try({}, Str)
	check_environment = |ir, backend, name| {
		project = validate(ir)?
		env = project.environments.find_first(|e| e.name == name).map_err(|_| "unknown environment: ${name}")?
		if backend == Guix and !env.overlays.is_empty() {
			return Err("Guix does not support overlays in environment ${name}")
		}
		# An empty environment still uses the default provider's environment builder.
		source_names = if env.tools.is_empty() ["default"] else unique(env.tools.map(|t| t.source))
		for source_name in source_names {
			source = project.sources.find_first(|s| s.name == source_name).map_err(|_| "unknown source: ${source_name}")?
			match (backend, source.provider) {
				(Nix, GuixPackages(_)) => return Err("source ${source.name} requires Guix, not Nix")
				(Guix, NixPackages(_)) => return Err("source ${source.name} requires Nix, not Guix")
				_ => {}
			}
		}
		for t in env.tools {
			check_tool(backend, t.name)?
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
expect Project.check_tool(Guix, "python@3.12:out").is_ok()
expect Project.check_tool(Guix, "git::out").is_err()
expect Project.check_tool(Guix, "g++@12.3:lib").is_ok()

# These fixtures use the public IR and validation boundary, not resolve internals.
fixture : List(Ir.Environment) -> Ir
fixture = |environments| Ir.{
	format: Ir.current_format,
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
	shells: [],
	tasks: [],
	build_sources: [],
	builds: [],
	extensions: [],
	raw: [],
}

base : Ir.Environment
base = { name: "base", parents: [], tools: [{ source: "default", name: "git" }], overlays: ["first"] }

child : Ir.Environment
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
	Ok(ir) => ir.environments == [base, { ..base, name: "dev" }, { name: "empty", parents: [], tools: [], overlays: [] }]
	Err(_) => False
}

# Validation can be repeated by frontend, loader, and backend without changes.
expect match Project.validate(fixture([base, child])) {
	Ok(ir) => Project.validate(ir) == Ok(ir) and Ir.parse(ir.to_str()) == Ok(ir) and ir.sources.first() == Ok({ name: "default", provider: Auto })
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
	ir = fixture([{ ..base, overlays: [], tools: [{ source: "default", name: "python@3:out" }] }])
	Project.validate(ir).is_ok() and Project.check_environment(ir, Guix, "base").is_ok() and Project.check_environment(ir, Nix, "base").is_err()
}

# An unused overlay/foreign source is not a global backend requirement.
expect {
	ir = fixture([base, { name: "plain", parents: [], overlays: [], tools: [{ source: "guix", name: "git" }] }])
	Project.check_environment(ir, Nix, "base").is_ok() and Project.check_environment(ir, Guix, "plain").is_ok() and Project.check_environment(ir, Nix, "plain").is_err() and Project.check_environment(ir, Guix, "base").is_err()
}

# Capabilities belong to the request, even with an explicit source constraint.
expect {
	ir = fixture([{ ..base, tools: [{ source: "guix", name: "git" }] }, { ..child, parents: [], overlays: [] }])
	Project.validate(ir).is_ok() and Project.check_environment(ir, Nix, "dev").is_ok() and Project.check_environment(ir, Guix, "base").is_err() and Project.check_environment(ir, Nix, "base").is_err()
}
expect Project.check_environment(fixture([{ ..base, overlays: [], tools: [{ source: "nix", name: "git" }] }]), Guix, "base").is_err()
expect Project.check_environment(fixture([base]), Nix, "missing").is_err()

# Runtime callers must not bypass validation by constructing IR directly.
expect Project.validate(Ir.empty("empty")).is_err()
expect !Project.valid_name("unsafe/name") and !Project.valid_name("line\nbreak")
expect Project.valid_task_name("check.fmt") and !Project.valid_task_name("check..fmt")

build_fixture : List(Ir.Build) -> Ir
build_fixture = |builds| Ir.{
	format: Ir.current_format,
	name: "build tests",
	requires_: ["sources", "builds"],
	systems: ["x86_64-linux"],
	sources: [],
	inputs: [],
	environments: [{ name: "builder", parents: [], tools: [], overlays: [] }],
	shells: [],
	tasks: [],
	build_sources: [{ name: "assets", ref: "path:./assets" }],
	builds,
	extensions: [],
	raw: [],
}

library : Ir.Build
library = { name: "library", environment: "builder", inputs: ["assets"], needs: [], run: ["python3", "build.py", "", "two words", "\"quoted\"", "$HOME", "line\nbreak"], output: "dist/library" }

application : Ir.Build
application = { ..library, name: "app", needs: ["library"], output: "dist/app" }

# Public codec/semantic round trip preserves exact argv, source and artifact data.
expect {
	ir = build_fixture([application, library])
	match Project.validate(ir) {
		Ok(project) => Ir.parse(project.to_str()) == Ok(project) and Project.validate(project) == Ok(project) and project.builds == [application, library]
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
expect ["path:./assets", "path:assets", "github:example/assets", "git+https://example.test/assets.git", "https://example.test/assets.tar.gz"].all(Project.valid_build_source_ref)
expect ["", "flake:nixpkgs", "path:.", "path:./", "path:/absolute", "path:../escape", "path:./assets/../escape", "path:assets?dir=../escape", "file:/absolute", "git+file:///absolute", "github:", "https://", "path:line\nbreak"].all(|ref| !Project.valid_build_source_ref(ref))

# Independent direct-IR fixtures test missing feature markers and source checks.
build_source_fixture : List(Ir.BuildSource), List(Str) -> Ir
build_source_fixture = |build_sources, requires_| {
	ir = build_fixture([library])
	Ir.{ format: ir.format, name: ir.name, requires_, systems: ir.systems, sources: ir.sources, inputs: ir.inputs, environments: ir.environments, shells: ir.shells, tasks: ir.tasks, build_sources, builds: ir.builds, extensions: ir.extensions, raw: ir.raw }
}
expect Project.validate(build_source_fixture([{ name: "assets", ref: "path:./assets" }], ["builds"])) == Err("build sources require feature: sources")
expect Project.validate(build_source_fixture([{ name: "assets", ref: "path:./assets" }], ["sources"])) == Err("builds require feature: builds")
expect Project.validate(build_source_fixture([{ name: "assets", ref: "path:../escape" }], ["sources", "builds"])).is_err()
expect Project.validate(build_source_fixture([{ name: "default", ref: "path:./assets" }], ["sources", "builds"])) == Err("DuplicateInput: default")
expect Project.validate(build_source_fixture([{ name: "assets", ref: "path:./assets" }, { name: "assets", ref: "path:./other" }], ["sources", "builds"])) == Err("DuplicateBuildSource: assets")
expect Project.validate(build_source_fixture([{ name: "bad/name", ref: "path:./assets" }], ["sources", "builds"])).is_err()

# Increasing-order declarations exercise cached heights, not just active ancestry.
chain_fixture : U64 -> List(Ir.Build)
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
