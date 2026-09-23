## A flake reference such as "github:roc-lang/roc-overlay", checked at compile time.
FlakeRef :: { url : Str }.{
	from_quote : Str -> Try(FlakeRef, [BadQuotedBytes(Str)])
	from_quote = |raw| {
		schemes = ["github:", "gitlab:", "git+", "path:", "https://", "tarball+"]
		if schemes.any(|s| raw.starts_with(s)) {
			Ok(FlakeRef.{ url: raw })
		} else {
			Err(BadQuotedBytes("\"${raw}\" is not a flake reference; expected one starting with github:, gitlab:, git+, path:, https:// or tarball+"))
		}
	}

	to_str : FlakeRef -> Str
	to_str = |value| value.url
}
