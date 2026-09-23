## A task name, checked at compile time.
TaskName :: { name : Str }.{
	from_quote : Str -> Try(TaskName, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if raw.is_empty() or raw.contains(" ") {
			Err(BadQuotedBytes("\"${raw}\" is not a task name; use letters, digits, ., - or _"))
		} else {
			Ok(TaskName.{ name: raw })
		}

	to_str : TaskName -> Str
	to_str = |value| value.name
}
