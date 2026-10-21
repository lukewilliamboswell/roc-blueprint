# Mutate lock snapshot JSON; whatever parses must re-encode to a fixed point.
app [target] {
	core: "../../main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
import core.JsonData
import core.LockSnapshot

## `JsonData.decode` and `LockSnapshot.parse_json` must return a result, never
## crash or hang, for any text. Any JSON value accepted must encode to text
## that decodes to the same value, with its object fields sorted too. Any
## report accepted must re-encode, parse to the same snapshot, and re-encode
## to the same bytes when its canonical encoding fits the output bound.
## Escaping control bytes can expand valid bounded input; report encoding also
## adds a newline. Only LimitExceeded is legitimate for those output bounds.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) => {
			match JsonData.decode(text) {
				Ok(value) => {
					match JsonData.encode(value) {
						Ok(encoded) => if JsonData.decode(encoded) != Ok(value) {
							crash "accepted JSON did not survive a re-encode"
						}
						Err(LimitExceeded(_)) => {}
						Err(_) => crash "accepted JSON could not be encoded"
					}
					match JsonData.encode(JsonData.sorted(value)) {
						Ok(encoded) => if JsonData.decode(encoded) != Ok(JsonData.sorted(value)) {
							crash "sorted JSON did not survive a re-encode"
						}
						Err(LimitExceeded(_)) => {}
						Err(_) => crash "accepted JSON could not be encoded once sorted"
					}
				}
				Err(_) => {}
			}
			match LockSnapshot.parse_json(text) {
				Ok(snapshot) =>
					match LockSnapshot.to_json(snapshot) {
						Ok(report) => {
							match LockSnapshot.parse_json(report) {
								Ok(again) => {
									if again != snapshot {
										crash "accepted report parsed to a different snapshot after a re-encode"
									}
									if LockSnapshot.to_json(again) != Ok(report) {
										crash "re-encoded report is not a fixed point"
									}
								}
								Err(_) => crash "re-encoded report did not parse"
							}
							Fuzz.keep
						}
						Err(LimitExceeded(_)) => Fuzz.keep
						Err(_) => crash "accepted report could not be encoded"
					}
				Err(_) => Fuzz.keep
			}
		}
	}

target = Fuzz.target_with({
	name: "lock-snapshot-parse",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
