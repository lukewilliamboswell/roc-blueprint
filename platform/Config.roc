import EnvName
import FlakeRef
import Tool

## The types a `Blueprint.roc` `config` is made of.
Config :: [].{

	## One top-level blueprint setting.
	Setting : [
		Name(Str),
		Systems(List([Aarch64Darwin, Aarch64Linux, X86_64Darwin, X86_64Linux])),
		Overlay(FlakeRef),
		Shell(EnvName, List(ShellSetting)),
	]

	## One setting inside a `Shell`.
	ShellSetting : [Tools(List(Tool))]
}
