## A nixpkgs attribute path, checked when the literal is compiled.
Tool :: { path : List(Str) }.{
	from_quote : Str -> Try(Tool, [BadQuotedBytes(Str)])
	from_quote = |raw| {
		parts = raw.split_on(".")
		if parts.any(|p| p.is_empty()) {
			Err(BadQuotedBytes("\"${raw}\" is not a nixpkgs attribute path, like \"git\" or \"python3Packages.ruff\""))
		} else if raw.contains(" ") {
			Err(BadQuotedBytes("nixpkgs attribute paths cannot contain spaces: \"${raw}\""))
		} else {
			Ok(Tool.{ path: parts })
		}
	}

	to_path : Tool -> List(Str)
	to_path = |tool| tool.path

	to_str : Tool -> Str
	to_str = |tool| Str.join_with(tool.path, ".")
}
