## Version-2 operational inspection data. Never authoritative Lock state.
## No filesystem, process, Store, freshness check or provider-native execution.
import Lock
import Provider
import Value
import JsonData

LockSnapshot := { sources : List(Source), fetched : List(Fetched) }.{
	is_eq : _

	Source : { name : Str, provider : Str, ref : Str, rev : Str, digest : Str, content_identity : Str, digest_kind : [File, Tree, Unknown(Str)], flat_sha256 : [Absent, Present(Str)], metadata : JsonData }
	Fetched : { name : Str, system : Str, urls : List(Str), sha256 : Str, content_identity : Str, size : U64, obtained : Str }
	ContentIdentity : { provider : Str, value : Str }
	Error : [InvalidJson(Str), LimitExceeded(Str), UnsupportedFormat(U64), InvalidReport(Str)]
	format : U64
	format = 2

	source : LockSnapshot, Str -> Try(Source, [MissingSource(Str)])
	source = |snapshot, name| snapshot.sources.find_first(|entry| entry.name == name).map_err(|_| MissingSource(name))

	fetched_program : LockSnapshot, Str, Str -> Try(Fetched, [MissingProgram({ name : Str, system : Str })])
	fetched_program = |snapshot, name, system| snapshot.fetched.find_first(|entry| entry.name == name and entry.system == system).map_err(|_| MissingProgram({ name, system }))

	source_content_identity : Source -> ContentIdentity
	source_content_identity = |entry| { provider: entry.provider, value: entry.content_identity }

	## Caller-supplied serialized data only. Validate the format before its fields.
	parse_json : Str -> Try(LockSnapshot, Error)
	parse_json = |text| {
		data = JsonData.decode(text)?
		version = unsigned(data, "format")?
		if version != format {
			return Err(UnsupportedFormat(version))
		}
		var $sources = []
		for field in JsonData.object(required(data, "sources")?).map_err(|_| InvalidReport("sources must be an object"))? {
			entry = field.value
			name = string(entry, "name")?
			if name != field.name {
				return Err(InvalidReport("source object key does not match name: ${field.name}"))
			}
			provider = string(entry, "provider")?
			content_identity = string(entry, "content_identity")?
			if name.trim().is_empty() or provider.trim().is_empty() or content_identity.trim().is_empty() {
				return Err(InvalidReport("source name, provider and content_identity must be nonempty"))
			}
			kind = string(entry, "digestKind")?
			if kind.trim().is_empty() {
				return Err(InvalidReport("digestKind must be nonempty"))
			}
			digest = string(entry, "digest")?
			flat = match required(entry, "flatSha256")? {
				Null => Absent
				String(hash) => {
					if !hex(hash) {
						return Err(InvalidReport("flatSha256 must be lowercase SHA-256"))
					}
					Present(hash)
				}
				_ => return Err(InvalidReport("flatSha256 must be null or a SHA-256 string"))
			}
			if provider == "file" {
				if string(entry, "rev")? != "" {
					return Err(InvalidReport("core file revision must be empty"))
				}
				match flat {
					Present(hash) => if kind != "file" or content_identity != "sha256:${hash}" or digest != content_identity {
						return Err(InvalidReport("core file content_identity/digest/flatSha256 disagree"))
					}
					Absent => return Err(InvalidReport("core file source requires flatSha256"))
				}
			} else if flat != Absent {
				return Err(InvalidReport("flatSha256 is reserved for core file sources"))
			}
			metadata = required(entry, "metadata")?
			_ = JsonData.object(metadata).map_err(|_| InvalidReport("source metadata must be an object"))?
			for namespace in JsonData.object(metadata).map_err(|_| InvalidReport("source metadata must be an object"))? {
				_ = JsonData.object(namespace.value).map_err(|_| InvalidReport("metadata namespaces must be objects"))?
			}
			$sources = $sources.append({ name, provider, ref: string(entry, "ref")?, rev: string(entry, "rev")?, digest, content_identity, digest_kind: when_kind(kind), flat_sha256: flat, metadata })
		}
		var $fetched = []
		for entry in JsonData.array(required(data, "fetched")?).map_err(|_| InvalidReport("fetched must be an array"))? {
			name = string(entry, "name")?
			system = string(entry, "system")?
			if name.trim().is_empty() or system.trim().is_empty() {
				return Err(InvalidReport("program name and system must be nonempty"))
			}
			if $fetched.any(|known| known.name == name and known.system == system) {
				return Err(InvalidReport("duplicate fetched program/system: ${name}/${system}"))
			}
			sha256 = string(entry, "sha256")?
			content_identity = string(entry, "content_identity")?
			if !hex(sha256) or content_identity != "sha256:${sha256}" {
				return Err(InvalidReport("program SHA-256 and content_identity disagree"))
			}
			var $urls = []
			for item in JsonData.array(required(entry, "urls")?).map_err(|_| InvalidReport("urls must be an array"))? {
				url = JsonData.string(item).map_err(|_| InvalidReport("URL must be a string"))?
				if url.is_empty() {
					return Err(InvalidReport("URL must be nonempty"))
				}
				$urls = $urls.append(url)
			}
			if $urls.is_empty() {
				return Err(InvalidReport("program URLs must be nonempty"))
			}
			if string(entry, "obtained")?.trim().is_empty() {
				return Err(InvalidReport("obtained must be nonempty"))
			}
			$fetched = $fetched.append({ name, system, urls: $urls, sha256, content_identity, size: unsigned(entry, "size")?, obtained: string(entry, "obtained")? })
		}
		Ok(LockSnapshot.{ sources: $sources, fetched: $fetched })
	}

	## Validate manually constructed values too; emit deterministic field order.
	## Unknown native JSON values retain null and exact numeric lexemes.
	to_json : LockSnapshot -> Try(Str, Error)
	to_json = |snapshot| {
		data = JsonData.Object([
			{ name: "format", value: JsonData.Number(format.to_str()) },
			{ name: "sources", value: JsonData.Object(snapshot.sources.map(|entry| { name: entry.name, value: source_data(entry) })) },
			{ name: "fetched", value: JsonData.Array(snapshot.fetched.map(fetched_data)) },
		])
		text = JsonData.encode(data)?
		validated = parse_json(text)?
		if validated != snapshot {
			return Err(InvalidReport("noncanonical constructed report"))
		}
		if text.to_utf8().len() >= 8388608 {
			return Err(LimitExceeded("lock report exceeds 8 MiB including newline"))
		}
		Ok(text.concat("\n"))
	}

	## Pure adapter contracts project committed hints; never execute providers.
	## Selected names affect output only, not validation of provider authority.
	project : Lock, List(Str), List(Provider) -> Try(LockSnapshot, Error)
	project = |lock, names, providers| {
		for name in names {
			if !lock.sources.any(|entry| entry.name == name) and !lock.fetched.any(|entry| entry.name == name) {
				return Err(InvalidReport("unknown locked entry: ${name}"))
			}
		}
		var $pins = []
		for provider in providers {
			if lock.sources.any(|entry| entry.provider == provider.name) {
				for entry in (provider.inspect_lock)(lock).map_err(|message| InvalidReport(message))? {
					if !lock.sources.any(|locked_source| locked_source.name == entry.name and locked_source.provider == provider.name) {
						return Err(InvalidReport("provider ${provider.name} projected an unowned source: ${entry.name}"))
					}
					if $pins.any(|known| known.name == entry.name) {
						return Err(InvalidReport("duplicate projected source: ${entry.name}"))
					}
					$pins = $pins.append(entry)
				}
			}
		}
		var $sources = []
		for locked_source in lock.sources {
			if names.is_empty() or names.contains(locked_source.name) {
				if $sources.any(|known| known.name == locked_source.name) {
					return Err(InvalidReport("duplicate locked source: ${locked_source.name}"))
				}
				pin = $pins.find_first(|entry| entry.name == locked_source.name)
				content_identity = pin.map_ok(|entry| entry.content_identity) ?? locked_source.digest
				if content_identity.is_empty() {
					return Err(InvalidReport("locked source ${locked_source.name} has no content content_identity"))
				}
				metadata = match pin {
					Ok(entry) => JsonData.Object([{ name: locked_source.provider, value: from_value(Value.Attrs(entry.metadata)) }])
					Err(_) => JsonData.Object([])
				}
				kind = if locked_source.provider == "file" {
					File
				} else {
					match pin.map_ok(|entry| entry.digest_kind) ?? Unknown {
						File => File
						Tree => Tree
						Unknown => Unknown("unknown")
					}
				}
				$sources = $sources.append({ name: locked_source.name, provider: locked_source.provider, ref: locked_source.ref, rev: locked_source.rev, digest: locked_source.digest, content_identity, digest_kind: kind, flat_sha256: if (locked_source.provider == "file") Present(locked_source.digest.drop_prefix("sha256:")) else Absent, metadata })
			}
		}
		fetched = lock.fetched.keep_if(|entry| names.is_empty() or names.contains(entry.name)).map(
			|entry| {
				name: entry.name,
				system: entry.system,
				urls: entry.urls,
				sha256: entry.sha256,
				content_identity: "sha256:${entry.sha256}",
				size: entry.size,
				obtained: match entry.obtained {
					Computed => "computed"
					Published => "published"
					Both => "both"
					Unstated => "unstated"
				},
			},
		)
		snapshot = LockSnapshot.{ sources: $sources, fetched }
		_ = to_json(snapshot)?
		Ok(snapshot)
	}

	describe : Error -> Str
	describe = |error| match error {
		InvalidJson(message) | LimitExceeded(message) | InvalidReport(message) => message
		UnsupportedFormat(version) => "unsupported lock report format: ${version.to_str()}"
	}
}

