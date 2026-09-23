import EnvName
import FlakeRef
import InputName
import System
import TaskName
import Tool
import Val

## The types a `Blueprint.roc` `config` is made of.
Config :: [].{

	## One top-level blueprint setting.
	##
	## - `Packages(name, ref)` declares a package set that tools can name as
	##   "name#attr.path". "nixpkgs" (nixos-unstable) is declared by default;
	##   `Packages("nixpkgs", ...)` replaces it.
	## - `Input(name, ref)` declares any other flake input, for `Raw` values.
	## - `Overlay(ref)` applies a flake's default overlay to the package sets.
	## - `Custom(kind, name, value)` is extension data for a consumer that
	##   knows `kind`; `Raw(backend, target, value)` is passed to one backend
	##   verbatim (for nix: target "shell:<name>" or "flake").
	Setting : [
		Name(Str),
		Systems(List(System)),
		Packages(InputName, FlakeRef),
		Input(InputName, FlakeRef),
		Overlay(FlakeRef),
		Shell(EnvName, List(ShellSetting)),
		Task(TaskName, List(TaskSetting)),
		Custom(Str, Str, Val),
		Raw(Str, Str, Val),
	]

	## One setting inside a `Shell`.
	ShellSetting : [Tools(List(Tool))]

	## One setting inside a `Task`. `Run` (required, once) is the command and
	## its arguments; `In` (optional) names the shell it runs in, which
	## defaults to "default".
	TaskSetting : [Run(List(Str)), In(EnvName)]
}
