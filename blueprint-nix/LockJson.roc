# Bounded JSON data codec for native Nix lock graphs and authority envelopes.
# Duplicate keys, malformed Unicode and trailing input fail before planning.
import core.Project
import core.JsonData

LockJson := [
	Object(List({ name : Str, value : LockJson })),
	Array(List(LockJson)),
	String(Str),
	Number(Str),
	Boolean(Bool),
	Null,
].{
	is_eq : _

	decode : Str -> Try(LockJson, Str)
	decode = |text| JsonData.decode(text).map_ok(from_data).map_err(
		|error| match error {
			InvalidJson(message) => message.replace_each("in JSON", "in lock JSON").replace_each("duplicate JSON key:", "duplicate lock JSON key:")
			LimitExceeded(message) => message.replace_each("JSON", "lock JSON")
		},
	)

	from_data : JsonData -> LockJson
	from_data = |value| match value {
		Object(fields) => Object(fields.map(|field| { name: field.name, value: from_data(field.value) }))
		Array(items) => Array(items.map(from_data))
		String(text) => String(text)
		Number(text) => Number(text)
		Boolean(boolean) => Boolean(boolean)
		Null => Null
	}

	encode : LockJson -> Str
	encode = |value| match value {
		Object(fields) => {
			items = fields.map(|f| "${quote(f.name)}:${encode(f.value)}")
			"{${Str.join_with(items, ",")}}"
		}
		Array(items) => "[${Str.join_with(items.map(encode), ",")}]"
		String(text) => quote(text)
		Number(text) => text
		Boolean(value_) => if (value_) "true" else "false"
		Null => "null"
	}

	quote : Str -> Str
	quote = |text| {
		var $bytes = ['"']
		for byte in text.to_utf8() {
			$bytes = $bytes.concat(
				match byte {
					'"' => ['\\', '"']
					'\\' => ['\\', '\\']
					_ => if byte < 32 {
						digits = "0123456789abcdef".to_utf8()
						[
							'\\',
							'u',
							'0',
							'0',
							digits.get(byte.to_u64() // 16) ?? '0',
							digits.get(byte.to_u64() % 16) ?? '0',
						]
					} else [byte]
				},
			)
		}
		Str.from_utf8($bytes.append('"')) ?? "\"\""
	}

	field : LockJson, Str -> Try(LockJson, Str)
	field = |value, name| {
		fields = object(value)?
		fields.find_first(|f| f.name == name)
			.map_ok(|f| f.value).map_err(|_| "missing lock field: ${name}")
	}

	object : LockJson -> Try(List({ name : Str, value : LockJson }), Str)
	object = |value| match value {
		Object(fields) => Ok(fields)
		_ => Err("expected JSON object in lock")
	}

	array : LockJson -> Try(List(LockJson), Str)
	array = |value| match value {
		Array(items) => Ok(items)
		_ => Err("expected JSON array in lock")
	}

	string : LockJson -> Try(Str, Str)
	string = |value| match value {
		String(text) => Ok(text)
		_ => Err("expected JSON string in lock")
	}

	set : LockJson, Str, LockJson -> Try(LockJson, Str)
	set = |value, name, replacement| {
		fields = object(value)?
		Ok(
			Object(
				fields.keep_if(|f| f.name != name)
					.append({ name, value: replacement }),
			),
		)
	}

	## The same value with the fields of every object in byte order of their
	## names, the order Nix writes a lock in.
	sorted : LockJson -> LockJson
	sorted = |value|
		match value {
			Object(fields) => Object(
				fields.map(|entry| { name: entry.name, value: sorted(entry.value) })
					.sort_with(|left, right| Project.bytewise(left.name, right.name)),
			)
			Array(items) => Array(items.map(sorted))
			_ => value
		}

}

# Unicode surrogate pairs and escaped controls survive exact JSON round trips.
expect {
	text = "a\n\t\"\\é😀"
	LockJson.decode(LockJson.quote(text)) == Ok(LockJson.String(text))
		and LockJson.decode("\"\\ud83d\\ude00\"") == Ok(LockJson.String("😀"))
}

# A malformed authority never gets to a native provider process.
expect [
	"",
	"{}{}",
	"{\"a\":1,\"a\":2}",
	"[1,]",
	"01",
	"1e",
	"\"\\ud800\"",
	"\"\\udc00\"",
	"\"\\x00\"",
	"{\"a\" 1}",
	"true false",
]
	.all(|text| LockJson.decode(text).is_err())

# Native graph booleans, numbers, arrays and null remain typed data.
expect match LockJson.decode("{\"a\":[true,false,null,-1.25e+2,0]}") {
	Ok(value) => LockJson.decode(LockJson.encode(value)) == Ok(value)
	Err(_) => False
}

# Depth and collection bounds reject oversized untrusted lock structures.
expect {
	var $nested = "null"
	var $items = []
	var $i = 0
	while $i < 4097 {
		$items = $items.append(LockJson.Null)
		if $i < 130 {
			$nested = "[${$nested}]"
		}
		$i = $i + 1
	}
	LockJson.decode($nested).is_err()
		and LockJson.decode(LockJson.encode(LockJson.Array($items))).is_err()
}

expect LockJson.decode("{\"b\":[{\"z\":1,\"a\":2}],\"a\":{\"d\":\"x\",\"c\":true}}").map_ok(|value| LockJson.encode(LockJson.sorted(value))) == Ok("{\"a\":{\"c\":true,\"d\":\"x\"},\"b\":[{\"a\":2,\"z\":1}]}")

# Compatibility facade retains the old data constructors, errors and bytes.
expect LockJson.decode("true false") == Err("trailing data in lock JSON")
expect LockJson.decode("{\"a\":1 \"b\":2}") == Err("expected comma in lock JSON object")
expect LockJson.decode("{\"a\":1,\"a\":2}") == Err("duplicate lock JSON key: a")
