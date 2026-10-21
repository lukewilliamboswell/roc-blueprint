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
##   ref, rev, digest }`. `digest` is a content identity (`sha256:<hex>`); `rev`
##   is empty when the source has none. Providers must keep these consistent
##   with their hints.
## - `intent` — the parts of the Spec that Resolve consumed: source and input
##   declarations, the build sources a provider resolves (see
##   `Project.resolved_build_sources`) and each environment's overlay order,
##   sorted by name. A Lock whose intent differs from the current Spec is
##   stale.
## - `hints` — provider-namespaced data `{ provider, value }` a provider needs
##   to reproduce its pins exactly, such as a native lock graph.
## - `fetched` — one entry per declared program and System: `{ name, system,
##   urls, sha256, size, obtained }`, the SHA-256 (in hex) and length of the
##   download when it was resolved, the URLs it was declared with, primary
##   first, and how the digest was obtained (see `Obtained`). Programs are not
##   part of `intent`: each entry carries its URLs, so one program whose URLs
##   changed is stale alone.
Lock := {
	format : { major : U64, minor : U64 },
	intent : {
		resolvers : List(Spec.Resolver),
		sources : List(Spec.Source),
		inputs : List(Spec.Input),
		build_sources : List(Spec.BuildSource),
		overlays : List({ environment : Str, overlays : List(Str) }),
	},
	sources : List({ name : Str, provider : Str, ref : Str, rev : Str, digest : Str }),
	hints : List({ provider : Str, value : Value }),
	fetched : List({ name : Str, system : Str, urls : List(Str), sha256 : Str, size : U64, obtained : [Computed, Published, Both, Unstated] }),
}.{
	is_eq : _
	encoder_for : _

	Format : { major : U64, minor : U64 }
	Source : { name : Str, provider : Str, ref : Str, rev : Str, digest : Str }
	Hint : { provider : Str, value : Value }
	Fetched : { name : Str, system : Str, urls : List(Str), sha256 : Str, size : U64, obtained : Obtained }

	## How Resolve came by a download's digest, which is what a reviewer of
	## the Lock is trusting. `Computed`: it downloaded the bytes and hashed
	## them, and nobody else's word was to be had. `Published`: the release
	## that serves the download reports this digest, and the bytes were not
	## downloaded; a run on that System still checks its download against
	## it. `Both`: it hashed the bytes and the release reports the same.
	## `Unstated`: the digest provenance is explicitly unknown.
	Obtained : [Computed, Published, Both, Unstated]

	## A download's digest, in hex, and its length.
	Digest : { sha256 : Str, size : U64 }

	## The entry Resolve records for a program, from what it hashed itself
	## and what the release reports, when there is either. Two digests that
	## differ are never reconciled: one of them is not the release, and
	## nothing is recorded.
	record : Spec.Program, Try(Digest, [NotDownloaded]), Try(Digest, [NotPublished]) -> Try(Fetched, Str)
	record = |program, computed, published| {
		entry = |digest, obtained| { name: program.name, system: program.system, urls: program.urls, sha256: digest.sha256, size: digest.size, obtained }
		match (computed, published) {
			(Ok(own), Ok(theirs)) =>
				if own == theirs {
					Ok(entry(own, Both))
				} else {
					Err("${program.name} for ${program.system}: the download has SHA-256 ${own.sha256} and ${own.size.to_str()} bytes, and its release publishes ${theirs.sha256} and ${theirs.size.to_str()} bytes; nothing was recorded. One of the two is not what was released: do not use this download until you know which")
				}

			(Ok(own), Err(NotPublished)) => Ok(entry(own, Computed))
			(Err(NotDownloaded), Ok(theirs)) => Ok(entry(theirs, Published))
			(Err(NotDownloaded), Err(NotPublished)) => Err("${program.name} for ${program.system}: no digest was computed or published")
		}
	}

	## What an update does with one declared program: keep the entry the
	## Lock has, or obtain its digest again.
	Refresh : [Keep(Fetched), Obtain(Spec.Program)]

	## What an update does with each program a Spec declares, in the Spec's
	## order, given the entries of the Lock it starts from. An update of
	## everything keeps an entry whose name, System and URLs are unchanged,
	## and obtains every other. An update of named programs obtains those
	## again whatever the Lock holds, and keeps the entry of every other
	## program as it is, current or not; one with no entry gets none. An
	## entry of a program that is no longer declared is dropped either way.
	refresh : List(Spec.Program), List(Fetched), [All, Named(List(Str))] -> List(Refresh)
	refresh = |programs, held, update| {
		var $plan = []
		for program in programs {
			entry = held.find_first(|candidate| candidate.name == program.name and candidate.system == program.system)
			match (update, entry) {
				(All, Ok(found)) => {
					$plan = $plan.append(if (found.urls == program.urls) Keep(found) else Obtain(program))
				}
				(All, Err(_)) => {
					$plan = $plan.append(Obtain(program))
				}
				(Named(names), found) =>
					if names.contains(program.name) {
						$plan = $plan.append(Obtain(program))
					} else {
						match found {
							Ok(kept) => {
								$plan = $plan.append(Keep(kept))
							}
							Err(_) => {}
						}
					}
			}
		}
		$plan
	}

	## The host of a download URL, without a port.
	host : Str -> Str
	host = |url|
		match url.split_on("/") {
			[_, "", authority, ..] => authority.split_on(":").first() ?? authority
			_ => ""
		}

	## Every host the Lock's downloads name, each once, in order of first use.
	hosts : List(Fetched) -> List(Str)
	hosts = |entries| Project.unique(entries.fold([], |all, entry| all.concat(entry.urls.map(host))).keep_if(|name| !name.is_empty()))

	## The download hosts `after` names and `before` did not: what a
	## reviewer of an update should notice.
	new_hosts : List(Fetched), List(Fetched) -> List(Str)
	new_hosts = |before, after| {
		known = hosts(before)
		hosts(after).keep_if(|name| !known.contains(name))
	}

	Intent : {
		resolvers : List(Spec.Resolver),
		sources : List(Spec.Source),
		inputs : List(Spec.Input),
		build_sources : List(Spec.BuildSource),
		overlays : List({ environment : Str, overlays : List(Str) }),
	}

	## What Resolve consumes from a validated Spec. Declaration order is not
	## part of the intent; overlay order within an environment is.
	intent_of : Spec -> Intent
	intent_of = |spec| {
		resolvers: spec.resolvers.map(|resolver| { provider: resolver.provider, inputs: resolver.inputs.sort_with(Project.bytewise) }).sort_with(|a, b| Project.bytewise(a.provider, b.provider)),
		sources: spec.sources.sort_with(|x, y| Project.bytewise(x.name, y.name)),
		inputs: spec.inputs.sort_with(|x, y| Project.bytewise(x.name, y.name)),
		build_sources: Project.resolved_build_sources(spec).sort_with(|x, y| Project.bytewise(x.name, y.name)),
		overlays: spec.environments
			.keep_if(|env| !env.overlays.is_empty())
			.map(|env| { environment: env.name, overlays: env.overlays })
			.sort_with(|x, y| Project.bytewise(x.environment, y.environment)),
	}

	empty_intent : Intent
	empty_intent = { resolvers: [], sources: [], inputs: [], build_sources: [], overlays: [] }

	## Fail, naming what changed, when the Spec no longer matches what was
	## resolved. Settings Resolve does not consume never make a Lock stale.
	stale : Lock, Spec -> Try({}, Str)
	stale = |lock, spec| {
		file_pins = spec.source_files.map(file_pin).sort_with(|a, b| Project.bytewise(a.name, b.name))
		locked_files = lock.sources.keep_if(|source| source.provider == "file").sort_with(|a, b| Project.bytewise(a.name, b.name))
		if file_pins != locked_files {
			return Err("Blueprint.roc changed its file sources since the lock was resolved; run blueprint update")
		}

		current = intent_of(spec)
		changed = |what, same| if (same) [] else [what]
		differences = changed("sources", lock.intent.sources == current.sources)
			.concat(changed("inputs", lock.intent.inputs == current.inputs))
			.concat(changed("resolver ownership", lock.intent.resolvers == current.resolvers))
			.concat(changed("build sources", lock.intent.build_sources == current.build_sources))
			.concat(changed("environment overlays", lock.intent.overlays == current.overlays))
		if differences.is_empty() {
			Ok({})
		} else {
			Err("Blueprint.roc changed its ${Str.join_with(differences, ", ")} since the lock was resolved; run blueprint update")
		}
	}

	## Flat-file sources are Core-owned authority, not NAR tree identities.
	## An explicit named update may replace only the named original-file pins.
	## All other declarations and authority must still match. Verification of
	## the newly declared bytes happens before the executor publishes the lock.
	stale_except_files : Lock, Spec, List(Str) -> Try({}, Str)
	stale_except_files = |lock, spec, names| {
		kept_lock = { ..lock, sources: lock.sources.keep_if(|source| source.provider != "file" or !names.contains(source.name)) }
		kept_spec = { ..spec, source_files: spec.source_files.keep_if(|source| !names.contains(source.name)) }
		stale(kept_lock, kept_spec)
	}

	## Flat-file sources are Core-owned authority, not NAR tree identities.
	file_pin : Spec.SourceFile -> Source
	file_pin = |source| { name: source.name, provider: "file", ref: source.url, rev: "", digest: "sha256:${source.sha256}" }

	current_format : Format
	current_format = { major: 2, minor: 0 }

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
				fetched: (wire.fetched ?? []).map(|entry| { name: entry.name, system: entry.system, urls: entry.urls, sha256: entry.sha256, size: entry.size, obtained: entry.obtained }),
			},
		)
	}

	## The hint a provider wrote for itself, if any.
	hint : Lock, Str -> Try(Value, [MissingHint])
	hint = |lock, provider| lock.hints.find_first(|h| h.provider == provider)
		.map_ok(|h| h.value)
		.map_err(|_| MissingHint)

	## What the Lock records for a program on its System: the SHA-256, in
	## hex, and the length of its download.
	## `NotLocked`: the program was declared after the Lock was resolved.
	## `UrlsChanged` carries the URLs the Lock was resolved with: the Spec now
	## names others, or the same in another order. The entry is current only
	## when the whole list is unchanged. The digest is fixed, so a later
	## change may let an added alternate keep the entry; nothing does yet.
	fetched_for : Lock, Spec.Program -> Try(Fetched, [NotLocked, UrlsChanged(List(Str))])
	fetched_for = |lock, program|
		match lock.fetched.find_first(|entry| entry.name == program.name and entry.system == program.system) {
			Ok(entry) => if (entry.urls == program.urls) Ok(entry) else Err(UrlsChanged(entry.urls))
			Err(_) => Err(NotLocked)
		}
}

