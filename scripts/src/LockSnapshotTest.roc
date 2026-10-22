import cli.Env
import cli.Path
import core.JsonData
import core.Project
import Process
import Script
import "../../blueprint-core/lock-snapshot-v2.schema.json" as schema_text : Str

## The lock snapshot's published contract, checked without the code that
## implements it: `conforms` evaluates the vendored
## `blueprint-core/lock-snapshot-v2.schema.json` itself, then the profile rules
## the schema cannot state. `run!` holds the official consumer in
## `fixtures/lock-snapshot` to the same verdicts, case by case, and to keeping
## metadata number lexemes exactly.
##
## Reading JSON goes through `core.JsonData`, which the consumer uses too; the
## expected verdict of every case is fixed below, so the duplicate-key and
## bound cases still hold that reader to the contract.
LockSnapshotTest := [].{

	## Whether `text` is a format-2 lock snapshot: the schema, then the profile.
	conforms : Str -> Try({}, Str)
	conforms = |text| {
		data = JsonData.decode(text).map_err(JsonData.message)?
		schema = JsonData.decode(schema_text).map_err(JsonData.message)?
		evaluate(schema, schema, data)?
		profile(data)
	}

	## Run the consumer built from `fixtures/lock-snapshot/main.roc` on every
	## case and compare it with `conforms` and the expected verdict.
	run! : Str => Try({}, _)
	run! = |consumer| {
		work = Path.to_str(Env.create_temp_dir_with_prefix!("lock-snapshot-conformance-")?)?
		result = consume!(consumer, work)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

consume! = |consumer, work| {
	example = Process.succeed!(Process.command(consumer, [], work))?.stdout
	all = cases(example)
	var $index = 0.U64
	for (candidate, expected) in all {
		if LockSnapshotTest.conforms(candidate).is_ok() != expected {
			return Script.fail!("lock snapshot case ${$index.to_str()}: the contract says ${if (expected) "valid" else "invalid"}, the independent check disagrees")
		}
		Path.write_utf8!(Path.utf8("${work}/report.json"), candidate)?
		result = Process.capture!(Process.command(consumer, ["${work}/report.json"], work))?
		if (result.code == 0) != expected {
			return Script.fail!("Roc consumer case ${$index.to_str()}: exit ${result.code.to_str()}, ${result.stderr}")
		}
		if expected {
			match LockSnapshotTest.conforms(result.stdout) {
				Ok({}) => {}
				Err(problem) => return Script.fail!("Roc consumer case ${$index.to_str()} wrote a nonconforming report: ${problem}")
			}
			if lexemes.any(|lexeme| candidate.contains(lexeme) and !result.stdout.contains(lexeme)) {
				return Script.fail!("Roc consumer case ${$index.to_str()} lost a metadata number lexeme")
			}
		}
		$index = $index + 1
	}
	Script.pass!("${all.len().to_str()} lock snapshot cases: the vendored schema and profile, checked in Roc, agree with the native consumer; null and numeric metadata kept exactly")
}

lexemes = ["-1.2300e+99999", "340282366920938463463374607431768211455", "9".repeat(10000)]

## Each candidate document and whether the format-2 contract accepts it.
cases : Str -> List((Str, Bool))
cases = |raw| {
	fetched = raw.split_first("\"fetched\":[").map_ok(|parts| parts.after.drop_suffix("\n").drop_suffix("]}")) ?? ""
	file = "{\"format\":2,\"sources\":{\"archive\":{\"name\":\"archive\",\"provider\":\"file\",\"ref\":\"https://example.test/source.tar.gz\",\"rev\":\"\",\"digest\":\"sha256:${file_hash}\",\"content_identity\":\"sha256:${file_hash}\",\"digestKind\":\"file\",\"flatSha256\":\"${file_hash}\",\"metadata\":{}}},\"fetched\":[]}"
	[
		(raw, True),
		(raw.replace_each("\"format\":2", "\"format\":3"), False),
		(raw.replace_each("\"format\":2", "\"format\":2.0"), False),
		(raw.replace_each("\"format\":2", "\"format\":2,\"format\":2"), False),
		(raw.concat("{}"), False),
		(raw.replace_each("18446744073709551615", "18446744073709551616"), False),
		(replace_first(raw, "\"nix\":{", "\"different\":{"), False),
		(raw.replace_each("\"flatSha256\":null", "\"flatSha256\":\"${"a".repeat(64)}\""), False),
		(raw.replace_each("\"published\"", "\"future-state\"").replace_each("\"tree\"", "\"future-kind\""), True),
		(raw.replace_each("\"format\":2", "\"additional\":{\"nested\":[null,2.5]},\"format\":2"), True),
		(raw.replace_each("\"fetched\":[${fetched}]", "\"fetched\":[${fetched},${fetched}]"), False),
		(raw.replace_each("340282366920938463463374607431768211455", "9".repeat(10000)), True),
		(raw.replace_each("-1.2300e+99999", "1e+${"9".repeat(10000)}"), True),
		(raw.replace_each("\"future\":", "\"future\":null,\"\\u0066uture\":"), False),
		(file, True),
		(file.replace_each("\"rev\":\"\"", "\"rev\":\"wrong\""), False),
		(file.replace_each("\"flatSha256\":\"${file_hash}\"", "\"flatSha256\":null"), False),
		(file.replace_each("\"content_identity\":\"sha256:${file_hash}", "\"content_identity\":\"sha256:${"a".repeat(64)}"), False),
		# Where the bytes came from and where a published digest was read:
		# hosts that are nonempty strings, an address that is a string, even
		# an empty one, and an entry that says both.
		(raw.replace_each("\"served\":[]", "\"served\":[\"objects.example.test\",\"mirror.example.test\"]"), True),
		(raw.replace_each("\"witness\":\"", "\"witness\":\"\",\"was\":\""), True),
		(raw.replace_each("\"served\":[]", "\"served\":[\"\"]"), False),
		(raw.replace_each("\"served\":[]", "\"served\":\"objects.example.test\""), False),
		(raw.replace_each("\"served\":[]", "\"unserved\":[]"), False),
		(raw.replace_each("\"witness\":\"", "\"witness\":null,\"was\":\""), False),
		(raw.replace_each("\"witness\":\"", "\"unwitnessed\":\""), False),
	]
}

file_hash = "b".repeat(64)

replace_first = |text, old, new| match text.split_first(old) {
	Ok(parts) => "${parts.before}${new}${parts.after}"
	Err(_) => text
}

## The rules JSON Schema cannot state: integer lexemes, keys that repeat a
## source's name, identities that repeat a declared hash, and one entry per
## program and system.
profile : JsonData -> Try({}, Str)
profile = |data| {
	member = |value, name| JsonData.field(value, name).map_err(JsonData.message)
	text = |value, name| JsonData.string(member(value, name)?).map_err(JsonData.message)
	if !integral(member(data, "format")?) {
		return Err("format must use an integer JSON lexeme")
	}
	for source in members(member(data, "sources")?) {
		if text(source.value, "name")? != source.name {
			return Err("source key/name mismatch")
		}
		if text(source.value, "provider")? == "file" {
			content_identity = "sha256:${text(source.value, "flatSha256")?}"
			if text(source.value, "content_identity")? != content_identity or text(source.value, "digest")? != content_identity {
				return Err("flat digest/content_identity mismatch")
			}
		}
	}
	var $seen = []
	for entry in elements(member(data, "fetched")?) {
		key = (text(entry, "name")?, text(entry, "system")?)
		if $seen.contains(key) {
			return Err("duplicate fetched program/system")
		}
		$seen = $seen.append(key)
		if !integral(member(entry, "size")?) {
			return Err("size must use an integer JSON lexeme")
		}
		if text(entry, "content_identity")? != "sha256:${text(entry, "sha256")?}" {
			return Err("program digest/content_identity mismatch")
		}
	}
	Ok({})
}

integral : JsonData -> Bool
integral = |value| match value {
	Number(lexeme) => JsonData.whole(lexeme.drop_prefix("-")) and !lexeme.contains(".")
	_ => False
}

## The JSON Schema 2020-12 keywords the vendored schema uses. A keyword or
## pattern outside them is refused, never skipped: `supported` holds the
## schema to that by expect.
evaluate : JsonData, JsonData, JsonData -> Try({}, Str)
evaluate = |root, schema, value| {
	for keyword in members(schema) {
		rule = keyword.value
		match keyword.name {
			"$schema" | "$id" | "title" | "description" | "$defs" | "then" | "else" => {}
			"type" => {
				if !of_type(value, rule) {
					return Err("expected ${encoded(rule)}, got ${encoded(value)}")
				}
			}
			"const" => {
				if !same(rule, value) {
					return Err("expected ${encoded(rule)}")
				}
			}
			"required" => {
				for name in names(rule) {
					if is_object(value) and !JsonData.keys(value).contains(name) {
						return Err("missing ${name}")
					}
				}
			}
			"properties" => {
				for property in members(value) {
					match JsonData.field(rule, property.name) {
						Ok(sub) => evaluate(root, sub, property.value).map_err(|problem| "${property.name}: ${problem}")?
						Err(_) => {}
					}
				}
			}
			"additionalProperties" => {
				listed = JsonData.keys(JsonData.field(schema, "properties") ?? JsonData.Object([]))
				for property in members(value) {
					if !listed.contains(property.name) {
						evaluate(root, rule, property.value).map_err(|problem| "${property.name}: ${problem}")?
					}
				}
			}
			"items" => {
				for item in elements(value) {
					evaluate(root, rule, item)?
				}
			}
			"maxProperties" => {
				if members(value).len() > count(rule) {
					return Err("too many members")
				}
			}
			"maxItems" => {
				if elements(value).len() > count(rule) {
					return Err("too many items")
				}
			}
			"minItems" => {
				if is_array(value) and elements(value).len() < count(rule) {
					return Err("too few items")
				}
			}
			"minLength" => {
				if is_string(value) and characters(value) < count(rule) {
					return Err("too short")
				}
			}
			"maxLength" => {
				if is_string(value) and characters(value) > count(rule) {
					return Err("too long")
				}
			}
			"pattern" => {
				match (value, rule) {
					(String(text), String(pattern)) => {
						if !matches(pattern, text) {
							return Err("does not match ${pattern}")
						}
					}
					_ => {}
				}
			}
			"minimum" => {
				if compare(value, rule) == Ok(LT) {
					return Err("below ${encoded(rule)}")
				}
			}
			"maximum" => {
				if compare(value, rule) == Ok(GT) {
					return Err("above ${encoded(rule)}")
				}
			}
			"$ref" => evaluate(root, definition(root, rule)?, value)?
			"anyOf" => {
				if !elements(rule).any(|sub| evaluate(root, sub, value).is_ok()) {
					return Err("matches no alternative")
				}
			}
			"allOf" => {
				for sub in elements(rule) {
					evaluate(root, sub, value)?
				}
			}
			"if" => {
				branch = if evaluate(root, rule, value).is_ok() {
					"then"
				} else {
					"else"
				}
				match JsonData.field(schema, branch) {
					Ok(sub) => evaluate(root, sub, value)?
					Err(_) => {}
				}
			}
			other => return Err("unsupported JSON Schema keyword: ${other}")
		}
	}
	Ok({})
}

## Whether the evaluator understands every keyword and pattern in `schema`.
supported : JsonData -> Bool
supported = |schema| match schema {
	Object(fields) =>
		fields.all(
			|keyword|
				known.contains(keyword.name)
					and (keyword.name != "pattern" or patterns.contains(JsonData.string(keyword.value) ?? ""))
						and (
							if ["properties", "$defs"].contains(keyword.name) {
								members(keyword.value).all(|member| supported(member.value))
							} else if ["required", "type", "const"].contains(keyword.name) {
								True
							} else {
								supported(keyword.value)
							}
						),
		)
	Array(items) => items.all(supported)
	_ => True
}

known = ["$schema", "$id", "title", "description", "$defs", "type", "const", "required", "properties", "additionalProperties", "items", "maxProperties", "maxItems", "minItems", "minLength", "maxLength", "pattern", "minimum", "maximum", "$ref", "anyOf", "allOf", "if", "then", "else"]

patterns = ["\\S", "^[a-f0-9]{64}$", "^sha256:[a-f0-9]{64}$"]

matches : Str, Str -> Bool
matches = |pattern, text| match pattern {
	"\\S" => text.to_utf8().any(|byte| ![' ', '\t', '\n', '\r', 11, 12].contains(byte))
	"^[a-f0-9]{64}$" => hex(text)
	"^sha256:[a-f0-9]{64}$" => text.starts_with("sha256:") and hex(text.drop_prefix("sha256:"))
	_ => False
}

hex = |text| text.to_utf8().len() == 64 and text.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))

