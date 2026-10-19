## The tag of a roc-lang/nightlies release, such as
## "nightly-2026-10-04-130536d", checked at compile time:
## `nightly-YYYY-MM-DD-<commit>`, the commit 7 to 40 lowercase hex digits.
NightlyTag :: { tag : Str }.{
	is_eq : _

	from_quote : Str -> Try(NightlyTag, [BadQuotedBytes(Str)])
	from_quote = |raw|
		if valid(raw) {
			Ok(NightlyTag.{ tag: raw })
		} else {
			Err(BadQuotedBytes("\"${raw}\" is not a Roc nightly tag; expected nightly-YYYY-MM-DD-<commit>"))
		}

	valid : Str -> Bool
	valid = |tag| {
		digits = |part, count| part.to_utf8().len() == count and part.to_utf8().all(|b| b >= '0' and b <= '9')
		match tag.split_on("-") {
			["nightly", year, month, day, commit] =>
				digits(year, 4) and digits(month, 2) and digits(day, 2)
					and commit.to_utf8().len() >= 7 and commit.to_utf8().len() <= 40
					and commit.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))

			_ => False
		}
	}

	to_str : NightlyTag -> Str
	to_str = |value| value.tag
}

expect NightlyTag.from_quote("nightly-2026-10-04-130536d").map_ok(NightlyTag.to_str) == Ok("nightly-2026-10-04-130536d")
expect NightlyTag.from_quote("v1.0").map_ok(NightlyTag.to_str) == Err(BadQuotedBytes("\"v1.0\" is not a Roc nightly tag; expected nightly-YYYY-MM-DD-<commit>"))

# A tag of another shape is not one, and never becomes part of a URL.
expect ["nightly", "0.1.0", "nightly-2026-10-4-130536d", "nightly-2026-10-04-13053", "nightly-2026-10-04-130536D", "nightly-2026-10-04-130536d/..", "nightly-2026-10-04-130536d-extra", "nightly-latest", "rocpkgs.nightly-2026-10-04-130536d", ""].all(|tag| !NightlyTag.valid(tag))

# A full commit hash is a tag too.
expect NightlyTag.valid("nightly-2026-10-04-130536d0123456789abcdef0123456789abcdef0") and !NightlyTag.valid("nightly-2026-10-04-130536d0123456789abcdef0123456789abcdef01")