required = |data, name| JsonData.field(data, name).map_err(|_| InvalidReport("missing required report field: ${name}"))

string = |data, name| JsonData.string(required(data, name)?).map_err(|_| InvalidReport("${name} must be a string"))

unsigned = |data, name| match required(data, name)? {
	Number(text) => U64.from_str(text).map_err(|_| InvalidReport("${name} must be an unsigned 64-bit integer"))
	_ => Err(InvalidReport("${name} must be an unsigned 64-bit integer"))
}

hex = |text| text.to_utf8().len() == 64 and text.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))

when_kind = |kind| match kind {
	"file" => File
	"tree" => Tree
	_ => Unknown(kind)
}

kind_text = |kind| match kind {
	File => "file"
	Tree => "tree"
	Unknown(text) => text
}

from_value = |value| match value {
	Str(text) => JsonData.String(text)
	Int(number) => JsonData.Number(number.to_str())
	Bool(boolean) => JsonData.Boolean(boolean)
	List(items) => JsonData.Array(items.map(from_value))
	Attrs(fields) => JsonData.Object(fields.map(|field| { name: field.name, value: from_value(field.value) }))
}

source_data = |entry| JsonData.Object([
	{ name: "name", value: JsonData.String(entry.name) },
	{ name: "provider", value: JsonData.String(entry.provider) },
	{ name: "ref", value: JsonData.String(entry.ref) },
	{ name: "rev", value: JsonData.String(entry.rev) },
	{ name: "digest", value: JsonData.String(entry.digest) },
	{ name: "content_identity", value: JsonData.String(entry.content_identity) },
	{ name: "digestKind", value: JsonData.String(kind_text(entry.digest_kind)) },
	{
		name: "flatSha256",
		value: match entry.flat_sha256 {
			Absent => JsonData.Null
			Present(hash) => JsonData.String(hash)
		},
	},
	{ name: "metadata", value: entry.metadata },
])

