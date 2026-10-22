# Generate well-formed lock snapshots, including arbitrary provider metadata.
app [target] {
	core: "../../main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
import core.JsonData
import core.LockSnapshot

## Every snapshot the generator builds is well formed, so `to_json` must
## accept it, `parse_json` must give it back unchanged, and each entry must be
## found by its name.
test : LockSnapshot -> Fuzz.Outcome
test = |snapshot|
	match LockSnapshot.to_json(snapshot) {
		Ok(report) => {
			if LockSnapshot.parse_json(report) != Ok(snapshot) {
				crash "snapshot round trip changed the value"
			}
			for entry in snapshot.sources {
				if LockSnapshot.source(snapshot, entry.name) != Ok(entry) {
					crash "source lookup did not find ${entry.name}"
				}
			}
			for entry in snapshot.fetched {
				if LockSnapshot.fetched_program(snapshot, entry.name, entry.system) != Ok(entry) {
					crash "program lookup did not find ${entry.name}/${entry.system}"
				}
			}
			Fuzz.keep
		}
		Err(error) => crash "well-formed snapshot was refused: ${LockSnapshot.describe(error)}"
	}

## The first of the items with each key.
unique_by : List(a), (a -> k) -> List(a) where [k.is_eq : k, k -> Bool]
unique_by = |items, key| items.fold([], |kept, item| if (kept.any(|other| key(other) == key(item))) kept else kept.append(item))

## A string that is not empty or all whitespace.
nonblank : Str -> Str
nonblank = |text| if (text.trim().is_empty()) "x${text}" else text

## Lowercase hex of exactly 32 bytes, padding with zeros.
hex_of : List(U8) -> Str
hex_of = |bytes| {
	digits = "0123456789abcdef".to_utf8()
	var $out = []
	var $i = 0
	while $i < 32 {
		byte = bytes.get($i) ?? 0
		$out = $out.append(digits.get(byte.to_u64() // 16) ?? '0').append(digits.get(byte.to_u64() % 16) ?? '0')
		$i = $i + 1
	}
	Str.from_utf8($out) ?? ""
}

## A valid JSON number lexeme: sign, integer, fraction and exponent forms.
number : Fuzz.Generator(Str)
number = Fuzz.map(
	{ negative: Fuzz.u8_in(0, 1), whole: Fuzz.u64, fraction: Fuzz.u8_in(0, 2), digits: Fuzz.u64, exponent: Fuzz.u8_in(0, 4), power: Fuzz.u64 }.Fuzz,
	|r| {
		sign = if (r.negative == 1) "-" else ""
		# Past U64: append digits to a whole part that has no leading zero.
		whole = if (r.fraction == 2 and r.whole != 0) "${r.whole.to_str()}${r.digits.to_str()}" else r.whole.to_str()
		fraction = if (r.fraction == 1) ".${r.digits.to_str()}" else ""
		exponent = match r.exponent {
			0 => ""
			1 => "e${r.power.to_str()}"
			2 => "E+${r.power.to_str()}"
			3 => "e-${r.power.to_str()}"
			_ => "E0"
		}
		"${sign}${whole}${fraction}${exponent}"
	},
)

## A JSON value nested at most `depth` levels deep, with unique object keys.
json : U64 -> Fuzz.Generator(JsonData)
json = |depth| |state| {
	choice = Fuzz.u8_in(0, if (depth == 0) 2 else 4)(state)
	match choice.value {
		0 => Fuzz.map(Fuzz.str, |s| JsonData.String(s))(choice.state)
		1 => Fuzz.map(number, |n| JsonData.Number(n))(choice.state)
		2 => Fuzz.map(
			Fuzz.u8_in(0, 2),
			|b|
				match b {
					0 => JsonData.Null
					_ => JsonData.Boolean(b == 1)
				},
		)(choice.state)
		3 => Fuzz.map(Fuzz.list(json(depth - 1), 3), |items| JsonData.Array(items))(choice.state)
		_ => Fuzz.map(
			Fuzz.list({ name: Fuzz.str, value: json(depth - 1) }.Fuzz, 3),
			|fields| JsonData.Object(unique_by(fields, |field| field.name)),
		)(choice.state)
	}
}

## Provider metadata: an object of namespace objects.
metadata : Fuzz.Generator(JsonData)
metadata = Fuzz.map(
	Fuzz.list({ name: Fuzz.str, fields: Fuzz.list({ name: Fuzz.str, value: json(3) }.Fuzz, 3) }.Fuzz, 2),
	|namespaces| JsonData.Object(unique_by(namespaces, |namespace| namespace.name).map(|namespace| { name: namespace.name, value: JsonData.Object(unique_by(namespace.fields, |field| field.name)) })),
)

## A core file source half the time, otherwise any other provider's source.
source : Fuzz.Generator(LockSnapshot.Source)
source = Fuzz.map(
	{ file: Fuzz.u8_in(0, 1), kind: Fuzz.u8_in(0, 2), name: Fuzz.str, provider: Fuzz.str, ref: Fuzz.str, rev: Fuzz.str, digest: Fuzz.str, content_identity: Fuzz.str, unknown: Fuzz.str, hash: Fuzz.list(Fuzz.u8, 32), metadata }.Fuzz,
	|r| {
		name = nonblank(r.name)
		if r.file == 0 {
			hash = hex_of(r.hash)
			{ name, provider: "file", ref: r.ref, rev: "", digest: "sha256:${hash}", content_identity: "sha256:${hash}", digest_kind: File, flat_sha256: Present(hash), metadata: r.metadata }
		} else {
			provider = if (r.provider == "file") "files" else nonblank(r.provider)
			# "file" and "tree" parse as the known kinds, so an Unknown names neither.
			unknown = if (r.unknown == "file" or r.unknown == "tree") "${r.unknown}s" else nonblank(r.unknown)
			digest_kind = match r.kind {
				0 => File
				1 => Tree
				_ => Unknown(unknown)
			}
			{ name, provider, ref: r.ref, rev: r.rev, digest: r.digest, content_identity: nonblank(r.content_identity), digest_kind, flat_sha256: Absent, metadata: r.metadata }
		}
	},
)

fetched : Fuzz.Generator(LockSnapshot.Fetched)
fetched = Fuzz.map(
	{ name: Fuzz.str, system: Fuzz.str, url: Fuzz.str, urls: Fuzz.list(Fuzz.str, 3), hash: Fuzz.list(Fuzz.u8, 32), size: Fuzz.u64, obtained: Fuzz.str }.Fuzz,
	|r| {
		hash = hex_of(r.hash)
		urls = [r.url].concat(r.urls).map(|url| if (url.is_empty()) "u" else url)
		{ name: nonblank(r.name), system: nonblank(r.system), urls, sha256: hash, content_identity: "sha256:${hash}", size: r.size, obtained: nonblank(r.obtained), served: [], witness: "" }
	},
)

snapshot_generator : Fuzz.Generator(LockSnapshot)
snapshot_generator = Fuzz.map(
	{ sources: Fuzz.list(source, 4), fetched: Fuzz.list(fetched, 4) }.Fuzz,
	|r| LockSnapshot.{
		sources: unique_by(r.sources, |entry| entry.name),
		fetched: unique_by(r.fetched, |entry| { name: entry.name, system: entry.system }),
	},
)

target = Fuzz.target_with({
	name: "lock-snapshot-round-trip",
	generator: snapshot_generator,
	test,
	show: |snapshot| LockSnapshot.to_json(snapshot) ?? Str.inspect(snapshot.sources.map(|entry| entry.name)),
})
