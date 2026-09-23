## A flake input name, such as "nixpkgs" or "stable", checked at compile time.
InputName :: { name : Str }.{
	from_quote : Str -> Try(InputName, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if raw.is_empty() or raw.contains(" ") or raw.contains(".") or raw.contains("#") {
			Err(BadQuotedBytes("\"${raw}\" is not an input name; use letters, digits, - or _"))
		} else {
			Ok(InputName.{ name: raw })
		}

	to_str : InputName -> Str
	to_str = |value| value.name
}
