import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import core.Lock
import core.Project
import nix.LockJson
import nix.Locks
import ../stubs/StubTool
import Integrity
import Script

## What the tests of the real `./blueprint` against stubbed tools share: a
## temporary directory holding the stub tool under the names a test asks for,
## running the CLI with an exact environment, and reading what the stubs
## recorded. Nothing here goes through a shell.
CliHarness := [].{

	## One test run: the repository, the CLI under test, the real compiler and
	## a temporary directory with the installed stubs in `bin`.
	Bench : {
		root : Str,
		blueprint : Str,
		work : Str,
		bin : Str,
		roc : Str,
		roc_version : Str,
		env : List((OsStr, OsStr)),
	}

	## A finished command. Its exit code is data: many cases expect a failure.
	Outcome : { code : I32, stdout : Str, stderr : Str }

	## Start a run from the repository root: find `./blueprint` and the
	## compiler `ROC` names (default `roc`), build `scripts/stubs/tool.roc` once
	## and install it in a new temporary directory under each of `names`.
	open! : Path, Str, List(Str) => Try(Bench, _)
	open! = |repository, prefix, names| {
		root = Path.to_str(Path.canonicalize!(repository)?)?
		blueprint = "${root}/blueprint"
		if !(Path.is_file!(Path.utf8(blueprint)) ?? False) {
			return Script.fail!("./blueprint is missing; build it with `roc build blueprint-cli/main.roc --output=./blueprint`")
		}
		env = Env.dict!()
		search = Env.var_str!(OsStr.from_str("PATH")) ?? ""
		roc = match which!(Env.var_str!(OsStr.from_str("ROC")) ?? "roc", search) {
			Ok(found) => found
			Err(_) => return Script.fail!("Roc compiler not found")
		}
		roc_version = succeed!({ program: roc, args: ["version"], cwd: root, env }, "roc version")?.stdout
		work = Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!(prefix)?)?)?
		bin = "${work}/bin"
		prepared = prepare!({ root, work, bin, roc, env }, names)
		if prepared.is_err() {
			_ = Path.delete_all!(Path.utf8(work))
		}
		prepared?
		Ok({ root, blueprint, work, bin, roc, roc_version, env })
	}

	## Remove the temporary directory, whatever a case left in it.
	close! : Bench => {}
	close! = |bench| {
		_ = Cmd.new_str("chmod").args_str(["-R", "u+w", "--", bench.work]).run!()
		_ = Path.delete_all!(Path.utf8(bench.work))
		{}
	}

	## Install the stub tool in `directory` under each of `names`.
	install! : Bench, Str, List(Str) => Try({}, _)
	install! = |bench, directory, names| {
		Path.create_all!(Path.utf8(directory))?
		for name in names {
			if StubTool.role(name).is_err() {
				return Script.fail!("the stub tool has no role called ${name}")
			}
			Path.copy!(Path.utf8("${bench.work}/stub-tool"), Path.utf8("${directory}/${name}"))?
		}
		Ok({})
	}

	## `env` with each named variable set to its new value.
	setting : List((OsStr, OsStr)), List((Str, Str)) -> List((OsStr, OsStr))
	setting = |env, changes|
		changes.fold(
			env,
			|kept, change|
				match change {
					(name, value) => unsetting(kept, [name]).append((OsStr.from_str(name), OsStr.from_str(value)))
				},
		)

	## `env` with none of the named variables.
	unsetting : List((OsStr, OsStr)), List(Str) -> List((OsStr, OsStr))
	unsetting = |env, names|
		env.keep_if(
			|entry|
				match entry {
					(name, _) => !names.contains(OsStr.display(name))
				},
		)

	## Run a program with exactly `env`, capturing its output. It gets a minute.
	invoke! : { program : Str, args : List(Str), cwd : Str, env : List((OsStr, OsStr)) } => Try(Outcome, _)
	invoke! = |call| {
		ran = command(call).run!()
		finished!(ran, describe(call))
	}

	## Start a program with exactly `env`; `finish!` waits for it.
	start! : { program : Str, args : List(Str), cwd : Str, env : List((OsStr, OsStr)) } => Try(Cmd.Child, _)
	start! = |call|
		match command(call).stdout(Capture).stderr(Capture).manage_tree(True).spawn!() {
			Ok(child) => Ok(child)
			Err(_) => Script.fail!("could not start ${describe(call)}")
		}

	## Wait for a started program and return its output.
	finish! : Cmd.Child, Str => Try(Outcome, _)
	finish! = |child, what| finished!(child.wait!(), what)

	## Run `./blueprint`, printing a `RUN` line first.
	blueprint! : Bench, Str, List(Str), List((OsStr, OsStr)) => Try(Outcome, _)
	blueprint! = |bench, cwd, args, env| {
		Stdout.line!("RUN  blueprint ${Str.join_with(args, " ")}")?
		invoke!({ program: bench.blueprint, args, cwd, env })
	}

	## Fail the script unless `holds`.
	check! : Bool, Str => Try({}, _)
	check! = |holds, message| if holds Ok({}) else Script.fail!(message)

	## Fail unless a command ended with `code`, showing what it printed.
	exited! : Outcome, I32, Str => Try({}, _)
	exited! = |outcome, code, what|
		check!(
			outcome.code == code,
			"${what} exited with code ${outcome.code.to_str()}, expected ${code.to_str()}:\n${outcome.stdout}${outcome.stderr}",
		)

	## Fail unless `text` contains `expected`, showing the text.
	contains! : Str, Str, Str => Try({}, _)
	contains! = |text, expected, what|
		check!(text.contains(expected), "${what} does not contain ${Str.inspect(expected)}:\n${text}")

	## Fail unless two lists of recorded invocations are equal, showing both.
	same_calls! : List(List(Str)), List(List(Str)), Str => Try({}, _)
	same_calls! = |actual, expected, what|
		check!(actual == expected, "${what}:\n  recorded ${Str.inspect(actual)}\n  expected ${Str.inspect(expected)}")

	## The invocations recorded in a directory, in the order they started, or
	## none when no stub ran there.
	calls! : Str => Try(List(List(Str)), _)
	calls! = |directory| {
		var $calls = []
		for name in names!(directory)?.sort_with(Project.bytewise) {
			text = Path.read_utf8!(Path.utf8("${directory}/${name}"))?
			match StubTool.parse_record(text) {
				Ok(argv) => {
					$calls = $calls.append(argv)
				}
				Err(message) => return Script.fail!("${directory}/${name} is not a stub record: ${message}")
			}
		}
		Ok($calls)
	}

	## Forget the invocations recorded in a directory.
	forget! : Str => Try({}, _)
	forget! = |directory|
		if Path.is_dir!(Path.utf8(directory)) ?? False {
			Path.delete_all!(Path.utf8(directory))
		} else {
			Ok({})
		}

	## The entry names of a directory, or none when it does not exist.
	names! : Str => Try(List(Str), _)
	names! = |directory| {
		if !(Path.is_dir!(Path.utf8(directory)) ?? False) {
			return Ok([])
		}
		var $names = []
		for entry in Path.list!(Path.utf8(directory))? {
			$names = $names.append(Path.display(entry).split_on("/").last() ?? "")
		}
		Ok($names)
	}

	## Whether anything, even a dangling link, has this name.
	present! : Str => Bool
	present! = |path| Path.type!(Path.utf8(path)).is_ok()

	## Run a coreutils program that must succeed: `ln`, `mkfifo`, `chmod`.
	## basic-cli has none of these operations.
	tool! : List(Str) => Try({}, _)
	tool! = |argv|
		match argv {
			[program, .. as args] =>
				match Cmd.new_str(program).args_str(args).run!() {
					Ok({ status: Exited(0), .. }) => Ok({})
					_ => Script.fail!("${Str.join_with(argv, " ")} failed")
				}

			[] => Ok({})
		}

	## What `stat -c format` prints for a file: basic-cli reports neither an
	## inode number nor a mode, and a link count not at all.
	stat! : Str, Str => Try(Str, _)
	stat! = |format, file|
		match Cmd.new_str("stat").args_str(["-c", format, "--", file]).run!() {
			Ok({ status: Exited(0), stdout_bytes, .. }) => Ok(Str.from_utf8_lossy(stdout_bytes).trim())
			_ => Script.fail!("stat -c ${format} -- ${file} failed")
		}

	## A file as an observer would know it: its bytes, its inode and when it was
	## last modified, to the nanosecond. Equal values mean it was not rewritten,
	## not even with the same bytes. An absent file is `absent`.
	identity! : Str => Try(Str, _)
	identity! = |file| {
		if !present!(file) {
			return Ok("absent")
		}
		bytes = Path.read_bytes!(Path.utf8(file))?
		Ok("${Integrity.digest(bytes)} ${stat!("%i %y", file)?}")
	}

	## Where a program name resolves on a search path, with links followed.
	which! : Str, Str => Try(Str, [NotFound])
	which! = |name, search| {
		candidates = if name.contains("/") [name] else search.split_on(":").keep_if(|part| !part.is_empty()).map(|part| "${part}/${name}")
		for candidate in candidates {
			file = Path.utf8(candidate)
			if (Path.is_file!(file) ?? False) and (Path.is_executable!(file) ?? False) {
				match Path.canonicalize!(file) {
					Ok(resolved) => return Ok(Path.display(resolved))
					Err(_) => {}
				}
			}
		}
		Err(NotFound)
	}

	## The native lock graph the Nix provider keeps in a Blueprint.lock.
	authority_graph : Str -> Try(LockJson, Str)
	authority_graph = |text| {
		lock = Lock.parse(text).map_err(|_| "not a Blueprint lock")?
		pins = Lock.hint(lock, "nix").map_err(|_| "the lock has no nix hint")?
		Locks.from_value(Locks.attr(pins, "graph")?)
	}

	## The revision a native lock graph pins a node to.
	locked_rev : LockJson, Str -> Try(Str, Str)
	locked_rev = |graph, node|
		LockJson.string(
			LockJson.field(LockJson.field(LockJson.field(LockJson.field(graph, "nodes")?, node)?, "locked")?, "rev")?,
		)

	## A version as `blueprint --version` prints it: `1.2.3` or `1.2.3-rc1`,
	## then only white space.
	is_version : Str -> Bool
	is_version = |output| {
		digits = |part| !part.is_empty() and part.to_utf8().all(|byte| byte >= '0' and byte <= '9')
		text = output.trim()
		no_space = output.starts_with(text) and !text.to_utf8().any(|byte| byte == ' ' or byte == '\t' or byte == '\n')
		match text.split_on(".") {
			[major, minor, .. as rest] =>
				match Str.join_with(rest, ".").split_on("-") {
					[patch] => no_space and digits(major) and digits(minor) and digits(patch)
					[patch, .. as suffix] => no_space and digits(major) and digits(minor) and digits(patch) and !Str.join_with(suffix, "-").is_empty()
					[] => False
				}

			_ => False
		}
	}
}

