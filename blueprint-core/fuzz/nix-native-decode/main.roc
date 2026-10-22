# Mutate the JSON Nix prints for derivations, builds and dev shells.
app [target] {
	core: "../../main.roc",
	nix: "../../../blueprint-nix/main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
import core.Activation
import nix.NixProvider

## `NixProvider.build_prepared`, `build_result` and `activation` must each
## return a result, never crash or hang, for any text. A prepared build that is
## accepted must have a `build_identity` ending in `.drv` under `/nix/store/`
## and no output path escaping `/nix/store/`. An accepted activation must hold
## only entries split from `PATH` and exported variables with valid names.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) => {
			match NixProvider.build_prepared(text) {
				Ok(prepared) => {
					if !prepared.build_identity.ends_with(".drv") or !in_store(prepared.build_identity) {
						crash "prepared build identity is not a derivation in the store: ${prepared.build_identity}"
					}
					if prepared.outputs.is_empty() {
						crash "prepared build has no outputs"
					}
					for output in prepared.outputs {
						if !in_store(output.path) {
							crash "prepared output ${output.name} escapes the store: ${output.path}"
						}
					}
				}
				Err(_) => {}
			}
			_ = NixProvider.build_result(text)
			match NixProvider.activation(text) {
				Ok(activation) => {
					for entry in activation.path {
						if entry.directory.is_empty() or entry.directory.contains(":") or entry.origin != "nix" {
							crash "activation has a search path entry not split from PATH: ${Str.inspect(entry.directory)}"
						}
					}
					for variable in activation.variables {
						if !Activation.valid_name(variable.name) or variable.name == "PATH" or variable.origin != "nix" {
							crash "activation exports an invalid variable: ${Str.inspect(variable.name)}"
						}
					}
				}
				Err(_) => {}
			}
			Fuzz.keep
		}
	}

## One entry directly in `/nix/store/`, not a path that leaves it.
in_store : Str -> Bool
in_store = |path| {
	name = path.drop_prefix("/nix/store/")
	path.starts_with("/nix/store/") and !name.is_empty() and name != "." and name != ".." and !name.contains("/")
}

target = Fuzz.target_with({
	name: "nix-native-decode",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
