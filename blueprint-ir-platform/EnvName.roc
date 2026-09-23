## A dev shell name, checked at compile time.
EnvName :: { name : Str }.{
	from_quote : Str -> Try(EnvName, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if raw.is_empty() or raw.contains(" ") or raw.contains(".") {
			Err(BadQuotedBytes("\"${raw}\" is not a shell name; use letters, digits, - or _"))
		} else {
			Ok(EnvName.{ name: raw })
		}

	to_str : EnvName -> Str
	to_str = |value| value.name
}
