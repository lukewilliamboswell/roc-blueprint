import core.Project

## Where a download is fetched from: `https://<host>/<path>`, with no
## credentials, query or fragment. A quoted URL is checked as it compiles. One
## built by interpolation, as in "https://example.org/${version}/tool", is
## assembled as it is and checked with the rest of the configuration.
##
## Only text can be interpolated: write `${system.to_str()}` for a System, or
## use `Recipes.file` with a `{system}` placeholder.
Url :: { text : Str }.{
	is_eq : _

	from_quote : Str -> Try(Url, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if Project.valid_download_url(raw) {
			Ok(Url.{ text: raw })
		} else {
			Err(BadQuotedBytes("\"${raw}\" is not a download URL; expected https://<host>/<path> with no credentials, query or fragment"))
		}

	from_interpolation : List(Str) -> Try((List(Str) -> Url), [InvalidInterpolation(Str)])
	from_interpolation = |segments|
		Str.from_interpolation(segments).map_ok(|assemble| |values| Url.{ text: assemble(values) })

	## A URL assembled from text that is checked elsewhere. The whole
	## configuration is validated after lowering, this URL with it.
	assembled : Str -> Url
	assembled = |text| Url.{ text }

	to_str : Url -> Str
	to_str = |value| value.text
}

quoted : Str -> Try(Str, [BadQuotedBytes(Str)])
quoted = |raw| Url.from_quote(raw).map_ok(Url.to_str)

expect quoted("https://example.org/releases/1.0/tool") == Ok("https://example.org/releases/1.0/tool")
expect quoted("http://127.0.0.1:8080/tool").is_ok()
expect quoted("http://example.org/tool") == Err(BadQuotedBytes("\"http://example.org/tool\" is not a download URL; expected https://<host>/<path> with no credentials, query or fragment"))
expect ["", "example.org/tool", "https://example.org", "https://user@example.org/tool", "https://example.org/tool?v=1", "https://example.org/tool#x", "tool-1.0/bin/tool"].all(|raw| quoted(raw).is_err())

# An interpolated URL is its text, whatever that is: validation sees it later.
expect {
	version = "1.0"
	url : Url
	url = "https://example.org/${version}/tool-${version}.tar.gz"
	url.to_str() == "https://example.org/1.0/tool-1.0.tar.gz" and url == Url.assembled("https://example.org/1.0/tool-1.0.tar.gz")
}
