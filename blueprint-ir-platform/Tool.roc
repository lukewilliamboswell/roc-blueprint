## A package: an attribute path in a package set, checked when the literal is
## compiled. "python3" and "python3Packages.ruff" come from "nixpkgs";
## "stable#python3" comes from the package set declared as
## `Packages("stable", ...)`.
Tool :: { source : Str, path : List(Str) }.{
	from_quote : Str -> Try(Tool, [BadQuotedBytes(Str)])
	from_quote = |raw| {
		(source, attr) =
			match raw.split_on("#") {
				[a] => ("nixpkgs", a)
				[s, a] => (s, a)
				_ => return Err(BadQuotedBytes("\"${raw}\" has more than one #; expected \"path\" or \"set#path\""))
			}
		parts = attr.split_on(".")
		if raw.contains(" ") {
			Err(BadQuotedBytes("package paths cannot contain spaces: \"${raw}\""))
		} else if source.is_empty() or source.contains(".") {
			Err(BadQuotedBytes("\"${raw}\" has no valid package set before #, like \"stable#python3\""))
		} else if parts.any(|p| p.is_empty()) {
			Err(BadQuotedBytes("\"${raw}\" is not an attribute path, like \"git\", \"python3Packages.ruff\" or \"stable#python3\""))
		} else {
			Ok(Tool.{ source, path: parts })
		}
	}

	## The package set it comes from, "nixpkgs" unless written as "set#path".
	source : Tool -> Str
	source = |tool| tool.source

	to_path : Tool -> List(Str)
	to_path = |tool| tool.path

	to_str : Tool -> Str
	to_str = |tool|
		if tool.source == "nixpkgs" {
			Str.join_with(tool.path, ".")
		} else {
			"${tool.source}#${Str.join_with(tool.path, ".")}"
		}
}
