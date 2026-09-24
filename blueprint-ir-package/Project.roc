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
			if task.run.is_empty() or (task.run.first() ?? "").is_empty() {
				return Err("empty argv: ${task.name}")
			}
			if task.run.any(|arg| arg.to_utf8().contains(0)) {
				return Err("NUL in argv: ${task.name}")
			}
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
		Ok(Ir.{ format: ir.format, name: ir.name, requires_: ir.requires_, systems: unique(ir.systems), sources, inputs: ir.inputs, environments: $environments, shells: ir.shells, tasks: ir.tasks, extensions: ir.extensions, raw: ir.raw })
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
