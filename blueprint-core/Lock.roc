import Project
import Sexpr
import Spec
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
## - `intent` — the parts of the Spec that Resolve consumed: source and input
##   declarations, build sources and each environment's overlay order, sorted
##   by name. A Lock whose intent differs from the current Spec is stale.
## - `hints` — provider-namespaced data `{ provider, value }` a provider needs
##   to reproduce its pins exactly, such as a native lock graph.
## - `fetched` — one entry per declared program and System: `{ name, system,
##   url, sha256, size }`, the SHA-256 (in hex) and length of what `url`
##   served when it was resolved. Programs are not part of `intent`: each
##   entry carries its URL, so one program whose URL changed is stale alone.
Lock := {
	format : { major : U64, minor : U64 },
	intent : {
		sources : List(Spec.Source),
		inputs : List(Spec.Input),
		build_sources : List(Spec.BuildSource),
		overlays : List({ environment : Str, overlays : List(Str) }),
	},
	sources : List({ name : Str, provider : Str, ref : Str, rev : Str, digest : Str }),
	hints : List({ provider : Str, value : Value }),
	fetched : List({ name : Str, system : Str, url : Str, sha256 : Str, size : U64 }),
}.{
	is_eq : _
	encoder_for : _

	Format : { major : U64, minor : U64 }
	Source : { name : Str, provider : Str, ref : Str, rev : Str, digest : Str }
	Hint : { provider : Str, value : Value }
	Fetched : { name : Str, system : Str, url : Str, sha256 : Str, size : U64 }
	Intent : {
		sources : List(Spec.Source),
		inputs : List(Spec.Input),
		build_sources : List(Spec.BuildSource),
		overlays : List({ environment : Str, overlays : List(Str) }),
	}

	## What Resolve consumes from a validated Spec. Declaration order is not
	## part of the intent; overlay order within an environment is.
	intent_of : Spec -> Intent
	intent_of = |spec| {
		sources: spec.sources.sort_with(|x, y| Project.bytewise(x.name, y.name)),
		inputs: spec.inputs.sort_with(|x, y| Project.bytewise(x.name, y.name)),
		build_sources: spec.build_sources.sort_with(|x, y| Project.bytewise(x.name, y.name)),
		overlays: spec.environments
			.keep_if(|env| !env.overlays.is_empty())
			.map(|env| { environment: env.name, overlays: env.overlays })
			.sort_with(|x, y| Project.bytewise(x.environment, y.environment)),
	}

	empty_intent : Intent
	empty_intent = { sources: [], inputs: [], build_sources: [], overlays: [] }

	## Fail, naming what changed, when the Spec no longer matches what was
	## resolved. Settings Resolve does not consume never make a Lock stale.
	stale : Lock, Spec -> Try({}, Str)
	stale = |lock, spec| {
		current = intent_of(spec)
		changed = |what, same| if same [] else [what]
		differences = changed("sources", lock.intent.sources == current.sources)
			.concat(changed("inputs", lock.intent.inputs == current.inputs))
			.concat(changed("build sources", lock.intent.build_sources == current.build_sources))
			.concat(changed("environment overlays", lock.intent.overlays == current.overlays))
		if differences.is_empty() {
			Ok({})
		} else {
			Err("Blueprint.roc changed its ${Str.join_with(differences, ", ")} since the lock was resolved; run blueprint update")
		}
	}

	current_format : Format
	current_format = { major: 1, minor: 1 }

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
				intent: wire.intent ?? empty_intent,
				sources: wire.sources ?? [],
				hints: wire.hints ?? [],
				fetched: wire.fetched ?? [],
			},
		)
	}

	## The hint a provider wrote for itself, if any.
	hint : Lock, Str -> Try(Value, [MissingHint])
	hint = |lock, provider| lock.hints.find_first(|h| h.provider == provider)
		.map_ok(|h| h.value)
		.map_err(|_| MissingHint)

	## The SHA-256, in hex, the Lock records for a program on its System.
	## `NotLocked`: the program was declared after the Lock was resolved.
	## `UrlChanged` carries the URL the Lock was resolved from: the Spec now
	## names another, whose bytes nothing has recorded.
	fetched_for : Lock, Spec.Program -> Try(Str, [NotLocked, UrlChanged(Str)])
	fetched_for = |lock, program|
		match lock.fetched.find_first(|entry| entry.name == program.name and entry.system == program.system) {
			Ok(entry) => if entry.url == program.url Ok(entry.sha256) else Err(UrlChanged(entry.url))
			Err(_) => Err(NotLocked)
		}
}

Wire : {
	format : Lock.Format,
	intent : Try(Lock.Intent, [Missing]),
	sources : Try(List(Lock.Source), [Missing]),
	hints : Try(List(Lock.Hint), [Missing]),
	fetched : Try(List(Lock.Fetched), [Missing]),
}

sample : Lock
sample = Lock.{
	format: Lock.current_format,
	intent: { ..Lock.empty_intent, sources: [{ name: "default", provider: Auto }] },
	sources: [{ name: "default", provider: "nix", ref: "github:NixOS/nixpkgs/nixos-unstable", rev: "4975466d324710c576dc11ad614684e6bd8cad8e", digest: "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=" }],
	hints: [{ provider: "nix", value: Value.Attrs([{ name: "version", value: Value.Int(7) }]) }],
	fetched: [
		{ name: "roc-stable", system: "x86_64-linux", url: "https://example.test/roc-linux.tar.gz", sha256: "893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f", size: 69614310 },
		{ name: "roc-stable", system: "aarch64-darwin", url: "https://example.test/roc-macos.tar.gz", sha256: "e0147f62f072a309519cbc2a6ebfa11e4bb8bac7903d5febaf7a112d1fc2842f", size: 66810227 },
	],
}

