import Sexpr
import Value

## The Lock: Blueprint's committed record of resolved pins. Only Resolve writes
## it; every later stage reads it and never changes a pin or digest.
##
## - `format` — `{ major, minor }`, with the same compatibility rules as the
##   Spec: any minor of the current major parses, other majors are rejected
##   before anything else is read, unknown fields are ignored and optional
##   fields default to empty.
## - `sources` — one pinned Source per declared input: `{ name, provider,
##   ref, rev, digest }`. `digest` is an SRI string (e.g. `sha256-…`); `rev`
##   is empty when the source has none. Providers must keep these consistent
##   with their hints.
## - `hints` — provider-namespaced data `{ provider, value }` a provider needs
##   to reproduce its pins exactly, such as a native lock graph.
Lock := {
	format : { major : U64, minor : U64 },
	sources : List({ name : Str, provider : Str, ref : Str, rev : Str, digest : Str }),
	hints : List({ provider : Str, value : Value }),
}.{
	is_eq : _
	encoder_for : _

	Format : { major : U64, minor : U64 }
	Source : { name : Str, provider : Str, ref : Str, rev : Str, digest : Str }
	Hint : { provider : Str, value : Value }

	current_format : Format
	current_format = { major: 1, minor: 0 }

	to_str : Lock -> Str
	to_str = |lock| Str.concat(Sexpr.to_str(lock), "\n")

	## Parse the version header before interpreting any version-specific records.
	parse : Str -> Try(Lock, [InvalidSexpr(Str), MissingRequiredField(Str), UnsupportedFormat(Format)])
	parse = |text| {
		header : { format : Format }
		header = Sexpr.parse(text)?
		if header.format.major != current_format.major {
			return Err(UnsupportedFormat(header.format))
		}
		wire : Wire
		wire = Sexpr.parse(text)?
		Ok(
			Lock.{
				format: wire.format,
				sources: wire.sources ?? [],
				hints: wire.hints ?? [],
			},
		)
	}

	## The hint a provider wrote for itself, if any.
	hint : Lock, Str -> Try(Value, [MissingHint])
	hint = |lock, provider| lock.hints.find_first(|h| h.provider == provider)
		.map_ok(|h| h.value)
		.map_err(|_| MissingHint)
}

Wire : {
	format : Lock.Format,
	sources : Try(List(Lock.Source), [Missing]),
	hints : Try(List(Lock.Hint), [Missing]),
}

sample : Lock
sample = Lock.{
	format: Lock.current_format,
	sources: [{ name: "default", provider: "nix", ref: "github:NixOS/nixpkgs/nixos-unstable", rev: "4975466d324710c576dc11ad614684e6bd8cad8e", digest: "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=" }],
	hints: [{ provider: "nix", value: Value.Attrs([{ name: "version", value: Value.Int(7) }]) }],
}

expect Lock.parse(sample.to_str()) == Ok(sample)

# Same major, any minor; unknown fields ignored; optional fields default empty.
expect
	match Lock.parse(sample.to_str().replace_each("(minor 0)", "(minor 9)")) {
		Ok(lock) => lock.format == { major: 1, minor: 9 } and lock.sources == sample.sources
		Err(_) => False
	}
expect Lock.parse("((format ((major 1) (minor 0))))") == Ok(Lock.{ format: Lock.current_format, sources: [], hints: [] })
expect Lock.parse("((format ((major 1) (minor 0))) (future (1 2 3)))").is_ok()

# Other majors are rejected before the rest is read, even if it wouldn't parse.
expect Lock.parse("((format ((major 2) (minor 0))) (sources 42))") == Err(UnsupportedFormat({ major: 2, minor: 0 }))

# The pre-Lock JSON authority is not a Lock.
expect Lock.parse("{\"version\":1}").is_err()

expect sample.hint("nix").is_ok() and sample.hint("conda") == Err(MissingHint)
