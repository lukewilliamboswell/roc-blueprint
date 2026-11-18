# Mutate build record text; whatever parses must survive a re-render unchanged.
app [target] {
	core: "../../main.roc",
	entropy: "../entropy.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.7.0/HBigHQhVZWEF2EkLxpYK35u8P6UNsAmPYxpNFTxXK1Br.tar.zst",
}

import pf.Fuzz
import entropy.EntropyTarget
import core.BuildModel

## `BuildModel.parse_record` must return a result, never crash or hang, for any
## text; and whatever it accepts must `render_record` to text that parses to
## the same record.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) =>
			match BuildModel.parse_record(text) {
				Ok(record) => {
					match BuildModel.render_record(record) {
						Ok(rendered) =>
							if BuildModel.parse_record(rendered) != Ok(record) {
								crash "accepted build record did not survive a re-render"
							}
						Err(message) => crash "accepted build record was refused on render: ${message}"
					}
					Fuzz.keep
				}
				Err(_) => Fuzz.keep
			}
	}

target = EntropyTarget.target_with({
	name: "build-record-parse",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