fetched_data = |entry| JsonData.Object([
	{ name: "name", value: JsonData.String(entry.name) },
	{ name: "system", value: JsonData.String(entry.system) },
	{ name: "urls", value: JsonData.Array(entry.urls.map(|url| JsonData.String(url))) },
	{ name: "sha256", value: JsonData.String(entry.sha256) },
	{ name: "content_identity", value: JsonData.String(entry.content_identity) },
	{ name: "size", value: JsonData.Number(entry.size.to_str()) },
	{ name: "obtained", value: JsonData.String(entry.obtained) },
])

sample : LockSnapshot
sample = LockSnapshot.{
	sources: [
		{
			name: "channel",
			provider: "future",
			ref: "https://example.test/channel",
			rev: "abc",
			digest: "opaque-content",
			content_identity: "opaque-content_identity",
			digest_kind: Unknown("graph"),
			flat_sha256: Absent,
			metadata: JsonData.Object([
				{
					name: "future",
					value: JsonData.Object([
						{ name: "large", value: JsonData.Number("340282366920938463463374607431768211455") },
						{ name: "decimal", value: JsonData.Number("-1.2300e+99999") },
						{ name: "nothing", value: JsonData.Null },
						{ name: "nested", value: JsonData.Array([JsonData.Boolean(True), JsonData.String("λ\n\"\\😀")]) },
					]),
				},
			]),
		},
	],
	fetched: [{ name: "roc-stable", system: "x86_64-linux", urls: ["https://example.test/roc.tar.gz"], sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", content_identity: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", size: 18446744073709551615, obtained: "published" }],
}