definition : JsonData, JsonData -> Try(JsonData, Str)
definition = |root, reference| match reference {
	String(target) if target.starts_with("#/$defs/") =>
		{
			all = JsonData.field(root, "$defs").map_err(JsonData.message)?
			JsonData.field(all, target.drop_prefix("#/$defs/")).map_err(JsonData.message)
		}
	_ => Err("unsupported reference ${encoded(reference)}")
}

of_type : JsonData, JsonData -> Bool
of_type = |value, kind| match (kind, value) {
	(String("object"), Object(_)) => True
	(String("array"), Array(_)) => True
	(String("string"), String(_)) => True
	(String("null"), Null) => True
	(String("boolean"), Boolean(_)) => True
	(String("number"), Number(_)) => True
	(String("integer"), Number(lexeme)) => JsonData.whole(lexeme.drop_prefix("-"))
	_ => False
}

## JSON Schema equality: numbers by value, so `1` is `1.0`.
same : JsonData, JsonData -> Bool
same = |left, right| match (left, right) {
	(Number(_), Number(_)) => compare(left, right) == Ok(EQ)
	_ => left == right
}

## Order two integer-valued numbers by their lexemes, whatever their size.
compare : JsonData, JsonData -> Try([LT, EQ, GT], [Unordered])
compare = |left, right| match (left, right) {
	(Number(a), Number(b)) if JsonData.whole(a.drop_prefix("-")) and JsonData.whole(b.drop_prefix("-")) => {
		x = signed(a)
		y = signed(b)
		match (x.negative, y.negative) {
			(False, True) => Ok(GT)
			(True, False) => Ok(LT)
			(False, False) => Ok(magnitude(x.integral, y.integral))
			(True, True) => Ok(magnitude(y.integral, x.integral))
		}
	}
	_ => Err(Unordered)
}

