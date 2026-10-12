import core.Project
import System

## A download URL with the System written into its path: "{system}", "{arch}"
## and "{os}" stand for the System asked about and its two parts, as in
## "https://example.org/1.0/tool-{system}". Checked at compile time: every
## placeholder is one of those three, none is in the host, and the URL is a
## download URL for every system Blueprint knows.
UrlTemplate :: { text : Str }.{
	is_eq : _

	from_quote : Str -> Try(UrlTemplate, [BadQuotedBytes(Str)])
	from_quote = |raw| {
		# What is left once the three placeholders are gone holds no brace.
		bare = fill(raw, "", "", "")
		if bare.contains("{") or bare.contains("}") {
			return Err(BadQuotedBytes("\"${raw}\" has a placeholder other than {system}, {arch} and {os}"))
		}
		authority = match raw.split_on("/") {
			[_, "", host, ..] => host
			_ => ""
		}
		if authority.contains("{") {
			return Err(BadQuotedBytes("\"${raw}\" has a placeholder in its host; the System belongs in the path"))
		}
		for arch in System.architectures {
			for os in System.operating_systems {
				if !Project.valid_download_url(fill(raw, "${arch}-${os}", arch, os)) {
					return Err(BadQuotedBytes("\"${raw}\" is not a download URL; expected https://<host>/<path> with no credentials, query or fragment"))
				}
			}
		}
		Ok(UrlTemplate.{ text: raw })
	}

	## The text with each placeholder replaced.
	fill : Str, Str, Str, Str -> Str
	fill = |text, system, arch, os| text.replace_each("{system}", system).replace_each("{arch}", arch).replace_each("{os}", os)

	## The URL for one System.
	for_system : UrlTemplate, System -> Str
	for_system = |template, system| {
		name = system.to_str()
		parts = name.split_on("-")
		fill(template.text, name, parts.first() ?? "", parts.last() ?? "")
	}

	to_str : UrlTemplate -> Str
	to_str = |value| value.text
}

quoted : Str -> Try(Str, [BadQuotedBytes(Str)])
quoted = |raw| UrlTemplate.from_quote(raw).map_ok(UrlTemplate.to_str)

expect quoted("https://example.org/releases/1.0/tool-{system}") == Ok("https://example.org/releases/1.0/tool-{system}")
expect quoted("https://example.org/{os}/{arch}/tool-{os}-{arch}.tar.gz").is_ok() and quoted("https://example.org/tool").is_ok() and quoted("http://127.0.0.1:4000/tool-{system}").is_ok()

# Any other placeholder, or a brace that closes nothing, is refused as one.
expect quoted("https://example.org/tool-{sytem}") == Err(BadQuotedBytes("\"https://example.org/tool-{sytem}\" has a placeholder other than {system}, {arch} and {os}"))
expect ["https://example.org/tool-{version}", "https://example.org/tool-{}", "https://example.org/tool-{system", "https://example.org/tool-system}", "https://example.org/tool-{System}", "https://example.org/{{os}}/tool"].all(|raw| quoted(raw) == Err(BadQuotedBytes("\"${raw}\" has a placeholder other than {system}, {arch} and {os}")))

# The host is the same for every System.
expect quoted("https://{os}.example.org/tool") == Err(BadQuotedBytes("\"https://{os}.example.org/tool\" has a placeholder in its host; the System belongs in the path"))
expect quoted("https://example.org:{arch}/tool").is_err() and quoted("{system}").is_err()

# What it is with the placeholders filled must be a download URL.
expect quoted("http://example.org/tool-{system}") == Err(BadQuotedBytes("\"http://example.org/tool-{system}\" is not a download URL; expected https://<host>/<path> with no credentials, query or fragment"))
expect ["https://example.org/{system}/", "https://example.org/tool-{system}?download=1", "https://user@example.org/tool-{os}", "https://example.org", "tool-{system}", ""].all(|raw| quoted(raw).is_err())

expect {
	template : UrlTemplate
	template = "https://example.org/{os}/{arch}/tool-{system}"
	template.for_system("aarch64-darwin") == "https://example.org/darwin/aarch64/tool-aarch64-darwin"
}