Wire : {
	format : Lock.Format,
	intent : Try(Lock.Intent, [Missing]),
	sources : Try(List(Lock.Source), [Missing]),
	hints : Try(List(Lock.Hint), [Missing]),
	fetched : Try(List(WireFetched), [Missing]),
}

WireFetched : { name : Str, system : Str, urls : List(Str), sha256 : Str, size : U64, obtained : Lock.Obtained }

sample : Lock
sample = Lock.{
	format: Lock.current_format,
	intent: { ..Lock.empty_intent, sources: [{ name: "nix", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-unstable" } }] },
	sources: [{ name: "nix", provider: "nix", ref: "github:NixOS/nixpkgs/nixos-unstable", rev: "4975466d324710c576dc11ad614684e6bd8cad8e", digest: "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU=" }],
	hints: [{ provider: "nix", value: Value.Attrs([{ name: "version", value: Value.Int(7) }]) }],
	fetched: [
		{ name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/roc-linux.tar.gz"], sha256: "893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f", size: 69614310, obtained: Both },
		{ name: "roc-stable", system: "aarch64-darwin", urls: ["https://example.test/roc-macos.tar.gz", "https://mirror.example.test/roc-macos.tar.gz"], sha256: "e0147f62f072a309519cbc2a6ebfa11e4bb8bac7903d5febaf7a112d1fc2842f", size: 66810227, obtained: Published },
	],
}

expect Lock.parse(sample.to_str()) == Ok(sample)

# Same major, any minor; unknown fields ignored; optional fields default empty.
expect
	match Lock.parse(sample.to_str().replace_each("(minor 0)", "(minor 9)")) {
		Ok(lock) => lock.format == { major: 2, minor: 9 } and lock.sources == sample.sources
		Err(_) => False
	}
expect Lock.parse("((format ((major 2) (minor 0))))") == Ok(Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [], hints: [], fetched: [] })
expect Lock.parse("((format ((major 2) (minor 0))) (future (1 2 3)))").is_ok()

# Locks with unsupported major versions are rejected.
expect Lock.parse("((format ((major 1) (minor 0))))") == Err(UnsupportedFormat({ major: 1, minor: 0 }))

expect Lock.parse("((format ((major 3) (minor 0))) (sources 42))") == Err(UnsupportedFormat({ major: 3, minor: 0 }))

# The pre-Lock JSON authority is not a Lock.
expect Lock.parse("{\"version\":1}").is_err()

expect sample.hint("nix").is_ok() and sample.hint("conda") == Err(MissingHint)

# Only what Resolve consumes can make a Lock stale, and the error says what.
expect {
	spec = { ..Spec.empty("x"), sources: [{ name: "nix", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-unstable" } }] }
	lock = { ..sample, intent: Lock.intent_of(spec) }
	with_task = { ..spec, tasks: [{ name: "t", environment: "e", run: ["true"] }] }
	with_input = { ..spec, inputs: [{ name: "roc", url: "github:roc-lang/roc-overlay", kind: Overlay }] }
	lock.stale(spec) == Ok({})
		and lock.stale(with_task) == Ok({})
		and lock.stale(with_input) == Err("Blueprint.roc changed its inputs since the lock was resolved; run blueprint update")
}

# Declaration order is not intent; overlay order is.
expect {
	a = { name: "a", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-unstable" } }
	b = { name: "b", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-24.05" } }
	env = |overlays| { name: "dev", parents: [], tools: [], overlays }
	one = { ..Spec.empty("x"), sources: [a, b], environments: [env(["p", "q"])] }
	two = { ..Spec.empty("x"), sources: [b, a], environments: [env(["p", "q"])] }
	swapped = { ..one, environments: [env(["q", "p"])] }
	Lock.intent_of(one) == Lock.intent_of(two) and Lock.intent_of(one) != Lock.intent_of(swapped)
}

# A program's digest is the one recorded for its name, System and URLs.
expect {
	linux = { name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/roc-linux.tar.gz"], unpack: TarGz, path: "roc/roc" }
	sample.fetched_for(linux).map_ok(|entry| (entry.sha256, entry.size)) == Ok(("893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f", 69614310))
		and sample.fetched_for({ ..linux, system: "aarch64-darwin", urls: ["https://example.test/roc-macos.tar.gz", "https://mirror.example.test/roc-macos.tar.gz"] }).map_ok(|entry| entry.sha256) == Ok("e0147f62f072a309519cbc2a6ebfa11e4bb8bac7903d5febaf7a112d1fc2842f")
		# How the bytes are unpacked is not what was resolved.
		and sample.fetched_for({ ..linux, unpack: File, path: "" }).map_ok(|entry| entry.sha256) == Ok("893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f")
}

# Changed URLs name the ones that were resolved; nothing else matches them.
# An added, removed or reordered alternate is a change.
expect {
	linux = { name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/roc-linux.tar.gz"], unpack: TarGz, path: "roc/roc" }
	macos = ["https://example.test/roc-macos.tar.gz", "https://mirror.example.test/roc-macos.tar.gz"]
	sample.fetched_for({ ..linux, urls: ["https://example.test/newer.tar.gz"] }) == Err(UrlsChanged(["https://example.test/roc-linux.tar.gz"]))
		and sample.fetched_for({ ..linux, urls: ["https://example.test/roc-linux.tar.gz", "https://mirror.example.test/roc-linux.tar.gz"] }) == Err(UrlsChanged(["https://example.test/roc-linux.tar.gz"]))
		and sample.fetched_for({ ..linux, system: "aarch64-darwin", urls: ["https://example.test/roc-macos.tar.gz"] }) == Err(UrlsChanged(macos))
		and sample.fetched_for({ ..linux, system: "aarch64-darwin", urls: ["https://mirror.example.test/roc-macos.tar.gz", "https://example.test/roc-macos.tar.gz"] }) == Err(UrlsChanged(macos))
		and sample.fetched_for({ ..linux, system: "aarch64-linux" }) == Err(NotLocked)
		and sample.fetched_for({ ..linux, name: "roc" }) == Err(NotLocked)
}

# Programs are not intent: declaring one leaves the pins of the Lock current.
expect {
	spec = { ..Spec.empty("x"), sources: [{ name: "nix", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-unstable" } }] }
	lock = { ..sample, intent: Lock.intent_of(spec) }
	lock.stale({ ..spec, programs: [{ name: "tool", system: "x86_64-linux", urls: ["https://example.test/tool"], unpack: File, path: "" }] }) == Ok({})
}

# The bundle of a Roc package that only tasks use is not what Resolve
# consumed: declaring one leaves the Lock current, and a build in that
# environment makes it stale, because a provider must then lock the bundle.
expect {
	spec = { ..Spec.empty("x"), requires_: ["sources", "builds", "roc-packages"], environments: [{ name: "dev", parents: [], tools: [], overlays: [] }] }
	lock = { ..sample, intent: Lock.intent_of(spec) }
	bundled = { ..spec, build_sources: [{ name: "roc-abc", ref: "tarball+https://example.test/abc.tar.zst" }], roc_packages: [{ environment: "dev", name: "abc", source: "roc-abc" }] }
	built = { ..bundled, builds: [{ name: "app", environment: "dev", inputs: [], needs: [], run: ["true"], output: "out" }] }
	Lock.intent_of(bundled).build_sources == []
		and lock.stale(bundled) == Ok({})
		and lock.stale(built) == Err("Blueprint.roc changed its build sources since the lock was resolved; run blueprint update")
}

# Current entries always record how their digest was obtained.
expect sample.to_str().contains("(obtained Both)") and sample.to_str().contains("(obtained Published)")
expect Lock.parse({ ..sample, fetched: sample.fetched.map(|entry| { ..entry, obtained: Unstated }) }.to_str()).map_ok(|lock| lock.fetched.map(|entry| entry.obtained)) == Ok([Unstated, Unstated])
expect Lock.parse("((format ((major 2) (minor 0))) (fetched (((name \"roc-stable\") (system \"x86_64-linux\") (urls (\"https://example.test/roc.tar.gz\")) (sha256 \"00\") (size 1)))))").is_err()
expect Lock.parse("((format ((major 2) (minor 0))) (fetched (((name \"t\") (system \"x86_64-linux\") (urls (\"https://example.test/t\")) (sha256 \"00\") (size 1) (obtained Computed)))))").map_ok(|lock| lock.fetched.map(|entry| entry.obtained)) == Ok([Computed])
expect Lock.parse("((format ((major 2) (minor 0))) (fetched (((name \"t\") (system \"x86_64-linux\") (urls (\"https://example.test/t\")) (sha256 \"00\") (size 1) (obtained Guessed)))))").is_err()

linux_tool : Spec.Program
linux_tool = { name: "tool", system: "x86_64-linux", urls: ["https://example.test/tool-linux", "https://mirror.example.test/tool-linux"], unpack: File, path: "" }

# A digest hashed here and reported by the release is recorded as both; either
# alone is recorded as what it is, with the program's own URLs.
expect {
	own = { sha256: "aa", size: 3 }
	Lock.record(linux_tool, Ok(own), Ok(own)) == Ok({ name: "tool", system: "x86_64-linux", urls: linux_tool.urls, sha256: "aa", size: 3, obtained: Both })
		and Lock.record(linux_tool, Ok(own), Err(NotPublished)).map_ok(|entry| entry.obtained) == Ok(Computed)
		and Lock.record(linux_tool, Err(NotDownloaded), Ok(own)).map_ok(|entry| (entry.sha256, entry.size, entry.obtained)) == Ok(("aa", 3, Published))
}

# Two digests that differ, or two lengths, record nothing and say both.
expect Lock.record(linux_tool, Ok({ sha256: "aa", size: 3 }), Ok({ sha256: "bb", size: 3 })) == Err("tool for x86_64-linux: the download has SHA-256 aa and 3 bytes, and its release publishes bb and 3 bytes; nothing was recorded. One of the two is not what was released: do not use this download until you know which")
expect Lock.record(linux_tool, Ok({ sha256: "aa", size: 3 }), Ok({ sha256: "aa", size: 4 })).is_err()
expect Lock.record(linux_tool, Err(NotDownloaded), Err(NotPublished)).is_err()

# A full update keeps what is unchanged and obtains what is new or declared
# with other URLs; an entry of a program no longer declared is dropped.
expect {
	macos_tool = { ..linux_tool, system: "aarch64-darwin", urls: ["https://example.test/tool-macos"] }
	other = { ..linux_tool, name: "other", urls: ["https://example.test/other"] }
	kept = { name: "tool", system: "x86_64-linux", urls: linux_tool.urls, sha256: "aa", size: 3, obtained: Both }
	moved = { name: "tool", system: "aarch64-darwin", urls: ["https://example.test/older"], sha256: "bb", size: 4, obtained: Published }
	gone = { name: "gone", system: "x86_64-linux", urls: ["https://example.test/gone"], sha256: "cc", size: 5, obtained: Computed }
	held = [gone, moved, kept]
	Lock.refresh([linux_tool, macos_tool, other], held, All) == [Keep(kept), Obtain(macos_tool), Obtain(other)]
		# A named program is obtained again on every System, changed or not; the
		# others keep what they have, stale or not, and a new one waits.
		and Lock.refresh([linux_tool, macos_tool, other], held, Named(["tool"])) == [Obtain(linux_tool), Obtain(macos_tool)]
		and Lock.refresh([linux_tool, macos_tool, other], held, Named(["other"])) == [Keep(kept), Keep(moved), Obtain(other)]
		# Naming no program keeps every entry of a declared program.
		and Lock.refresh([linux_tool, macos_tool, other], held, Named([])) == [Keep(kept), Keep(moved)]
		and Lock.refresh([linux_tool], [], All) == [Obtain(linux_tool)]
}

# The hosts a lock's downloads name, alternates included, without ports; the
# new ones are those the lock before did not name.
expect Lock.host("https://github.com/roc-lang/nightlies/releases/download/x/roc.tar.gz") == "github.com" and Lock.host("http://127.0.0.1:4000/tool") == "127.0.0.1" and Lock.host("tool") == ""
expect {
	entry = |urls| { name: "tool", system: "x86_64-linux", urls, sha256: "aa", size: 3, obtained: Computed }
	before = [entry(["https://example.test/a"])]
	after = [entry(["https://example.test/b", "https://mirror.example.net/b"]), entry(["https://github.com/o/r/releases/download/1/t", "https://mirror.example.net/t"])]
	Lock.hosts(after) == ["example.test", "mirror.example.net", "github.com"]
		and Lock.new_hosts(before, after) == ["mirror.example.net", "github.com"]
		and Lock.new_hosts([], after) == ["example.test", "mirror.example.net", "github.com"]
		and Lock.new_hosts(after, after) == []
		and Lock.new_hosts(after, before) == []
}

expect {
	file = { name: "upstream", url: "https://example.test/release.tar.gz", sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
	spec = { ..Spec.empty("file-sources"), source_files: [file] }
	lock = { ..sample, intent: Lock.intent_of(spec), sources: [Lock.file_pin(file)], hints: [], fetched: [] }
	Lock.parse(lock.to_str()) == Ok(lock) and lock.stale(spec) == Ok({})
		and lock.stale({ ..spec, tasks: [{ name: "check", environment: "dev", run: ["check"] }] }) == Ok({})
		and lock.stale({ ..spec, source_files: [{ ..file, sha256: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" }] }).is_err()
		and lock.stale({ ..spec, source_files: [{ ..file, url: "https://mirror.test/release.tar.gz" }] }).is_err()
		and lock.stale({ ..spec, source_files: [] }).is_err()
		and { ..lock, sources: [] }.stale(spec).is_err()
}

# Updating one original-file pin must not resolve unrelated provider inputs or
# authorize changing another file. Native intent still has to match exactly.
expect {
	first = { name: "first", url: "https://example.test/first", sha256: "a".repeat(64) }
	second = { name: "second", url: "https://example.test/second", sha256: "b".repeat(64) }
	before = { ..Spec.empty("files"), requires_: ["source-files"], source_files: [first] }
	lock = Lock.{ format: Lock.current_format, intent: Lock.intent_of(before), sources: [Lock.file_pin(first)], hints: [], fetched: [] }
	after = { ..before, source_files: [first, second] }
	Lock.stale_except_files(lock, after, ["second"]) == Ok({})
		and Lock.stale(lock, after).is_err()
		and Lock.stale_except_files(lock, { ..after, source_files: [{ ..first, sha256: "c".repeat(64) }, second] }, ["second"]).is_err()
		and Lock.stale_except_files(lock, { ..after, inputs: [{ name: "unexpected", url: "github:example/input", kind: Flake }] }, ["second"]).is_err()
		and lock.sources == [Lock.file_pin(first)]
}
