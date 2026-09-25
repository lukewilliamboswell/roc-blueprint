# Mutate Lock text; whatever parses must survive a re-encode unchanged.
app [target] {
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst",
	core: "../../main.roc",
}

import pf.Fuzz
import core.Lock

## `Lock.parse` must return a result, never crash or hang, for any text; and
## whatever it accepts must re-encode to text that parses to the same Lock.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) =>
			match Lock.parse(text) {
				Ok(lock) => {
					if Lock.parse(lock.to_str()) != Ok(lock) {
						crash "accepted Lock did not survive a re-encode"
					}
					Fuzz.keep
				}
				Err(_) => Fuzz.keep
			}
		}

target = Fuzz.target_with({
	name: "lock-parse",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