Call : { program : Str, args : List(Str), cwd : Str, env : List((OsStr, OsStr)) }

command : Call -> Cmd
command = |call|
	Cmd.new_str(call.program).args_str(call.args).cwd(Path.utf8(call.cwd)).clear_envs().envs(call.env).timeout_ms(60000)

describe : Call -> Str
describe = |call| Str.join_with([call.program].concat(call.args), " ")

finished! : Try(Cmd.RunOutput, Cmd.RunErr), Str => Try(CliHarness.Outcome, _)
finished! = |ran, what|
	match ran {
		Ok({ status, stdout_bytes, stderr_bytes }) => {
			code = match status {
				Exited(exit_code) => exit_code
				Signaled(signal) => 128 + signal
			}
			Ok({ code, stdout: Str.from_utf8_lossy(stdout_bytes), stderr: Str.from_utf8_lossy(stderr_bytes) })
		}
		Err(Timeout(_)) => Script.fail!("${what} did not finish in a minute")
		Err(_) => Script.fail!("could not run ${what}")
	}

succeed! : Call, Str => Try(CliHarness.Outcome, _)
succeed! = |call, what| {
	outcome = CliHarness.invoke!(call)?
	if outcome.code != 0 {
		return Script.fail!("${what} exited with code ${outcome.code.to_str()}:\n${outcome.stdout}${outcome.stderr}")
	}
	Ok(outcome)
}

