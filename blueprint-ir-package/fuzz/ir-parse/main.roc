app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.0-rc1/9k2cfuAWoBfcRBRiVbriXFf1dHktoRBbieifYN7NmTHc.tar.zst", ir: "../../main.roc", roc: "nightly-2026-09-19-d025939" }

import fuzz.Fuzz
import ir.Ir

## `Ir.parse` must return a result, never crash or hang, for any text; and
## whatever it accepts must re-encode to text that parses to the same IR.
##
## The input is raw bytes read as UTF-8, so the seeds in `corpus/` are plain
## IR text the fuzzer can mutate directly.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) =>
			match Ir.parse(text) {
				Ok(ir) =>
					if Ir.parse(ir.to_str()) == Ok(ir) {
						Fuzz.keep
					} else {
						crash "accepted IR did not survive a re-encode"
					}
				Err(_) => Fuzz.keep
			}
		}

target = Fuzz.target_with({
	name: "ir-parse",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
