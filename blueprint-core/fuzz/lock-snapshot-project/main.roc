# Project generated Locks through a provider's pins into lock snapshots.
app [target] {
	core: "../../main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
import core.Lock
import core.LockSnapshot
import core.Provider
import core.Spec
import core.Value

## A well-formed Lock, the pins one provider reports for its sources, the
## names asked for, and at most one fault that `project` must refuse.
Case : { lock : Lock, pins : List(Provider.LockedSource), names : List(Str), fault : [None, UnknownName, UnownedPin, DuplicatePin] }

## With no fault, `project` must keep exactly the entries asked for, take a
## pinned source's content_identity from its pin and an unpinned one's from its digest,
## and give a snapshot that survives `to_json` then `parse_json`. With a fault,
## it must refuse.
test : Case -> Fuzz.Outcome
test = |case|
	match (LockSnapshot.project(case.lock, case.names, [provider(case.pins)]), case.fault) {
		(Ok(snapshot), None) => {
			wanted = |name| case.names.is_empty() or case.names.contains(name)
			if snapshot.sources.map(|entry| entry.name) != case.lock.sources.map(|entry| entry.name).keep_if(wanted) {
				crash "projected sources are not the ones asked for"
			}
			if snapshot.fetched.map(|entry| { name: entry.name, system: entry.system }) != case.lock.fetched.keep_if(|entry| wanted(entry.name)).map(|entry| { name: entry.name, system: entry.system }) {
				crash "projected programs are not the ones asked for"
			}
			for entry in snapshot.sources {
				locked = case.lock.sources.find_first(|candidate| candidate.name == entry.name) ?? { name: "", provider: "", ref: "", rev: "", digest: "" }
				if entry.provider != locked.provider or entry.ref != locked.ref or entry.rev != locked.rev or entry.digest != locked.digest {
					crash "projected source ${entry.name} does not match its Lock entry"
				}
				expected = case.pins.find_first(|pin| pin.name == entry.name).map_ok(|pin| pin.content_identity) ?? locked.digest
				if entry.content_identity != expected {
					crash "projected source ${entry.name} has the wrong content_identity"
				}
			}
			match LockSnapshot.to_json(snapshot) {
				Ok(report) => if LockSnapshot.parse_json(report) != Ok(snapshot) {
					crash "projected snapshot did not survive a round trip"
				}
				Err(error) => crash "projected snapshot was refused: ${LockSnapshot.describe(error)}"
			}
			Fuzz.keep
		}
		(Err(error), None) => crash "well-formed Lock was refused: ${LockSnapshot.describe(error)}"
		(Ok(_), _) => crash "projection accepted a fault"
		(Err(_), _) => Fuzz.keep
	}

## A pure provider named "guix" whose Lock inspection reports `pins`.
provider : List(Provider.LockedSource) -> Provider
provider = |pins| Provider.{
	validate_source: |_source| Ok({}),
	validate_tool: |_name| Ok({}),
	name: "guix",
	features: [],
	realises: |_source| False,
	render: |_spec| Ok([]),
	inspect_lock: |_lock| Ok(pins),
	preflight: |_spec, _request, _system, _layout| Ok({}),
	realise: |_spec, _request, _system, _layout, _lock| Err(Unrealisable("not realised here")),
	build_argv: |step, _options| Ok(step.argv),
	build_result: |_text| Err("not built here"),
	build_sources: |_spec, _name| Ok([]),
	resolve: |_spec, _system, _layout, _update| Err("not resolved here"),
	lock_from_native: |_spec, _layout, _text, _trees| Err("not resolved here"),
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

## Provider metadata nested at most `depth` levels deep, with unique names.
value : U64 -> Fuzz.Generator(Value)
value = |depth| |state| {
	choice = Fuzz.u8_in(0, if (depth == 0) 2 else 4)(state)
	match choice.value {
		0 => Fuzz.map(Fuzz.str, |s| Value.Str(s))(choice.state)
		1 => Fuzz.map(Fuzz.u64, |n| Value.Int(U64.to_i64_wrap(n)))(choice.state)
		2 => Fuzz.map(Fuzz.u8_in(0, 1), |b| Value.Bool(b == 1))(choice.state)
		3 => Fuzz.map(Fuzz.list(value(depth - 1), 3), |items| Value.List(items))(choice.state)
		_ => Fuzz.map(
			Fuzz.list({ name: Fuzz.str, value: value(depth - 1) }.Fuzz, 3),
			|attrs| Value.Attrs(unique_by(attrs, |attr| attr.name)),
		)(choice.state)
	}
}

## A Lock source and, when its provider is "guix" and it is pinned, its pin.
Entry : { source : Lock.Source, pin : Try(Provider.LockedSource, [Unpinned]) }

entry : Fuzz.Generator(Entry)
entry = Fuzz.map(
	{ provider: Fuzz.u8_in(0, 2), name: Fuzz.str, other: Fuzz.str, ref: Fuzz.str, rev: Fuzz.str, digest: Fuzz.str, hash: Fuzz.list(Fuzz.u8, 32), pinned: Fuzz.u8_in(0, 2), content_identity: Fuzz.str, kind: Fuzz.u8_in(0, 2), metadata: Fuzz.list({ name: Fuzz.str, value: value(3) }.Fuzz, 3) }.Fuzz,
	|r| {
		name = nonblank(r.name)
		match r.provider {
			0 => { source: { name, provider: "file", ref: r.ref, rev: "", digest: "sha256:${hex_of(r.hash)}" }, pin: Err(Unpinned) }
			1 => {
				source = { name, provider: "guix", ref: r.ref, rev: r.rev, digest: r.digest }
				if r.pinned == 0 and !r.digest.trim().is_empty() {
					{ source, pin: Err(Unpinned) }
				} else {
					digest_kind = match r.kind {
						0 => File
						1 => Tree
						_ => Unknown
					}
					{ source, pin: Ok({ name, content_identity: nonblank(r.content_identity), digest_kind, metadata: unique_by(r.metadata, |attr| attr.name) }) }
				}
			}
			_ => {
				# An adapter that is not loaded: its sources project their digests.
				provider_name = if (r.other == "file" or r.other == "guix") "${r.other}-other" else nonblank(r.other)
				{ source: { name, provider: provider_name, ref: r.ref, rev: r.rev, digest: nonblank(r.digest) }, pin: Err(Unpinned) }
			}
		}
	},
)

fetched : Fuzz.Generator(Lock.Fetched)
fetched = Fuzz.map(
	{ name: Fuzz.str, system: Fuzz.str, url: Fuzz.str, urls: Fuzz.list(Fuzz.str, 3), hash: Fuzz.list(Fuzz.u8, 32), size: Fuzz.u64, obtained: Fuzz.u8_in(0, 3) }.Fuzz,
	|r| {
		urls = [r.url].concat(r.urls).map(|url| if (url.is_empty()) "u" else url)
		obtained = match r.obtained {
			0 => Computed
			1 => Published
			2 => Both
			_ => Unstated
		}
		{ name: nonblank(r.name), system: nonblank(r.system), urls, sha256: hex_of(r.hash), size: r.size, obtained }
	},
)

case_generator : Fuzz.Generator(Case)
case_generator = Fuzz.map(
	{ entries: Fuzz.list(entry, 5), fetched: Fuzz.list(fetched, 3), select: Fuzz.list(Fuzz.u8, 3), fault: Fuzz.u8_in(0, 6) }.Fuzz,
	|r| {
		entries = unique_by(r.entries, |item| item.source.name)
		sources = entries.map(|item| item.source)
		programs = unique_by(r.fetched, |item| { name: item.name, system: item.system })
		pins = entries.keep_oks(|item| item.pin)
		known = sources.map(|item| item.name).concat(programs.map(|item| item.name))
		# Each index picks a known name; none picks every entry.
		names = unique_by(r.select.keep_oks(|index| known.get(index.to_u64() % U64.max(known.len(), 1))), |name| name)
		# Longer than every known name, so no entry has it.
		stranger = "${Str.join_with(known, "")}?"
		lock = Lock.{ format: Lock.current_format, intent: Lock.intent_of(Spec.empty("fuzz")), sources, hints: [], fetched: programs }
		# A provider's pins are read only when the Lock has a source of its own.
		owns = sources.any(|item| item.provider == "guix")
		match (r.fault, pins.first()) {
			(4, _) => { lock, pins, names: names.append(stranger), fault: UnknownName }
			(5, _) if owns => { lock, pins: pins.append({ name: stranger, content_identity: "guix:unowned", digest_kind: Unknown, metadata: [] }), names, fault: UnownedPin }
			(6, Ok(pin)) => { lock, pins: pins.append(pin), names, fault: DuplicatePin }
			_ => { lock, pins, names, fault: None }
		}
	},
)

target = Fuzz.target_with({
	name: "lock-snapshot-project",
	generator: case_generator,
	test,
	show: |case| "${Str.inspect(case.lock.sources)}\npins: ${Str.inspect(case.pins.map(|pin| { name: pin.name, content_identity: pin.content_identity }))}\nnames: ${Str.inspect(case.names)}\nfault: ${Str.inspect(case.fault)}",
})
