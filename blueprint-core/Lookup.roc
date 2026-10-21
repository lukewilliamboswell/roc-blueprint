import Project

## Values by text key, sorted for binary search: the identifier indexes of the
## SPDX validators and reader. It stands in for a `Dict`: in the bundled SBOM
## app, `roc run` reusing cached dev-backend objects for these modules made
## `Dict.contains` miss keys just inserted (nightly-2026-10-18-1df370f and
## nightly-2026-10-20-7a8a800, on Linux and macOS alike).
Lookup := [].{
	Entry(v) : { key : Str, value : v }

	## The entries sorted by key. For a key with several entries `find`
	## returns one of them; `repeated` names those keys.
	index : List(Lookup.Entry(v)) -> List(Lookup.Entry(v))
	index = |entries| entries.sort_with(|a, b| Project.bytewise(a.key, b.key))

	find : List(Lookup.Entry(v)), Str -> Try(v, [Missing])
	find = |sorted, key| {
		var $low = 0.U64
		var $high = sorted.len()
		while $low < $high {
			middle = $low + ($high - $low) // 2
			match sorted.get(middle) {
				Ok(entry) =>
					match Project.bytewise(entry.key, key) {
						Before => {
							$low = middle + 1
						}
						After => {
							$high = middle
						}
						Same => return Ok(entry.value)
					}
				Err(_) => return Err(Missing)
			}
		}
		Err(Missing)
	}

	contains : List(Lookup.Entry(v)), Str -> Bool
	contains = |sorted, key| Lookup.find(sorted, key).is_ok()

	## The keys an index holds more than once.
	repeated : List(Lookup.Entry(v)) -> List(Str)
	repeated = |sorted| {
		var $found = []
		var $previous = Err(Missing)
		for entry in sorted {
			if $previous == Ok(entry.key) and !$found.contains(entry.key) {
				$found = $found.append(entry.key)
			}
			$previous = Ok(entry.key)
		}
		$found
	}
}

sample = Lookup.index([{ key: "b", value: 2 }, { key: "a", value: 1 }, { key: "c", value: 3 }, { key: "b", value: 4 }])

expect Lookup.find(sample, "a") == Ok(1)
expect Lookup.find(sample, "c") == Ok(3)
expect Lookup.find(sample, "b") == Ok(2) or Lookup.find(sample, "b") == Ok(4)
expect Lookup.find(sample, "d").is_err() and Lookup.find(sample, "").is_err() and Lookup.find([], "a").is_err()
expect Lookup.repeated(sample) == ["b"] and Lookup.repeated(Lookup.index([{ key: "x", value: 0 }])) == []
expect {
	keys = List.repeat("k", 300).fold([], |all, _| all.append("k${all.len().to_str()}"))
	index = Lookup.index(keys.map(|key| { key, value: key }))
	keys.all(|key| Lookup.find(index, key) == Ok(key)) and !Lookup.contains(index, "k300")
}
