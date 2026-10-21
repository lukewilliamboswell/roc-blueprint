## Pure typed metadata encoding. Duplicate attributes are never ambiguous JSON.
import core.Value

ReportJson := [].{
	object : List((Str, Str)) -> Str
	object = |fields| "{${Str.join_with(fields.map(|(name, value)| "${Json.to_str(name)}:${value}"), ",")}}"

	value : Value -> Try(Str, Str)
	value = |input| match input {
		Str(text) => Ok(Json.to_str(text))
		Int(number) => Ok(number.to_str())
		Bool(boolean) => Ok(if (boolean) "true" else "false")
		List(items) => {
			var $encoded = []
			for item in items {
				$encoded = $encoded.append(value(item)?)
			}
			Ok("[${Str.join_with($encoded, ",")}]")
		}
		Attrs(fields) => {
			var $encoded = []
			var $names = []
			for field in fields {
				if $names.contains(field.name) {
					return Err("duplicate report metadata field: ${field.name}")
				}
				$names = $names.append(field.name)
				$encoded = $encoded.append((field.name, value(field.value)?))
			}
			Ok(object($encoded))
		}
	}
}

expect ReportJson.value(Value.Attrs([{ name: "x", value: Value.Int(1) }, { name: "x", value: Value.Bool(True) }])) == Err("duplicate report metadata field: x")
expect ReportJson.value(Value.List([Value.Attrs([{ name: "a", value: Value.Str("λ\n\"") }]), Value.Bool(False)])) == Ok("[{\"a\":\"λ\\n\\\"\"},false]")
