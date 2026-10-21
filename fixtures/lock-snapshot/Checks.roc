## Pure consumer examples; imported unchanged by the release-bundle smoke test.
import core.LockSnapshot
import core.JsonData

Checks := [].{
	pin_matches : LockSnapshot, Str, Str, Str -> Bool
	pin_matches = |snapshot, name, system, expected| LockSnapshot.fetched_program(snapshot, name, system).map_ok(|entry| entry.sha256 == expected) ?? False

	same_source : LockSnapshot, LockSnapshot, Str -> Try(Bool, [MissingSource(Str)])
	same_source = |before, after, name| {
		left = LockSnapshot.source(before, name)?
		right = LockSnapshot.source(after, name)?
		Ok(LockSnapshot.source_identity(left) == LockSnapshot.source_identity(right))
	}

	## Explicitly Nix-aware client code; returns inert data and performs no fetch.
	fetch_attributes : LockSnapshot, Str -> Try(JsonData, Str)
	fetch_attributes = |snapshot, name| {
		entry = LockSnapshot.source(snapshot, name).map_err(|_| "missing selected source")?
		if entry.provider != "nix" {
			return Err("selected source is not Nix")
		}
		native = JsonData.field(entry.metadata, "nix").map_err(|_| "missing Nix metadata")?
		JsonData.field(native, "fetchTree").map_err(|_| "no portable fetchTree attributes")
	}

	example : LockSnapshot
	example = LockSnapshot.{
		sources: [
			{
				name: "nix",
				provider: "nix",
				ref: "github:example/packages",
				rev: "abc",
				digest: "opaque-tree",
				identity: "opaque-content",
				digest_kind: Tree,
				flat_sha256: Absent,
				metadata: JsonData.Object([
					{
						name: "nix",
						value: JsonData.Object([
							{ name: "fetchTree", value: JsonData.Object([{ name: "type", value: JsonData.String("git") }, { name: "url", value: JsonData.String("https://example.test/packages.git") }, { name: "rev", value: JsonData.String("abc") }]) },
							{ name: "future", value: JsonData.Array([JsonData.Null, JsonData.Number("340282366920938463463374607431768211455"), JsonData.Number("-1.2300e+99999")]) },
						]),
					},
				]),
			},
		],
		fetched: [{ name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/roc.tar.gz"], sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", identity: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", size: 18446744073709551615, obtained: "published" }],
	}

}

expect Checks.pin_matches(Checks.example, "roc-stable", "x86_64-linux", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
expect !Checks.pin_matches(Checks.example, "roc-stable", "aarch64-darwin", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
expect Checks.same_source(Checks.example, Checks.example, "nix") == Ok(True)
expect {
	other = { ..Checks.example, sources: Checks.example.sources.map(|entry| { ..entry, provider: "other" }) }
	Checks.same_source(Checks.example, other, "nix") == Ok(False)
}
expect Checks.fetch_attributes(Checks.example, "nix").is_ok()
