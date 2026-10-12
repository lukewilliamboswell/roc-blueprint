import core.Project

## The command name of a fetched program or of a tool the machine is expected
## to have, checked at compile time: a file name on PATH.
ProgramName :: { name : Str }.{
	from_quote : Str -> Try(ProgramName, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if !Project.valid_command_name(raw) {
			Err(BadQuotedBytes("\"${raw}\" is not a program name; use letters, digits, - _ . or +, not starting with - or ."))
		} else {
			Ok(ProgramName.{ name: raw })
		}

	to_str : ProgramName -> Str
	to_str = |value| value.name
}
