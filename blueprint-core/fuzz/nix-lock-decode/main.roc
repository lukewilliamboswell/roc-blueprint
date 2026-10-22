# Mutate Nix lock authority text and the native lock JSON Nix writes.
app [target] {
	core: "../../main.roc",
	nix: "../../../blueprint-nix/main.roc",
	pf: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import pf.Fuzz
import core.Layout
import core.Spec
import nix.Locks

## `Locks.decode` over authority text and `Locks.from_nix` over native lock
## JSON must return a result, never crash or hang. A Lock that `decode`
## accepts must `encode` to text that decodes to the same value, and so must
## what `from_nix` accepts, before and after its local trees are recorded.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) => {
			match Locks.decode(text) {
				Ok(locks) => round_trip(locks, "decoded")
				Err(_) => {}
			}
			match Locks.from_nix(project, layout, text) {
				Ok(locks) => {
					round_trip(locks, "resolved")
					match locks.with_trees(layout, [{ path: "/project/assets", digest: "sha256:${"1".repeat(64)}" }]) {
						Ok(recorded) => round_trip(recorded, "recorded")
						Err(message) => crash "resolved Lock has no place for its local tree: ${message}"
					}
				}
				Err(_) => {}
			}
			Fuzz.keep
		}
	}

round_trip : Locks, Str -> {}
round_trip = |locks, what|
	if Locks.decode(Locks.encode(locks)) != Ok(locks) {
		crash "${what} Lock did not survive a re-encode"
	}

## The project and layout of blueprint-nix/TestData.roc, which the package
## does not export: one Nix package source and one local build source.
layout : Layout
layout = Layout.{ project_root: "/project", workspace: "/work", generated_root: "/generated", lock_path: "/authority/inputs.lock" }

library : Spec.Build
library = { name: "library", environment: "builder", inputs: ["assets"], needs: [], run: ["python3", "build.py"], output: "dist/library" }

project : Spec
project = Spec.{
	resolvers: [{ provider: "nix", inputs: ["assets"] }],
	executors: [{ name: "native", provider: "nix", source: "default" }],
	build_executors: [{ build: "app", executor: "native" }, { build: "library", executor: "native" }],
	source_files: [],
	build_files: [],
	format: Spec.current_format,
	name: "plan fixture",
	systems: ["x86_64-linux"],
	sources: [{ name: "default", provider: { name: "nix", version: 1, ref: "github:NixOS/nixpkgs/nixos-unstable" } }],
	inputs: [],
	environments: [{ name: "builder", parents: [], tools: [{ source: "default", name: "python3" }], overlays: [] }],
	system_tools: [],
	commands: [],
	configured_tools: [],
	roc_packages: [],
	programs: [],
	environment_programs: [],
	expects: [],
	shells: [{ name: "default", environment: "builder" }],
	tasks: [{ name: "check", environment: "builder", run: ["python3", "check.py", "configured argument"] }],
	build_sources: [{ name: "assets", ref: "path:./assets" }],
	builds: [{ ..library, name: "app", needs: ["library"], output: "dist/app", run: ["python3", "build.py", "", "two words", "line\nbreak", "$HOME"] }, library],
	workflows: [],
	requires_: ["sources", "builds"],
	raw: [],
	extensions: [],
}

target = Fuzz.target_with({
	name: "nix-lock-decode",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
