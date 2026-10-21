## CLI presentation over the official pure operational report protocol.
import core.Lock
import core.Provider
import core.LockSnapshot

LockReport := [].{
	format : U64
	format = LockSnapshot.format

	render : Lock, List(Str), Bool, List(Provider) -> Try(Str, Str)
	render = |lock, names, json, providers| {
		snapshot = LockSnapshot.project(lock, names, providers).map_err(LockSnapshot.describe)?
		if json {
			return LockSnapshot.to_json(snapshot).map_err(LockSnapshot.describe)
		}
		lines = snapshot.sources.map(|entry| "source ${entry.name} [${entry.provider}] ${entry.rev} ${entry.identity}")
			.concat(snapshot.fetched.map(|entry| "program ${entry.name} [${entry.system}] ${entry.identity}"))
		Ok(Str.join_with(lines, "\n").concat("\n"))
	}
}

# Fetched entries round-trip the caller-facing names, escaping and provenance,
# with every system selected by one program name, including old unstated pins.
expect {
	entry = { name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/a?quote=\"&slash=\\"], sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", size: 4, obtained: Published }
	lock = Lock.{ format: Lock.current_format, intent: Lock.empty_intent, sources: [], hints: [], fetched: [entry, { ..entry, system: "aarch64-darwin", obtained: Unstated }] }
	match LockReport.render(lock, ["roc-stable"], True, []) {
		Ok(text) => {
			decoded : Try({ format : U64, fetched : List({ name : Str, system : Str, urls : List(Str), sha256 : Str, identity : Str, size : U64, obtained : Str }) }, _)
			decoded = Json.parse(text)
			match decoded {
				Ok(read) => read.format == 1 and read.fetched.map(|item| (item.system, item.obtained)) == [("x86_64-linux", "published"), ("aarch64-darwin", "unstated")] and read.fetched.all(|item| item.urls == entry.urls and item.name == entry.name and item.identity == "sha256:${entry.sha256}" and item.sha256 == entry.sha256 and item.size == 4)
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