expect Lock.parse(sample.to_str()) == Ok(sample)

# Same major, any minor; unknown fields ignored; optional fields default empty.
expect
	match Lock.parse(sample.to_str().replace_each("(minor 1)", "(minor 9)")) {
		Ok(lock) => lock.format == { major: 1, minor: 9 } and lock.sources == sample.sources
		Err(_) => False
	}
expect Lock.parse("((format ((major 1) (minor 1))))") == Ok(Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [], hints: [], fetched: [] })
expect Lock.parse("((format ((major 1) (minor 0))) (future (1 2 3)))").is_ok()

# A 1.0 Lock, as blueprint 0.5 wrote it, has fetched nothing and keeps its pins.
expect
	match Lock.parse("((format ((major 1) (minor 0))) (hints ()) (intent ((build_sources ()) (inputs ()) (overlays ()) (sources (((name \"default\") (provider Auto)))))) (sources (((digest \"sha256:00\") (name \"default\") (provider \"nix\") (ref \"github:NixOS/nixpkgs/nixos-unstable\") (rev \"abc\")))))") {
		Ok(lock) => lock.format == { major: 1, minor: 0 } and lock.fetched == [] and lock.sources.map(|source| source.rev) == ["abc"] and lock.intent.sources == [{ name: "default", provider: Auto }]
		Err(_) => False
	}

# A fetched entry is whole or the Lock is not read.
expect Lock.parse("((format ((major 1) (minor 1))) (fetched (((name \"roc-stable\") (system \"x86_64-linux\") (url \"https://example.test/roc.tar.gz\") (size 1)))))").is_err()
expect Lock.parse("((format ((major 1) (minor 1))) (fetched (((name \"roc-stable\") (system \"x86_64-linux\") (url \"https://example.test/roc.tar.gz\") (sha256 \"00\") (size -1)))))").is_err()

# Other majors are rejected before the rest is read, even if it wouldn't parse.
expect Lock.parse("((format ((major 2) (minor 0))) (sources 42))") == Err(UnsupportedFormat({ major: 2, minor: 0 }))

# The pre-Lock JSON authority is not a Lock.
expect Lock.parse("{\"version\":1}").is_err()

expect sample.hint("nix").is_ok() and sample.hint("conda") == Err(MissingHint)

# Only what Resolve consumes can make a Lock stale, and the error says what.
expect {
	spec = { ..Spec.empty("x"), sources: [{ name: "default", provider: Auto }] }
	lock = { ..sample, intent: Lock.intent_of(spec) }
	with_task = { ..spec, tasks: [{ name: "t", environment: "e", run: ["true"] }] }
	with_input = { ..spec, inputs: [{ name: "roc", url: "github:roc-lang/roc-overlay", kind: Overlay }] }
	lock.stale(spec) == Ok({})
		and lock.stale(with_task) == Ok({})
			and lock.stale(with_input) == Err("Blueprint.roc changed its inputs since the lock was resolved; run blueprint update")
}

# Declaration order is not intent; overlay order is.
expect {
	a = { name: "a", provider: Auto }
	b = { name: "b", provider: Auto }
	env = |overlays| { name: "dev", parents: [], tools: [], overlays }
	one = { ..Spec.empty("x"), sources: [a, b], environments: [env(["p", "q"])] }
	two = { ..Spec.empty("x"), sources: [b, a], environments: [env(["p", "q"])] }
	swapped = { ..one, environments: [env(["q", "p"])] }
	Lock.intent_of(one) == Lock.intent_of(two) and Lock.intent_of(one) != Lock.intent_of(swapped)
}

# A program's digest is the one recorded for its name, System and URL.
expect {
	linux = { name: "roc-stable", system: "x86_64-linux", url: "https://example.test/roc-linux.tar.gz", unpack: TarGz, path: "roc/roc" }
	sample.fetched_for(linux) == Ok("893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f")
		and sample.fetched_for({ ..linux, system: "aarch64-darwin", url: "https://example.test/roc-macos.tar.gz" }) == Ok("e0147f62f072a309519cbc2a6ebfa11e4bb8bac7903d5febaf7a112d1fc2842f")
			# How the bytes are unpacked is not what was resolved.
			and sample.fetched_for({ ..linux, unpack: File, path: "" }) == Ok("893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f")
}

# A changed URL names the one that was resolved; nothing else matches it.
expect {
	linux = { name: "roc-stable", system: "x86_64-linux", url: "https://example.test/roc-linux.tar.gz", unpack: TarGz, path: "roc/roc" }
	sample.fetched_for({ ..linux, url: "https://example.test/newer.tar.gz" }) == Err(UrlChanged("https://example.test/roc-linux.tar.gz"))
		and sample.fetched_for({ ..linux, system: "aarch64-linux" }) == Err(NotLocked)
			and sample.fetched_for({ ..linux, name: "roc" }) == Err(NotLocked)
}

# Programs are not intent: declaring one leaves the pins of the Lock current.
expect {
	spec = { ..Spec.empty("x"), sources: [{ name: "default", provider: Auto }] }
	lock = { ..sample, intent: Lock.intent_of(spec) }
	lock.stale({ ..spec, programs: [{ name: "tool", system: "x86_64-linux", url: "https://example.test/tool", unpack: File, path: "" }] }) == Ok({})
}
