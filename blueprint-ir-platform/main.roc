## A platform whose apps are pure configuration. A `Blueprint.roc` provides
## `config`, a list of settings; the platform validates it and prints the
## blueprint IR as an S-expression, which the `blueprint` CLI turns into a
## working environment.
##
## ```roc
## app [config] { pf: platform "blueprint-ir-platform/main.roc" }
##
## config = [
## 	Name("my-project"),
## 	Systems(["x86_64-linux", "aarch64-darwin"]),
## 	Packages("stable", "github:NixOS/nixpkgs/nixos-24.05"),
## 	Shell("default", [Tools(["git", "python3", "stable#nodejs"])]),
## 	Task("test", [Run(["python3", "-m", "pytest"])]),
## 	Raw("nix", "shell:default", Attrs([("shellHook", Str("echo hi"))])),
## ]
## ```
##
## Tools come from "nixpkgs" (nixos-unstable unless `Packages("nixpkgs", ...)`
## overrides it) or from a set named as "set#attr.path". `Custom` and `Raw`
## take a `Val`, written with bare tags: `Str`, `Int`, `Bool`, `List` and
## `Attrs` (a list of (name, value) pairs).
##
## Every quoted value is checked as it compiles, through the `from_quote` of
## `Tool`, `System`, `FlakeRef`, `InputName`, `EnvName` or `TaskName`.
## Whole-config rules are checked when the app runs (see the TODO below).
platform ""
	requires {
		config : List(Config.Setting)
	}
	exposes [Config, EnvName, FlakeRef, InputName, System, TaskName, Tool, Val]
	packages {
		ir: "../blueprint-ir-package/main.roc",
	}
	provides { "roc_main": main_for_host! }
	hosted {
		"roc_stderr_line": Host.stderr_line!,
		"roc_stdout_line": Host.stdout_line!,
	}
	targets: {
		inputs_dir: "targets/",
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
	}

import Config
import Host
import Lower
import Tool
import FlakeRef
import EnvName
import InputName
import System
import TaskName
import Val
import ir.Ir

# TODO(compile-time-render): restore compile-time rendering once upstream is fixed.
#
# The IR should be a top-level constant so whole-config errors (duplicate
# shells, a missing Name, ...) are reported by `roc check Blueprint.roc`:
#
#     rendered : Str
#     rendered = or_crash(Lower.lower(config)).to_str()
#
# That works for `roc check` and `roc Blueprint.roc`, but `roc bundle`
# crashes on a top-level constant that depends on the app's `config`
# (segfault on nightly-2026-09-04..09-19, trap on 09-22; fixed on roc main
# at e87f3eb). The newer compilers can't yet be used because basic-cli
# 0.23.0-rc1 does not build with them (see roc-lang/basic-cli#495).
#
# Until then the IR is built when the app runs, so whole-config errors are
# reported at run time (`blueprint check` runs Blueprint.roc for that).
# Per-value checks (the `from_quote` of Tool, System, FlakeRef, ...) remain compile time.
or_crash : Try(Ir, List(Lower.Error)) -> Ir
or_crash = |result|
	match result {
		Ok(ir) => ir
		Err(errors) => crash "Invalid Blueprint.roc: ${Str.inspect(errors)}"
	}

main_for_host! : List(Str) => I32
main_for_host! = |_args|
	match Host.stdout_line!(Str.drop_suffix(or_crash(Lower.lower(config)).to_str(), "\n")) {
		Ok({}) => 0
		Err(_) => 1
	}