signed = |lexeme| {
	part = lexeme.drop_prefix("-").split_on(".").first() ?? "0"
	{ negative: lexeme.starts_with("-") and part != "0", integral: part }
}

## Integral lexemes without leading zeros order by length, then bytes.
magnitude = |a, b|
	if a.to_utf8().len() < b.to_utf8().len() {
		LT
	} else if a.to_utf8().len() > b.to_utf8().len() {
		GT
	} else {
		match Project.bytewise(a, b) {
			Before => LT
			Same => EQ
			After => GT
		}
	}

count : JsonData -> U64
count = |rule| match rule {
	Number(lexeme) => U64.from_str(lexeme) ?? 0
	_ => 0
}

## A string's length in code points, as JSON Schema counts it.
characters : JsonData -> U64
characters = |value| match value {
	String(text) => text.to_utf8().count_if(|byte| byte < 0x80 or byte >= 0xC0)
	_ => 0
}

names : JsonData -> List(Str)
names = |value| elements(value).keep_oks(JsonData.string)

members = |value| JsonData.object(value) ?? []

elements = |value| JsonData.array(value) ?? []

is_object = |value| JsonData.object(value).is_ok()

is_array = |value| JsonData.array(value).is_ok()

is_string = |value| JsonData.string(value).is_ok()

