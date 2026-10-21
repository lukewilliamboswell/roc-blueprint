## A JSON value as a tree, for formats a record type cannot describe: JSON-LD
## keys such as `@context`, and arrays whose objects differ in shape by their
## `type`. `Json.parse` reads one through `parser_for`, which drives the
## built-in JSON decoder, so strings, numbers and literals follow its rules
## and its tokenizer. On top of those the tree rejects nesting deeper than
## `max_depth` and an object key repeated with a different value, which would
## mean different things to readers that keep the first or the last. A key
## repeated with the same value says nothing new and appears once: the
## published SPDX 3.0.1 JSON schema repeats `extension` that way.
##
## `parser_for` is hand-written: the compiler hangs deriving one for a
## recursive nominal type. A format's state is internal to the builtin, so the
## parser offers the input to each kind of value in turn; a kind that does
## not start there fails without consuming anything.
JsonTree := [Null, Bool(Bool), Num(Dec), Text(Str), Array(List(JsonTree)), Object(List({ key : Str, value : JsonTree }))].{
	is_eq : _

	parser_for = |encoding| |state| parse_at(encoding, state, 0)

	## The deepest nesting `parse` accepts.
	max_depth : U64
	max_depth = 64

	parse : Str -> Try(JsonTree, Str)
	parse = |text| Json.parse(text).map_err(
		|problem| match problem {
			InvalidJson(message) => message
			_ => "invalid JSON"
		},
	)

	## Compact JSON text. Object members keep their order.
	to_str : JsonTree -> Str
	to_str = |tree|
		match tree {
			Null => "null"
			Bool(b) => if (b) "true" else "false"
			Num(n) => n.to_str()
			Text(s) => Json.to_str(s)
			Array(items) => "[${Str.join_with(items.map(JsonTree.to_str), ",")}]"
			Object(members) => "{${Str.join_with(members.map(|member| "${Json.to_str(member.key)}:${member.value.to_str()}"), ",")}}"
		}

	## The member named `key`, when `tree` is an object that has one.
	field : JsonTree, Str -> Try(JsonTree, [Missing])
	field = |tree, key|
		match tree {
			Object(members) => members.find_first(|member| member.key == key).map_ok(|member| member.value).map_err(|_| Missing)
			_ => Err(Missing)
		}

	## The member names of an object, in order; empty for anything else.
	keys : JsonTree -> List(Str)
	keys = |tree|
		match tree {
			Object(members) => members.map(|member| member.key)
			_ => []
		}

	text : JsonTree -> Try(Str, [NotText])
	text = |tree|
		match tree {
			Text(s) => Ok(s)
			_ => Err(NotText)
		}

	items : JsonTree -> Try(List(JsonTree), [NotArray])
	items = |tree|
		match tree {
			Array(list) => Ok(list)
			_ => Err(NotArray)
		}
}

parse_at = |encoding, state, depth| {
	if depth >= JsonTree.max_depth {
		return Err(InvalidJson("JSON nested deeper than ${JsonTree.max_depth.to_str()} levels"))
	}
	match encoding.parse_str(state) {
		Ok(parsed) => return Ok({ value: JsonTree.Text(parsed.value), rest: parsed.rest })
		Err(_) => {}
	}
	match encoding.parse_bool(state) {
		Ok(parsed) => return Ok({ value: JsonTree.Bool(parsed.value), rest: parsed.rest })
		Err(_) => {}
	}
	match encoding.parse_null(state) {
		Ok(rest) => return Ok({ value: JsonTree.Null, rest })
		Err(_) => {}
	}
	match encoding.parse_dec(state) {
		Ok(parsed) => return Ok({ value: JsonTree.Num(parsed.value), rest: parsed.rest })
		Err(_) => {}
	}
	match encoding.parse_list_start(state) {
		Ok(start) => {
			var $items = []
			var $state = match start {
				Counted({ len: _, rest }) => rest
				Uncounted(rest) => rest
			}
			while True {
				match encoding.parse_list_next($state)? {
					Done(rest) => return Ok({ value: JsonTree.Array($items), rest })
					Item(at) => {
						item = parse_at(encoding, at, depth + 1)?
						$items = $items.append(item.value)
						match encoding.parse_list_after_item(item.rest)? {
							Done(rest) => return Ok({ value: JsonTree.Array($items), rest })
							Continue(rest) => {
								$state = rest
							}
						}
					}
				}
			}
		}
		Err(_) => {}
	}
	start = encoding.parse_dict_start(state)?
	var $members = []
	var $state = match start {
		Counted({ len: _, rest }) => rest
		Uncounted(rest) => rest
	}
	while True {
		match encoding.parse_dict_next($state)? {
			Done(rest) => return Ok({ value: JsonTree.Object($members), rest })
			Entry(at) => {
				key = encoding.parse_key_str(at)?
				member = parse_at(encoding, encoding.parse_dict_after_key(key.rest)?, depth + 1)?
				match $members.find_first(|existing| existing.key == key.value) {
					Ok(existing) => if existing.value != member.value {
						return Err(InvalidJson("conflicting values for JSON key ${Json.to_str(key.value)}"))
					}
					Err(_) => {
						$members = $members.append({ key: key.value, value: member.value })
					}
				}
				match encoding.parse_dict_after_entry(member.rest)? {
					Done(rest) => return Ok({ value: JsonTree.Object($members), rest })
					Continue(rest) => {
						$state = rest
					}
				}
			}
		}
	}
}

expect JsonTree.parse("{\"@context\":\"x\",\"n\":[1,-0.5e3,true,null]}") == Ok(Object([{ key: "@context", value: Text("x") }, { key: "n", value: Array([Num(1), Num(-500), Bool(True), Null]) }]))
expect JsonTree.parse("\"\\u00e9\\ud83d\\ude00\\n\"") == Ok(Text("é😀\n"))
expect JsonTree.parse(" { \"a\" : [ ] , \"b\" : { } } ") == Ok(Object([{ key: "a", value: Array([]) }, { key: "b", value: Object([]) }]))
expect JsonTree.parse("{\"a\":1,\"a\":2}").is_err()
expect JsonTree.parse("{\"a\":[1],\"b\":2,\"a\":[1]}") == Ok(Object([{ key: "a", value: Array([Num(1)]) }, { key: "b", value: Num(2) }]))
expect JsonTree.parse("[1,]").is_err()
expect JsonTree.parse("[] []").is_err()
expect JsonTree.parse(Str.join_with(List.repeat("[", 65), "").concat(Str.join_with(List.repeat("]", 65), ""))).is_err()
expect {
	text = "{\"k\":[\"a\\\"b\",{\"x\":null}],\"e\":{}}"
	JsonTree.parse(text).map_ok(JsonTree.to_str) == Ok(text)
}