## Build the stub tool once and install it under the names asked for.
prepare! : { root : Str, work : Str, bin : Str, roc : Str, env : List((OsStr, OsStr)) }, List(Str) => Try({}, _)
prepare! = |run, names| {
	Stdout.line!("RUN  roc build scripts/stubs/tool.roc")?
	_ = succeed!(
		{ program: run.roc, args: ["build", "scripts/stubs/tool.roc", "--output=${run.work}/stub-tool"], cwd: run.root, env: run.env },
		"roc build scripts/stubs/tool.roc",
	)?
	Path.create_all!(Path.utf8(run.bin))?
	for name in names {
		Path.copy!(Path.utf8("${run.work}/stub-tool"), Path.utf8("${run.bin}/${name}"))?
	}
	Ok({})
}

expect CliHarness.is_version("0.4.0-rc2\n") and CliHarness.is_version("1.2.3") and CliHarness.is_version("10.20.30  \n")
expect ["", "1.2", "1.2.x", "v1.2.3", "1.2.3-", "1.2.3 extra", "1.2.3-rc 1", " 1.2.3", "blueprint 1.2.3"].all(|output| !CliHarness.is_version(output))

expect {
	env = [(OsStr.from_str("PATH"), OsStr.from_str("/bin")), (OsStr.from_str("ROC"), OsStr.from_str("roc"))]
	changed = CliHarness.setting(env, [("ROC", "/stub/roc"), ("NEW", "1")])
	changed == [(OsStr.from_str("PATH"), OsStr.from_str("/bin")), (OsStr.from_str("ROC"), OsStr.from_str("/stub/roc")), (OsStr.from_str("NEW"), OsStr.from_str("1"))]
		and CliHarness.unsetting(changed, ["ROC", "ABSENT"]) == [(OsStr.from_str("PATH"), OsStr.from_str("/bin")), (OsStr.from_str("NEW"), OsStr.from_str("1"))]
}

sample_authority : Str
sample_authority = Lock.to_str(
	Lock.{
		format: Lock.current_format,
		intent: Lock.empty_intent,
		sources: [],
		hints: [{ provider: "nix", value: Locks.to_value(LockJson.decode("{\"graph\":{\"nodes\":{\"default\":{\"locked\":{\"rev\":\"abc\"}}},\"version\":7}}") ?? LockJson.Null) }],
	},
)

expect CliHarness.authority_graph(sample_authority).map_ok(|graph| CliHarness.locked_rev(graph, "default")) == Ok(Ok("abc"))
expect CliHarness.authority_graph(sample_authority).map_ok(|graph| CliHarness.locked_rev(graph, "absent").is_err()) == Ok(True)
expect CliHarness.authority_graph("((format ((major 1) (minor 0))))") == Err("the lock has no nix hint")
expect CliHarness.authority_graph("{}") == Err("not a Blueprint lock")
