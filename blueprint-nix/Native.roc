# Pure Nix/Guix authoring validators. These grammars belong to adapters,
# never to the provider-neutral project model.
import core.Spec
import core.Project

Native :: [].{
	ProviderName : [Nix, Guix]
	letter = Project.letter
	valid_name = Project.valid_name
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
				leading = if (after) part.drop_prefix(".") else part
				inner = if (before) leading.drop_suffix(".") else leading
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
		if (valid) Ok({}) else Err("invalid ${if (provider == Nix) "Nix" else "Guix"} tool: ${name}")
	}

	## Check only the requested environment's normalized dependency closure.
	## This models Guix shell capability without implementing a Guix executor.
	check_environment : Spec, ProviderName, Str -> Try({}, Str)
	check_environment = |spec, provider, name| {
		project = Project.validate(spec)?
		env = project.environments.find_first(|e| e.name == name).map_err(|_| "unknown environment: ${name}")?
		if provider == Guix and !env.overlays.is_empty() {
			return Err("Guix does not support overlays in environment ${name}")
		}
		configured = project.configured_tools.keep_if(|entry| entry.environment == name)
		if provider == Guix and !configured.is_empty() {
			return Err("Guix does not support configured tools in environment ${name}")
		}
		all_tools = env.tools.concat(project.system_tools.keep_if(|entry| entry.environment == name).fold([], |tools, entry| tools.concat(entry.tools))).concat(project.commands.keep_if(|entry| entry.environment == name).map(|entry| entry.tool)).concat(configured.map(|entry| entry.tool))
		for source_name in Project.unique(all_tools.map(|t| t.source)) {
			source = project.sources.find_first(|s| s.name == source_name).map_err(|_| Project.unknown_source(project.sources, source_name))?
			if source.provider.name != (if (provider == Nix) "nix" else "guix") {
				return Err("source ${source.name} requires ${source.provider.name}, not ${if (provider == Nix) "Nix" else "Guix"}")
			}
		}
		for t in all_tools {
			check_tool(provider, t.name)?
		}
		Ok({})
	}

}

expect Native.check_tool(Nix, "python3Packages.requests").is_ok()
expect Native.check_tool(Nix, "7zip").is_ok() and Native.check_tool(Nix, "2bwm").is_ok()
expect Native.check_tool(Nix, "python@3").is_err()
expect Native.nix_path("python3Packages.requests") == Ok(["python3Packages", "requests"])
expect Native.nix_path("zigpkgs.\"0.16.0\"") == Ok(["zigpkgs", "0.16.0"])
expect Native.nix_path("zigpkgs.brew.\"0.16.0\".out") == Ok(["zigpkgs", "brew", "0.16.0", "out"])
expect Native.nix_path("\"0.16.0\"") == Ok(["0.16.0"])
expect Native.nix_path("a.\"1.0\".\"2.0\"") == Ok(["a", "1.0", "2.0"])
expect Native.check_tool(Nix, "zigpkgs.\"0.16.0\"").is_ok()
expect Native.check_tool(Nix, "zigpkgs.0.16.0").is_ok()
expect Native.check_tool(Nix, "zigpkgs\"0.16.0\"").is_err()
expect Native.check_tool(Nix, "zigpkgs.\"0.16.0").is_err()
expect Native.check_tool(Nix, "zigpkgs.\"\"").is_err()
expect Native.check_tool(Nix, "\"a\"\"b\"").is_err()
expect Native.check_tool(Nix, "\"a\"..\"b\"").is_err()
expect Native.check_tool(Nix, "a.\"b\".").is_err()
expect Native.check_tool(Nix, "a.\"b c\"").is_err()
expect Native.check_tool(Nix, "").is_err()
expect Native.check_tool(Guix, "python@3.12:out").is_ok()
expect Native.check_tool(Guix, "git::out").is_err()
expect Native.check_tool(Guix, "g++@12.3:lib").is_ok()

