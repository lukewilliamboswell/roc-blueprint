## The stable, provider-independent inspector over committed authority.
import core.Lock
import core.Provider
import core.Value
import ReportJson

LockReport := [].{
	format : U64
	format = 1

	## Unknown names fail before output. Each provider sees only authority,
	## never a project Spec, machine context, filesystem or process API.
	render : Lock, List(Str), Bool, List(Provider) -> Try(Str, Str)
	render = |lock, names, json, providers| {
		for name in names {
			if !lock.sources.any(|source| source.name == name) and !lock.fetched.any(|entry| entry.name == name) {
				return Err("unknown locked entry: ${name}")
			}
		}
		var $pins = []
		for provider in providers {
			if lock.sources.any(|source| source.provider == provider.name) {
				for entry in (provider.inspect_lock)(lock)? {
					if !lock.sources.any(|source| source.name == entry.name and source.provider == provider.name) {
						return Err("provider ${provider.name} projected an unowned source: ${entry.name}")
					}
					if $pins.any(|known| known.name == entry.name) {
						return Err("duplicate projected source: ${entry.name}")
					}
					$pins = $pins.append(entry)
				}
			}
		}
		var $sources = []
		var $seen = []
		var $lines = []
		for source in lock.sources {
			if names.is_empty() or names.contains(source.name) {
				if $seen.contains(source.name) {
					return Err("duplicate locked source: ${source.name}")
				}
				$seen = $seen.append(source.name)
				pin = $pins.find_first(|entry| entry.name == source.name)
				identity = pin.map_ok(|entry| entry.identity) ?? source.digest
				if identity.is_empty() {
					return Err("locked source ${source.name} has no content identity")
				}
				metadata = match pin {
					Ok(entry) => ReportJson.object([(source.provider, ReportJson.value(Value.Attrs(entry.metadata))?)])
					Err(_) => "{}"
				}
				digest_kind = if source.provider == "file" {
					"file"
				} else {
					match pin.map_ok(|entry| entry.digest_kind) ?? Unknown {
						File => "file"
						Tree => "tree"
						Unknown => "unknown"
					}
				}
				$lines = $lines.append("source ${source.name} [${source.provider}] ${source.rev} ${identity}")
				fields = [
					("name", Json.to_str(source.name)),
					("provider", Json.to_str(source.provider)),
					("ref", Json.to_str(source.ref)),
					("rev", Json.to_str(source.rev)),
					("digest", Json.to_str(source.digest)),
					("digestKind", Json.to_str(digest_kind)),
					(
						"flatSha256",
						if source.provider == "file" {
							Json.to_str(source.digest.drop_prefix("sha256:"))
						} else {
							"null"
						},
					),
					("identity", Json.to_str(identity)),
					("metadata", metadata),
				]
				$sources = $sources.append((source.name, ReportJson.object(fields)))
			}
		}
		var $fetched = []
		for entry in lock.fetched {
			if names.is_empty() or names.contains(entry.name) {
				obtained = match entry.obtained {
					Computed => "computed"
					Published => "published"
					Both => "both"
					Unstated => "unstated"
				}
				$lines = $lines.append("program ${entry.name} [${entry.system}] sha256:${entry.sha256}")
				$fetched = $fetched.append(
					ReportJson.object([
						("name", Json.to_str(entry.name)),
						("system", Json.to_str(entry.system)),
						("urls", Json.to_str(entry.urls)),
						("sha256", Json.to_str(entry.sha256)),
						("identity", Json.to_str("sha256:${entry.sha256}")),
						("size", entry.size.to_str()),
						("obtained", Json.to_str(obtained)),
					]),
				)
			}
		}
		Ok(
			if json {
				ReportJson.object([
					("format", format.to_str()),
					("sources", ReportJson.object($sources)),
					("fetched", "[${Str.join_with($fetched, ",")}]"),
				]).concat("\n")
			} else {
				Str.join_with($lines, "\n").concat("\n")
			},
		)
	}
}

# Fetched entries round-trip the caller-facing names, escaping and provenance,
# with every system selected by one program name, including old unstated pins.
expect {
	entry = { name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/a?quote=\"&slash=\\"], sha256: "abcd", size: 4, obtained: Published }
	lock = Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [], hints: [], fetched: [entry, { ..entry, system: "aarch64-darwin", obtained: Unstated }] }
	match LockReport.render(lock, ["roc-stable"], True, []) {
		Ok(text) => {
			decoded : Try({ format : U64, fetched : List({ name : Str, system : Str, urls : List(Str), sha256 : Str, identity : Str, size : U64, obtained : Str }) }, _)
			decoded = Json.parse(text)
			match decoded {
				Ok(read) => read.format == 1 and read.fetched.map(|item| (item.system, item.obtained)) == [("x86_64-linux", "published"), ("aarch64-darwin", "unstated")] and read.fetched.all(|item| item.urls == entry.urls and item.name == entry.name and item.identity == "sha256:abcd" and item.sha256 == "abcd" and item.size == 4)
				Err(_) => False
			}
		}
		Err(_) => False
	}
}

expect {
	lock = Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [{ name: "missing", provider: "other", ref: "source", rev: "", digest: "" }], hints: [], fetched: [] }
	LockReport.render(lock, [], True, []) == Err("locked source missing has no content identity")
}
