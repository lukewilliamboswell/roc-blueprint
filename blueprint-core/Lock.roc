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
}.{
	is_eq : _
	encoder_for : _

	Format : { major : U64, minor : U64 }
	Source : { name : Str, provider : Str, ref : Str, rev : Str, digest : Str }
	Hint : { provider : Str, value : Value }
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
				intent: wire.intent ?? empty_intent,
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
	intent : Try(Lock.Intent, [Missing]),
	sources : Try(List(Lock.Source), [Missing]),
	hints : Try(List(Lock.Hint), [Missing]),
}

sample : Lock
sample = Lock.{
	format: Lock.current_format,
	intent: { ..Lock.empty_intent, sources: [{ name: "default", provider: Auto }] },
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
expect Lock.parse("((format ((major 1) (minor 0))))") == Ok(Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [], hints: [] })
expect Lock.parse("((format ((major 1) (minor 0))) (future (1 2 3)))").is_ok()

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
