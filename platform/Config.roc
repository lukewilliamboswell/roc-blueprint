import EnvName
import FlakeRef
import TaskName
import Tool

## The types a `Blueprint.roc` `config` is made of.
Config :: [].{

	## One top-level blueprint setting.
	Setting : [
		Name(Str),
		Systems(List([Aarch64Darwin, Aarch64Linux, X86_64Darwin, X86_64Linux])),
		Overlay(FlakeRef),
		Shell(EnvName, List(ShellSetting)),
		Task(TaskName, List(TaskSetting)),
	]

	## One setting inside a `Shell`.
	ShellSetting : [Tools(List(Tool))]

	## One setting inside a `Task`. `Run` (required, once) is the command and
	## its arguments; `In` (optional) names the shell it runs in, which
	## defaults to "default".
	TaskSetting : [Run(List(Str)), In(EnvName)]
}
