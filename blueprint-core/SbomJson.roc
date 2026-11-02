import JsonData

## SBOM payload budget and depth guard, separate from small authority JSON.
SbomJson := [].{
	max_bytes : U64
	max_bytes = 16 * 1024 * 1024

	within_bounds : Str -> Bool
	within_bounds = |text| {
		if text.to_utf8().len() > max_bytes {
			return False
		}
		var $depth = 0.U64
		var $quoted = False
		var $escaped = False
		for byte in text.to_utf8() {
			if $quoted {
				if $escaped {
					$escaped = False
				} else if byte == '\\' {
					$escaped = True
				} else if byte == '"' {
					$quoted = False
				}
			} else if byte == '"' {
				$quoted = True
			} else if byte == '{' or byte == '[' {
				$depth = $depth + 1
				if $depth > 64 {
					return False
				}
			} else if byte == '}' or byte == ']' {
				if $depth == 0 {
					return False
				}
				$depth = $depth - 1
			}
		}
		$depth == 0 and !$quoted
	}

	decode : Str -> Try(JsonData, JsonData.Error)
	decode = |text| {
		if !within_bounds(text) {
			return Err(LimitExceeded("SBOM JSON exceeds its byte budget or depth 64"))
		}
		JsonData.decode_bounded(text, JsonData.documents, max_bytes)
	}

	encode : JsonData -> Try(Str, JsonData.Error)
	encode = |value| {
		text = JsonData.encode_bounded(value, JsonData.documents, max_bytes)?
		if !within_bounds(text) {
			return Err(LimitExceeded("SBOM JSON exceeds its byte budget or depth 64"))
		}
		Ok(text)
	}
}
