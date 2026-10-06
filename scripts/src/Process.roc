import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import Script

## Child processes whose exit code and output are data, for scripts that
## compare them. Programs are run by argument list; no shell is involved.
Process := [].{
	Outcome : { code : I32, stdout : Str, stderr : Str }

	## The compiler under test: `$ROC`, or `roc` on `PATH`.
	roc! : () => Str
	roc! = ||
		match Env.var_str!(OsStr.from_str("ROC")) {
			Ok(value) => if value.is_empty() "roc" else value
			Err(_) => "roc"
		}

	## A command and how to show it: the program and its arguments.
	Job : { cmd : Cmd, label : Str }

	## A program with string arguments, run in `directory`.
	command : Str, List(Str), Str -> Job
	command = |program, args, directory| {
		cmd: Cmd.new_str(program).args_str(args).cwd(Path.utf8(directory)),
		label: Str.join_with([program.split_on("/").last() ?? program].concat(args), " "),
	}

	## The same command with these environment variables added.
	with_env : Job, List((Str, Str)) -> Job
	with_env = |job, variables| { ..job, cmd: job.cmd.envs_str(variables) }

	outcome : Cmd.RunOutput -> Outcome
	outcome = |output| {
		code = match output.status {
			Exited(exit_code) => exit_code
			Signaled(signal) => 128 + signal
		}
		{ code, stdout: Str.from_utf8_lossy(output.stdout_bytes), stderr: Str.from_utf8_lossy(output.stderr_bytes) }
	}

	## Run to completion with both streams captured. A program that cannot be
	## started is an error; any exit code is an `Outcome`.
	capture! : Job => Try(Outcome, _)
	capture! = |job|
		match Cmd.run!(job.cmd) {
			Ok(output) => Ok(outcome(output))
			Err(_) => Script.fail!("could not run ${job.label}")
		}

	## `capture!` after printing a `RUN` line.
	traced! : Job => Try(Outcome, _)
	traced! = |job| {
		Stdout.line!("RUN  ${job.label}")?
		capture!(job)
	}

	## The outcome of a command that must exit 0; its output explains a failure.
	succeed! : Job => Try(Outcome, _)
	succeed! = |job| {
		result = traced!(job)?
		if result.code != 0 {
			return Script.fail!("${result.stdout}${result.stderr}\n${job.label} exited with code ${result.code.to_str()}")
		}
		Ok(result)
	}

	## Run with the terminal's own output and input; a non-zero exit is an error.
	passthrough! : Job => Try({}, _)
	passthrough! = |job| {
		Stdout.line!("RUN  ${job.label}")?
		match Cmd.exec_exit_code!(job.cmd) {
			Ok(0) => Ok({})
			Ok(code) => Script.fail!("${job.label} exited with code ${code.to_str()}")
			Err(_) => Script.fail!("could not run ${job.label}")
		}
	}

	## Start a command with both streams captured, to be waited for later.
	spawn! : Job => Try(Cmd.Child, _)
	spawn! = |job| {
		captured = Cmd.stderr(Cmd.stdout(job.cmd, Capture), Capture)
		# Not `captured.spawn!()`: inside this module that names this function.
		match Cmd.spawn!(captured) {
			Ok(child) => Ok(child)
			Err(_) => Script.fail!("could not start ${job.label}")
		}
	}

	## Start every command, then wait for each in order: the commands run
	## together and their outcomes come back in the order given.
	together! : List(Job) => Try(List(Outcome), _)
	together! = |jobs| wait_each!(spawn_each!(jobs, [])?, [])

	spawn_each! : List(Job), List(Cmd.Child) => Try(List(Cmd.Child), _)
	spawn_each! = |jobs, started|
		match jobs {
			[] => Ok(started)
			[first, .. as rest] => spawn_each!(rest, started.append(spawn!(first)?))
		}

	wait_each! : List(Cmd.Child), List(Outcome) => Try(List(Outcome), _)
	wait_each! = |children, finished|
		match children {
			[] => Ok(finished)
			[first, .. as rest] =>
				match first.wait!() {
					Ok(output) => wait_each!(rest, finished.append(outcome(output)))
					Err(_) => Script.fail!("could not wait for a child process")
				}
		}

	## Whether `directory` holds an executable called `name`, directly or
	## through a symbolic link.
	holds_program! : Str, Str => Bool
	holds_program! = |directory, name|
		match Path.canonicalize!(Path.utf8("${directory}/${name}")) {
			Ok(real) => !directory.is_empty() and (Path.is_file!(real) ?? False) and (Path.is_executable!(real) ?? False)
			Err(_) => False
		}

	## The directories of `PATH`, in order.
	search_path! : () => List(Str)
	search_path! = || (Env.var_str!(OsStr.from_str("PATH")) ?? "").split_on(":").keep_if(|directory| !directory.is_empty())

	## The directories among these that hold an executable called `name`.
	holding! : List(Str), Str => List(Str)
	holding! = |directories, name| {
		var $found = []
		for directory in directories {
			if holds_program!(directory, name) {
				$found = $found.append(directory)
			}
		}
		$found
	}

	## Fail with `message` unless `holds`.
	check! : Bool, Str => Try({}, _)
	check! = |holds, message| if holds Ok({}) else Script.fail!(message)

	## `to` as seen from the directory `from`; both absolute. Roc refuses an
	## absolute platform path.
	relative : Str, Str -> Str
	relative = |from, to| {
		parts = |text| text.split_on("/").keep_if(|part| !part.is_empty())
		start = parts(from)
		end = parts(to)
		var $shared = 0
		while $shared < start.len() and $shared < end.len() and start.get($shared) == end.get($shared) {
			$shared = $shared + 1
		}
		Str.join_with(start.drop_first($shared).map(|_| "..").concat(end.drop_first($shared)), "/")
	}

	## The lines of `text` that are not empty.
	lines : Str -> List(Str)
	lines = |text| text.split_on("\n").keep_if(|line| !line.is_empty())

	## The strings in byte order, so a directory listing has one order.
	sorted : List(Str) -> List(Str)
	sorted = |items| items.sort_with(|left, right| compare_bytes(left.to_utf8(), right.to_utf8()))

	## The slices of `items` holding at most `size` items each, in order.
	batches : List(a), U64 -> List(List(a))
	batches = |items, size| {
		var $batches = []
		var $rest = items
		while !$rest.is_empty() {
			$batches = $batches.append($rest.take_first(size))
			$rest = $rest.drop_first(size)
		}
		$batches
	}
}

compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |left, right|
	match (left, right) {
		([a, .. as left_rest], [b, .. as right_rest]) =>
			if a < b Before else if a > b After else compare_bytes(left_rest, right_rest)
		([], []) => Same
		([], _) => Before
		(_, []) => After
	}

expect Process.relative("/tmp/work/project", "/home/me/repo/blueprint-platform/main.roc") == "../../../home/me/repo/blueprint-platform/main.roc"
expect Process.relative("/repo/tests/project", "/repo/blueprint-platform/main.roc") == "../../blueprint-platform/main.roc"
expect Process.relative("/repo", "/repo/blueprint-platform/main.roc") == "blueprint-platform/main.roc"
expect Process.lines("a\n\nb\n") == ["a", "b"]
expect Process.batches([1, 2, 3, 4, 5], 2) == [[1, 2], [3, 4], [5]]
expect Process.batches([1].drop_first(1), 2).is_empty()
expect Process.outcome({ status: Exited(3), stdout_bytes: "out".to_utf8(), stderr_bytes: "err".to_utf8() }) == { code: 3, stdout: "out", stderr: "err" }
expect Process.outcome({ status: Signaled(9), stdout_bytes: [], stderr_bytes: [] }).code == 137
expect Process.command("/repo/blueprint", ["run", "hello"], "/tmp").label == "blueprint run hello"
expect Process.sorted(["b", "ab", "a", "Z", "a"]) == ["Z", "a", "a", "ab", "b"]
