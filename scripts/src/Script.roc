import cli.Cmd
import cli.OsStr
import cli.Stderr
import cli.Stdout

## Shared command and terminal-output helpers for repository scripts.
Script := [].{

	## A command-line program. Arguments are passed as a list; no shell is involved.
	Command := { base : Cmd, program : Str }.{

		## Print a `RUN` line, append the arguments and run the command with
		## inherited output. A non-zero exit is an error.
		run! : Command, List(Str) => Try({}, _)
		run! = |self, args| {
			Stdout.line!("RUN  ${Str.join_with([self.program].concat(args), " ")}")?
			self.base.args(args.map(OsStr.from_str)).exec_cmd!()
		}
	}

	## Construct a script command from a program name or path.
	command : Str -> Command
	command = |program| Command.{ base: Cmd.new(OsStr.from_str(program)), program }

	## Print a `PASS` result followed by its description.
	pass! : Str => Try({}, _)
	pass! = |message| Stdout.line!("PASS ${message}")

	## Print an informational label followed by its description.
	info! : Str, Str => Try({}, _)
	info! = |label, message| Stdout.line!("${label} ${message}")

	## Print a script error and return `ScriptFailed`.
	fail! : Str => Try(_, [ScriptFailed])
	fail! = |message| {
		_ = Stderr.line!("error: ${message}")
		Err(ScriptFailed)
	}
}
