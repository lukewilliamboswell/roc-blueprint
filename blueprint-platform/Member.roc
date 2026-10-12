import core.Project

## The path of a program inside an archive, such as "tool-1.0/bin/tool",
## checked at compile time: relative, with no empty, `.` or `..` segment, and
## not a URL, so that the two texts of an `Archive` cannot change places.
Member :: { path : Str }.{
	is_eq : _

	from_quote : Str -> Try(Member, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if raw.contains("://") {
			Err(BadQuotedBytes("\"${raw}\" is a URL, not the path of a program inside an archive"))
		} else if !Project.valid_output(raw) {
			Err(BadQuotedBytes("\"${raw}\" is not the path of a program inside an archive; expected a relative path such as \"tool-1.0/bin/tool\""))
		} else {
			Ok(Member.{ path: raw })
		}

	from_interpolation : Str, Iter((Str, Str)) -> Member
	from_interpolation = |first, rest| {
		var $text = first
		for (value, segment) in rest {
			$text = "${$text}${value}${segment}"
		}
		Member.{ path: $text }
	}

	to_str : Member -> Str
	to_str = |value| value.path
}

quoted : Str -> Try(Str, [BadQuotedBytes(Str)])
quoted = |raw| Member.from_quote(raw).map_ok(Member.to_str)

expect quoted("tool-1.0/bin/tool") == Ok("tool-1.0/bin/tool") and quoted("roc.exe").is_ok() and quoted("a b/tool").is_ok()
expect quoted("https://example.org/tool-1.0.tar.gz") == Err(BadQuotedBytes("\"https://example.org/tool-1.0.tar.gz\" is a URL, not the path of a program inside an archive"))
expect quoted("../tool") == Err(BadQuotedBytes("\"../tool\" is not the path of a program inside an archive; expected a relative path such as \"tool-1.0/bin/tool\""))
expect ["", "/usr/bin/tool", "bin//tool", "bin/./tool", "bin/", "C:\\tool", "a:b"].all(|raw| quoted(raw).is_err())
expect {
	top = "tool-1.0"
	member : Member
	member = "${top}/bin/tool"
	member.to_str() == "tool-1.0/bin/tool"
}
