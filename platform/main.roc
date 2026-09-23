## A platform whose apps are pure configuration. A Kaifile provides `config`,
## a list of settings, and the platform prints the flake it describes.
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
## `Tool`, `FlakeRef` or `EnvName`. The flake itself is rendered at compile
## time, so `roc check Kaifile.roc` reports every problem before anything runs.
platform ""
	requires {
		config : List(Config.Setting)
	}
	exposes [Config, EnvName, FlakeRef, Tool]
	packages {
		blueprint: "../packages/blueprint/main.roc",
		blueprint_nix: "../packages/blueprint-nix/main.roc",
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
import Flake
import Host
import Tool
import FlakeRef
import EnvName

## Evaluated at compile time, because it depends only on constants.
rendered : Str
rendered = or_crash(config.fold(Flake.new("project"), apply).render())

or_crash : Try(Str, Flake.Error) -> Str
or_crash = |result|
	match result {
		Ok(source) => source
		Err(errors) => crash "Invalid Kaifile: ${Str.inspect(errors)}"
	}

apply : Flake, Config.Setting -> Flake
apply = |flake, setting|
	match setting {
		Name(name) => flake.named(name)
		Systems(systems) => flake.for_systems(systems)
		Overlay(ref) => flake.overlay(ref.to_str())
		Shell(env, settings) => flake.env(env.to_str(), shell_tools(settings))
	}

shell_tools : List(Config.ShellSetting) -> List(Str)
shell_tools = |settings| settings.fold([], add_tools)

add_tools : List(Str), Config.ShellSetting -> List(Str)
add_tools = |acc, setting|
	match setting {
		Tools(tools) => tools.fold(acc, |names, tool| names.append(tool.to_str()))
	}

main_for_host! : List(Str) => I32
main_for_host! = |_args|
	match Host.stdout_line!(rendered) {
		Ok({}) => 0
		Err(_) => 1
	}
