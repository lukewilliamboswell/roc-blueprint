app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst" }

import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout

## Host tasks expose exact argv and alter later, fresh build inputs.
##
##   roc-stable task.roc -- args ARGS...   print the arguments as a JSON list
##   roc-stable task.roc -- edit           write a file the next build must see
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		["args", .. as rest] =>
			if Path.exists!("INJECTED") ?? Bool.True {
				Err(Failed("task argv was interpreted by a shell"))
			} else {
				Stdout.line!(Json.to_str(rest))
			}

		["edit"] => Path.write_bytes!("task-produced.txt", "task-generated".to_utf8().append(0).concat("bytes\n".to_utf8()))
		_ => Err(Failed("unknown fixture task"))
	}
	match result {
		Ok({}) => Ok({})
		Err(other) => {
			_ = Stderr.line!("fixture task: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}