sample_text : Str
sample_text = LockSnapshot.to_json(sample) ?? ""

expect LockSnapshot.parse_json(sample_text) == Ok(sample)
expect LockSnapshot.source(sample, "channel").map_ok(LockSnapshot.source_content_identity) == Ok({ provider: "future", value: "opaque-content_identity" })
expect LockSnapshot.source(sample, "missing") == Err(MissingSource("missing"))
expect LockSnapshot.fetched_program(sample, "roc-stable", "x86_64-linux").map_ok(|entry| entry.size) == Ok(18446744073709551615)
expect LockSnapshot.fetched_program(sample, "roc-stable", "aarch64-darwin") == Err(MissingProgram({ name: "roc-stable", system: "aarch64-darwin" }))
expect LockSnapshot.parse_json("{\"format\":3,\"sources\":false,\"fetched\":42}") == Err(UnsupportedFormat(3))
expect LockSnapshot.parse_json("{\"format\":2,\"sources\":{},\"fetched\":[],\"future\":{\"new\":[null,2.5]}}") == Ok(LockSnapshot.{ sources: [], fetched: [] })
expect LockSnapshot.parse_json("{\"format\":2,\"sources\":{},\"fetched\":[]}{ }").is_err()
expect LockSnapshot.parse_json("{\"format\":2,\"format\":3,\"sources\":{},\"fetched\":[]}").is_err()
expect LockSnapshot.parse_json(sample_text.replace_each("\"channel\":{", "\"different\":{")).is_err()
expect LockSnapshot.parse_json(sample_text.replace_each("18446744073709551615", "18446744073709551616")).is_err()
expect LockSnapshot.parse_json(sample_text.replace_each("\"flatSha256\":null", "\"flatSha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"")).is_err()
expect LockSnapshot.parse_json(sample_text.replace_each("\"nothing\":null", "\"nothing\":null,\"nothing\":42")).is_err()
expect LockSnapshot.parse_json(sample_text.replace_each("\"metadata\":{\"future\":{", "\"metadata\":{\"future\":null,\"extra\":{")).is_err()
expect {
	program = sample.fetched.first() ?? { name: "", system: "", urls: [], sha256: "", content_identity: "", size: 0, obtained: "" }
	LockSnapshot.to_json({ ..sample, fetched: [program, program] }).is_err()
		and LockSnapshot.to_json({ ..sample, fetched: [{ ..program, content_identity: "wrong" }] }).is_err()
}
expect {
	file = { ..(sample.sources.first() ?? { name: "", provider: "", ref: "", rev: "", digest: "", content_identity: "", digest_kind: Unknown("unknown"), flat_sha256: Absent, metadata: JsonData.Object([]) }), name: "archive", provider: "file", digest_kind: File, rev: "", digest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", content_identity: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", flat_sha256: Present("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), metadata: JsonData.Object([]) }
	result = || {
		text = LockSnapshot.to_json(LockSnapshot.{ sources: [file], fetched: [] })?
		LockSnapshot.parse_json(text)
	}
	result() == Ok(LockSnapshot.{ sources: [file], fetched: [] })
		and LockSnapshot.to_json(LockSnapshot.{ sources: [{ ..file, flat_sha256: Absent }], fetched: [] }).is_err()
}

expect LockSnapshot.parse_json(sample_text.replace_each("published", "future-provenance")).map_ok(|snapshot| snapshot.fetched.first().map_ok(|entry| entry.obtained)) == Ok(Ok("future-provenance"))

# A renamed field never makes an old report silently compatible.
expect LockSnapshot.parse_json("{\"format\":1,\"sources\":{},\"fetched\":[]}") == Err(UnsupportedFormat(1))
