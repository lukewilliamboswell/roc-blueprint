## A platform whose apps are pure configuration. A `Blueprint.roc` provides
## `config`, a list of settings; the platform validates it and prints the
## blueprint IR as an S-expression, which the `blueprint` CLI turns into a
## working environment.
##
## ```roc
## app [config] { pf: platform "platform/main.roc" }
##
## config = [
## 	Name("my-project"),
## 	Shell("default", [Tools(["git", "python3"])]),
## ]
## ```
##
## Every quoted value is checked as it compiles, through the `from_quote` of
## `Tool`, `FlakeRef` or `EnvName`. The IR itself is built at compile time,
## so `roc check Blueprint.roc` reports every problem before anything runs.
platform ""
	requires {
		config : List(Config.Setting)
	}
	exposes [Config, EnvName, FlakeRef, Tool]
	packages {
		ir: "../ir/main.roc",
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
import ir.Ir

## Evaluated at compile time, because it depends only on constants.
rendered : Str
rendered = or_crash(Lower.lower(config)).to_str()

or_crash : Try(Ir, List(Lower.Error)) -> Ir
or_crash = |result|
	match result {
		Ok(ir) => ir
		Err(errors) => crash "Invalid Blueprint.roc: ${Str.inspect(errors)}"
	}

main_for_host! : List(Str) => I32
main_for_host! = |_args|
	match Host.stdout_line!(Str.drop_suffix(rendered, "\n")) {
		Ok({}) => 0
		Err(_) => 1
	}
