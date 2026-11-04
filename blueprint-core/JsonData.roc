# Bounded JSON data codec for inert data; numbers retain their exact JSON lexemes.
# Duplicate keys, malformed Unicode and trailing input fail before planning.
import Project
import parser.JsonValue

JsonData := [
	Object(List({ name : Str, value : JsonData })),
	Array(List(JsonData)),
	String(Str),
	Number(Str),
	Boolean(Bool),
	Null,
].{
	Error : [InvalidJson(Str), LimitExceeded(Str)]

	is_eq : _

	## Collection and duplicate rules, independent of the byte budget. Every
	## decode/encode has a 128-level bound. A key repeated in one object means:
	## `Reject` refuses it, and `CollapseIdentical` keeps one copy of a key
	## repeated with an equal value and refuses one repeated with another.
	Rules : { max_items : U64, duplicates : [Reject, CollapseIdentical] }

	## The rules `decode` and `encode` apply: small authority documents.
	defaults : Rules
	defaults = { max_items: 4096, duplicates: Reject }

	## Large documents such as SBOMs, whose arrays can hold every element of a
	## supply chain: the byte bound is what limits them.
	documents : Rules
	documents = { max_items: 131072, duplicates: Reject }

	decode : Str -> Try(JsonData, Error)
	decode = |text| JsonData.decode_with(text, defaults)

	decode_with : Str, Rules -> Try(JsonData, Error)
	decode_with = |text, rules| JsonData.decode_bounded(text, rules, 8388608)

	## An inclusive UTF-8 byte budget; depth and collection rules stay fixed.
	## Zero admits no valid JSON, and every explicit budget remains finite.
	decode_bounded : Str, Rules, U64 -> Try(JsonData, Error)
	decode_bounded = |text, rules, max_bytes| {
		options : JsonValue.Options
		options = {
			max_bytes: max_bytes,
			max_depth: 128,
			max_items: rules.max_items,
			duplicates: match rules.duplicates {
				Reject => Reject
				CollapseIdentical => CollapseIdentical
			},
		}
		JsonValue.parse_with(text, options)
			.map_ok(from_parser)
			.map_err(|InvalidJsonValue(error)| read_error(error.message, rules, max_bytes))
	}

	encode : JsonData -> Try(Str, Error)
	encode = |value| JsonData.encode_with(value, defaults)

	encode_with : JsonData, Rules -> Try(Str, Error)
	encode_with = |value, rules| JsonData.encode_bounded(value, rules, 8388608)

	## Size escaped output before allocation, then apply the same inclusive
	## byte budget to the output through roc-parser’s checked writer.
	encode_bounded : JsonData, Rules, U64 -> Try(Str, Error)
	encode_bounded = |value, rules, max_bytes| {
		converted = to_parser(value, 0, rules)?
		JsonValue.to_str_with(converted, { max_bytes: max_bytes }).map_err(
			|error| match error {
				TooLarge(_) => byte_limit(max_bytes)
				TooDeep => LimitExceeded("JSON exceeds 128 levels")
				DuplicateKey(key) => InvalidJson("duplicate JSON key: ${key}")
				InvalidNumber(text) => InvalidJson("invalid JSON number: ${text}")
			},
		)
	}

	## A JSON number lexeme with no fractional part, as JSON Schema counts an
	## integer: `3`, or `3.0`.
	whole : Str -> Bool
	whole = |lexeme| {
		digits = match lexeme.split_on(".") {
			[integral] => Ok(integral)
			[integral, fraction] if !fraction.is_empty() and fraction.to_utf8().all(|byte| byte == '0') => Ok(integral)
			_ => Err(Fractional)
		}
		match digits {
			Ok(integral) => !integral.is_empty() and integral.to_utf8().all(|byte| byte >= '0' and byte <= '9') and (integral == "0" or !integral.starts_with("0"))
			Err(_) => False
		}
	}

	## What went wrong, in words.
	message : Error -> Str
	message = |error|
		match error {
			InvalidJson(text) => text
			LimitExceeded(text) => text
		}

	## The member names of an object, in order; none for anything else.
	keys : JsonData -> List(Str)
	keys = |value|
		match value {
			Object(fields) => fields.map(|f| f.name)
			_ => []
		}

	quote : Str -> Str
	quote = |text| JsonValue.to_str(JsonValue.String(text)) ?? crash "JSON string exceeds addressable output size"

	field : JsonData, Str -> Try(JsonData, Error)
	field = |value, name| {
		fields = object(value)?
		fields.find_first(|f| f.name == name)
			.map_ok(|f| f.value).map_err(|_| InvalidJson("missing JSON field: ${name}"))
	}

	object : JsonData -> Try(List({ name : Str, value : JsonData }), Error)
	object = |value| match value {
		Object(fields) => Ok(fields)
		_ => Err(InvalidJson("expected JSON object"))
	}

	array : JsonData -> Try(List(JsonData), Error)
	array = |value| match value {
		Array(items) => Ok(items)
		_ => Err(InvalidJson("expected JSON array"))
	}

	string : JsonData -> Try(Str, Error)
	string = |value| match value {
		String(text) => Ok(text)
		_ => Err(InvalidJson("expected JSON string"))
	}

	set : JsonData, Str, JsonData -> Try(JsonData, Error)
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
	sorted : JsonData -> JsonData
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

# Blueprint keeps its public value shape and collection policy; roc-parser owns
# JSON syntax, Unicode, duplicate detection, and sizing before serialization.
from_parser : JsonValue -> JsonData
from_parser = |value| match value {
	Object(fields) => JsonData.Object(fields.map(|f| { name: f.key, value: from_parser(f.value) }))
	Array(items) => JsonData.Array(items.map(from_parser))
	String(text) => JsonData.String(text)
	Number(text) => JsonData.Number(text)
	Bool(flag) => JsonData.Boolean(flag)
	Null => JsonData.Null
}

# Bound recursion before converting an untrusted constructed tree. The upstream
# writer validates numbers, duplicate keys and output bytes without a readback.
to_parser : JsonData, U64, JsonData.Rules -> Try(JsonValue, JsonData.Error)
to_parser = |value, depth, rules| {
	match value {
		Object(fields) => {
			if depth >= 128 {
				return Err(LimitExceeded("JSON exceeds 128 levels"))
			}
			if fields.len() > rules.max_items {
				return Err(LimitExceeded("JSON object exceeds ${rules.max_items.to_str()} fields"))
			}
			var $out = []
			for field in fields {
				$out = $out.append({ key: field.name, value: to_parser(field.value, depth + 1, rules)? })
			}
			Ok(JsonValue.Object($out))
		}
		Array(items) => {
			if depth >= 128 {
				return Err(LimitExceeded("JSON exceeds 128 levels"))
			}
			if items.len() > rules.max_items {
				return Err(LimitExceeded("JSON array exceeds ${rules.max_items.to_str()} items"))
			}
			var $out = []
			for item in items {
				$out = $out.append(to_parser(item, depth + 1, rules)?)
			}
			Ok(JsonValue.Array($out))
		}
		String(text) => Ok(JsonValue.String(text))
		Number(text) => Ok(JsonValue.Number(text))
		Boolean(flag) => Ok(JsonValue.Bool(flag))
		Null => Ok(JsonValue.Null)
	}
}

byte_limit : U64 -> JsonData.Error
byte_limit = |max_bytes| LimitExceeded(if (max_bytes == 8388608) "JSON exceeds 8 MiB" else "JSON exceeds ${max_bytes.to_str()} bytes")

read_error : Str, JsonData.Rules, U64 -> JsonData.Error
read_error = |message, rules, max_bytes| {
	if message == "document exceeds the limit of ${max_bytes.to_str()} bytes" {
		byte_limit(max_bytes)
	}
	else if message == "nesting exceeds the limit of 128 levels" {
		LimitExceeded("JSON exceeds 128 levels")
	}
	else if message == "array has more than ${rules.max_items.to_str()} items" {
		LimitExceeded("JSON array exceeds ${rules.max_items.to_str()} items")
	}
	else if message == "object has more than ${rules.max_items.to_str()} members" {
		LimitExceeded("JSON object exceeds ${rules.max_items.to_str()} fields")
	}
	else {
		InvalidJson(message)
	}
}

# Unicode surrogate pairs and escaped controls survive exact JSON round trips.
expect {
	text = "a\n\t\"\\é😀"
	JsonData.decode(JsonData.quote(text)) == Ok(JsonData.String(text))
		and JsonData.decode("\"\\ud83d\\ude00\"") == Ok(JsonData.String("😀"))
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
	.all(|text| JsonData.decode(text).is_err())

# Native graph booleans, numbers, arrays and null remain typed data.
expect match JsonData.decode("{\"a\":[true,false,null,-1.25e+2,0]}") {
	Ok(value) => match JsonData.encode(value) {
		Ok(text) => JsonData.decode(text) == Ok(value)
		Err(_) => False
	}
	Err(_) => False
}

# Depth and collection bounds reject oversized untrusted lock structures.
expect {
	var $nested = "null"
	var $items = []
	var $i = 0
	while $i < 4097 {
		$items = $items.append(JsonData.Null)
		if $i < 130 {
			$nested = "[${$nested}]"
		}
		$i = $i + 1
	}
	JsonData.decode($nested).is_err()
		and JsonData.encode(JsonData.Array($items)).is_err()
}

expect {
	result = || {
		value = JsonData.decode("{\"b\":[{\"z\":1,\"a\":2}],\"a\":{\"d\":\"x\",\"c\":true}}")?
		JsonData.encode(JsonData.sorted(value))
	}
	result() == Ok("{\"a\":{\"c\":true,\"d\":\"x\"},\"b\":[{\"a\":2,\"z\":1}]}")
}

# Constructed metadata is untrusted too: numeric lexemes cannot inject syntax.
expect ["", "null", "01", "1,2", "1e", "NaN", "1}\n{\"injected\":true"].all(|text| JsonData.encode(JsonData.Number(text)).is_err())
expect JsonData.encode(JsonData.Object([{ name: "a", value: JsonData.Null }, { name: "a", value: JsonData.Boolean(True) }])).is_err()
expect JsonData.encode(JsonData.Number("340282366920938463463374607431768211455")) == Ok("340282366920938463463374607431768211455")
expect JsonData.decode("{\"a\":1,\"\\u0061\":2}").is_err()

expect {
	var $nested = JsonData.Null
	var $depth = 0
	while $depth < 130 {
		$nested = JsonData.Array([$nested])
		$depth = $depth + 1
	}
	JsonData.encode($nested) == Err(LimitExceeded("JSON exceeds 128 levels"))
}

expect {
	var $text = "a"
	var $doublings = 0
	while $doublings < 23 {
		$text = $text.concat($text)
		$doublings = $doublings + 1
	}
	JsonData.decode($text.concat("a")) == Err(LimitExceeded("JSON exceeds 8 MiB"))
		and JsonData.encode(JsonData.String($text)) == Err(LimitExceeded("JSON exceeds 8 MiB"))
}

# Larger documents may hold more items; a key repeated with an equal value is
# one key only where the rules say so, and a conflicting one never is.
expect {
	items = Str.join_with(List.repeat("0", 5000), ",")
	JsonData.decode("[${items}]").is_err() and JsonData.decode_with("[${items}]", JsonData.documents).is_ok()
}
expect JsonData.decode("{\"a\":[1],\"a\":[1]}").is_err()
expect JsonData.decode_with("{\"a\":[1],\"b\":2,\"a\":[1]}", { ..JsonData.documents, duplicates: CollapseIdentical }) == Ok(JsonData.Object([{ name: "a", value: JsonData.Array([JsonData.Number("1")]) }, { name: "b", value: JsonData.Number("2") }]))
expect JsonData.decode_with("{\"a\":1,\"a\":2}", { ..JsonData.documents, duplicates: CollapseIdentical }).is_err()
expect JsonData.keys(JsonData.Object([{ name: "x", value: JsonData.Null }])) == ["x"] and JsonData.message(InvalidJson("bad")) == "bad"
expect JsonData.whole("0") and JsonData.whole("12") and JsonData.whole("3.00") and !JsonData.whole("01") and !JsonData.whole("1.5") and !JsonData.whole("-1") and !JsonData.whole("1e3")

# Inclusive budgets account for whitespace, UTF-8 and escaped output.
expect JsonData.decode_bounded("null", JsonData.defaults, 4) == Ok(JsonData.Null)
expect JsonData.decode_bounded("null ", JsonData.defaults, 4) == Err(LimitExceeded("JSON exceeds 4 bytes"))
expect JsonData.encode_bounded(JsonData.String(""), JsonData.defaults, 2) == Ok("\"\"")
expect JsonData.encode_bounded(JsonData.String(""), JsonData.defaults, 1) == Err(LimitExceeded("JSON exceeds 1 bytes"))
expect JsonData.encode_bounded(JsonData.Array([]), JsonData.defaults, 0) == Err(LimitExceeded("JSON exceeds 0 bytes"))
expect JsonData.decode_bounded("0", JsonData.defaults, 0) == Err(LimitExceeded("JSON exceeds 0 bytes"))
expect JsonData.decode_bounded("", JsonData.defaults, 0).is_err()
expect JsonData.encode_bounded(JsonData.String("\u(0001)"), JsonData.defaults, 7).is_err()
expect JsonData.encode_bounded(JsonData.String("\u(0001)"), JsonData.defaults, 8).map_ok(|text| text.to_utf8().len()) == Ok(8)
expect JsonData.encode_bounded(JsonData.String("é"), JsonData.defaults, 4).map_ok(|text| text.to_utf8().len()) == Ok(4)
expect JsonData.encode_bounded(JsonData.Object([{ name: "\u(0001)", value: JsonData.Null }]), JsonData.defaults, 14).is_err()
expect JsonData.encode_bounded(JsonData.Object([{ name: "\u(0001)", value: JsonData.Null }]), JsonData.defaults, 15).is_ok()
expect JsonData.encode_bounded(JsonData.Array([JsonData.Null, JsonData.Null]), JsonData.defaults, 10) == Err(LimitExceeded("JSON exceeds 10 bytes"))
expect JsonData.encode_bounded(JsonData.Array([JsonData.Null, JsonData.Null]), JsonData.defaults, 11) == Ok("[null,null]")
expect JsonData.encode_bounded(JsonData.Number("NaN"), JsonData.defaults, 100).is_err()
expect JsonData.decode_bounded("{\"x\":0,\"x\":0}", JsonData.documents, 100).is_err()
expect JsonData.decode_bounded("[0,0]", { ..JsonData.documents, max_items: 1 }, 100).is_err()
expect JsonData.encode_bounded(JsonData.Null, JsonData.defaults, 18446744073709551615) == Ok("null")

# A larger explicit budget reaches escaping and allocation;
# the existing public entrypoints retain their original 8 MiB errors.
expect {
	value = JsonData.String("a".repeat(8388607))
	JsonData.encode_with(value, JsonData.documents) == Err(LimitExceeded("JSON exceeds 8 MiB"))
		and match JsonData.encode_bounded(value, JsonData.documents, 8388609) {
			Ok(text) => JsonData.decode_with(text, JsonData.documents) == Err(LimitExceeded("JSON exceeds 8 MiB")) and JsonData.decode_bounded(text, JsonData.documents, 8388609) == Ok(value)
			Err(_) => False
		}
}

expect {
	var $tree = JsonData.Null
	var $text = "null"
	var $depth = 0
	while $depth < 129 {
		$tree = JsonData.Array([$tree])
		$text = "[${$text}]"
		$depth = $depth + 1
	}
	JsonData.encode_bounded($tree, JsonData.documents, 16777216) == Err(LimitExceeded("JSON exceeds 128 levels"))
		and JsonData.decode_bounded($text, JsonData.documents, 16777216) == Err(LimitExceeded("JSON exceeds 128 levels"))
}
expect JsonData.encode_bounded(JsonData.Object([{ name: "a", value: JsonData.Null }, { name: "a", value: JsonData.Null }]), { ..JsonData.documents, duplicates: CollapseIdentical }, 100).is_err()
expect JsonData.encode_bounded(JsonData.Array([JsonData.Null, JsonData.Null]), { ..JsonData.documents, max_items: 1 }, 100).is_err()
expect JsonData.encode_bounded(JsonData.Array([JsonData.Object([{ name: "a", value: JsonData.Null }])]), JsonData.documents, 11).is_err()

# Upstream uses short escapes where JSON defines them; budgets count those
# emitted bytes, while other controls still need six-byte Unicode escapes.
expect JsonData.encode_bounded(JsonData.String("\n"), JsonData.defaults, 4) == Ok("\"\\n\"")
expect JsonData.encode_bounded(JsonData.String("\n"), JsonData.defaults, 3) == Err(LimitExceeded("JSON exceeds 3 bytes"))
expect JsonData.decode_bounded("[0,0]", { ..JsonData.defaults, max_items: 1 }, 100) == Err(LimitExceeded("JSON array exceeds 1 items"))

# The inclusive 128-container limit agrees in the value adapter and parser.
expect {
	var $tree = JsonData.Null
	var $text = "null"
	var $depth = 0
	while $depth < 128 {
		$tree = JsonData.Array([$tree])
		$text = "[${$text}]"
		$depth = $depth + 1
	}
	JsonData.encode($tree) == Ok($text) and JsonData.decode($text) == Ok($tree)
}