encoded = |value| JsonData.encode(value) ?? "a value"

sample = "{\"format\":2,\"sources\":{\"nix\":{\"name\":\"nix\",\"provider\":\"nix\",\"ref\":\"github:example/packages\",\"rev\":\"abc\",\"digest\":\"opaque-tree\",\"content_identity\":\"opaque-content\",\"digestKind\":\"tree\",\"flatSha256\":null,\"metadata\":{\"nix\":{\"fetchTree\":{\"type\":\"git\",\"url\":\"https://example.test/packages.git\",\"rev\":\"abc\"},\"future\":[null,340282366920938463463374607431768211455,-1.2300e+99999]}}}},\"fetched\":[{\"name\":\"roc-stable\",\"system\":\"x86_64-linux\",\"urls\":[\"https://example.test/roc.tar.gz\"],\"sha256\":\"${"a".repeat(64)}\",\"content_identity\":\"sha256:${"a".repeat(64)}\",\"size\":18446744073709551615,\"obtained\":\"published\",\"served\":[],\"witness\":\"https://api.example.test/repos/example/roc/releases/tags/1.0\"}]}\n"

expect JsonData.decode(schema_text).map_ok(supported) == Ok(True)
expect cases(sample).all(|(candidate, expected)| LockSnapshotTest.conforms(candidate).is_ok() == expected)
expect cases(sample).len() == 25 and cases(sample).drop_first(1).all(|(candidate, _)| candidate != sample)
expect LockSnapshotTest.conforms(sample.replace_each("\"urls\":[\"https://example.test/roc.tar.gz\"]", "\"urls\":[]")).is_err()
expect LockSnapshotTest.conforms(sample.replace_each("\"obtained\":\"published\"", "\"obtained\":\" \"")).is_err()
expect LockSnapshotTest.conforms(sample.replace_each("\"size\":18446744073709551615", "\"size\":-1")).is_err()
expect LockSnapshotTest.conforms(sample.replace_each("\"sha256\":\"a", "\"sha256\":\"A")).is_err()
expect LockSnapshotTest.conforms(sample.replace_each("\"metadata\":{\"nix\":{", "\"metadata\":{\"nix\":[{").replace_each("]}}}},", "]}]}}},")).is_err()
expect LockSnapshotTest.conforms(sample.replace_each("\"sources\":{", "\"sources\":[").replace_each("}}}},\"fetched\"", "}}}],\"fetched\"")).is_err()
expect !supported(JsonData.Object([{ name: "pattern", value: JsonData.String("^[a-z]+$") }]))
expect !supported(JsonData.Object([{ name: "oneOf", value: JsonData.Array([]) }]))
expect same(JsonData.Number("1"), JsonData.Number("1.0")) and !same(JsonData.Number("1"), JsonData.Number("2"))
expect compare(JsonData.Number("18446744073709551616"), JsonData.Number("18446744073709551615")) == Ok(GT)
expect compare(JsonData.Number("-1"), JsonData.Number("0")) == Ok(LT) and compare(JsonData.Number("-0"), JsonData.Number("0")) == Ok(EQ)
