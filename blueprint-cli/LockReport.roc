## The stable, provider-independent inspector over committed authority.
import core.Lock
import core.Provider
import core.Value

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
				$pins = $pins.concat((provider.inspect_lock)(lock)?)
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
				fetch = match pin {
					Ok(entry) => entry.metadata.find_first(|field| field.name == "fetchTree").map_ok(|field| value_json(field.value)) ?? "null"
					Err(_) => "null"
				}
				$lines = $lines.append("source ${source.name} [${source.provider}] ${source.rev} ${identity}")
				fields = [
					("name", Json.to_str(source.name)),
					("provider", Json.to_str(source.provider)),
					("ref", Json.to_str(source.ref)),
					("rev", Json.to_str(source.rev)),
					("digest", Json.to_str(source.digest)),
					("identity", Json.to_str(identity)),
					("fetchTree", fetch),
				]
				$sources = $sources.append((source.name, object(fields)))
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
					object([
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
				object([
					("format", format.to_str()),
					("sources", object($sources)),
					("fetched", "[${Str.join_with($fetched, ",")}]"),
				]).concat("\n")
			} else {
				Str.join_with($lines, "\n").concat("\n")
			},
		)
	}
}

object : List((Str, Str)) -> Str
object = |fields| "{${Str.join_with(fields.map(|(name, value)| "${Json.to_str(name)}:${value}"), ",")}}"

value_json : Value -> Str
value_json = |value| match value {
	Str(text) => Json.to_str(text)
	Int(number) => number.to_str()
	Bool(boolean) => if (boolean) "true" else "false"
	List(items) => "[${Str.join_with(items.map(value_json), ",")}]"
	Attrs(fields) => object(fields.map(|field| (field.name, value_json(field.value))))
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
