#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
	nix: "../../blueprint-nix/main.roc",
}

import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Random
import cli.Sleep
import cli.Stderr
import cli.Stdout
import cli.Utc
import StubTool

## The one program the CLI tests put in place of every tool `blueprint` runs.
## A test builds it once and installs copies under the names in
## `StubTool.names`; each copy decides what to be from its own file name, and
## how to behave from the `STUB_*` variables below.
##
##   roc-record  record the arguments, then run `STUB_REAL_ROC` with them
##   roc-wire    `version` prints `STUB_ROC_VERSION`; `Blueprint.roc` prints `./wire.scm`
##   roc-probe   record; `version` prints `STUB_PROBE_VERSION`, exits `STUB_PROBE_STATUS`
##   roc-stable  record, then print the arguments on one line; with
##               `STUB_SHOW_EXE`, first print the file this process is, links
##               resolved. `program` is the same under another file name.
##   nix         record; `flake update [INPUT...]` writes a `flake.lock` from `STUB_NIX_FIXTURE`
##               as `STUB_NIX_MODE` says (`declared` or `local`, the latter with
##               `STUB_NIX_REV`), after waiting at `STUB_NIX_PAUSE` if set;
##               `derivation show` returns a static prepared recipe; `build` returns native JSON for that recipe; `develop` exits 23 if `STUB_NIX_FAIL`,
##               and with `STUB_NIX_RUN` runs what follows `--command`, as it is
##               found on this process's PATH
##   guix        record, exit 99
##   python3     record in the directory `STUB_PYTHON_LOG`, exit 97
##   readlink    print `STUB_READLINK`, or exit 1 without it
##
## A record is one file holding one line of JSON, in `<name>-calls/` under the
## working directory. It runs nothing through a shell.
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	executable = Env.exe_path!().map_ok(Path.display) ?? ""
	match StubTool.role(executable) {
		Ok(role) =>
			match act!(role, args) {
				Ok(0) => Ok({})
				Ok(code) => Err(Exit(code))
				Err(message) => {
					_ = Stderr.line!("stub ${executable}: ${message}")
					Err(Exit(1))
				}
			}

		Err(UnknownRole(name)) => {
			_ = Stderr.line!("stub: install this program as one of ${Str.join_with(StubTool.names, ", ")}, not ${name}")
			Err(Exit(2))
		}
	}
}

act! : StubTool.Role, List(OsStr) => Try(I32, Str)
act! = |role, args| {
	argv = args.map(OsStr.display)
	match role {
		RocRecord => {
			record!("roc-calls", argv)?
			real = variable!("STUB_REAL_ROC")?
			# There is no exec here: the compiler is a child with this process's
			# streams, and its status becomes this process's.
			ran = Cmd.new(OsStr.from_str(real)).args(args).stdin(Inherit).stdout(Inherit).stderr(Inherit).run!()
			match ran {
				Ok(Cmd.Output.{ status: Exited(code), .. }) => Ok(code)
				Ok(Cmd.Output.{ status: Signaled(signal), .. }) => Ok(128 + signal)
				Err(_) => Err("could not run ${real}")
			}
		}
		RocWire =>
			match argv {
				["version"] => written!(variable!("STUB_ROC_VERSION")?)
				["Blueprint.roc"] => written!(Path.read_utf8!(Path.utf8("wire.scm")).map_err(|_| "cannot read ./wire.scm")?)
				_ => Err("unexpected compiler arguments: ${Str.inspect(argv)}")
			}

		RocProbe => {
			record!("roc-calls", argv)?
			if argv != ["version"] {
				return Err("config ran with an unverified compiler")
			}
			_ = written!("${variable!("STUB_PROBE_VERSION")?}\n")?
			match optional!("STUB_PROBE_STATUS") {
				Ok(status) => I32.from_str(status).map_err(|_| "STUB_PROBE_STATUS is not a number: ${status}")
				Err(_) => Ok(0)
			}
		}
		Nix => {
			record!(optional!("STUB_NIX_CALLS") ?? "nix-calls", argv)?
			match argv {
				["flake", "update", "--flake", target] => flake_update!(target, [])
				["flake", "update", .. as rest] =>
					match rest.take_last(2) {
						["--flake", target] => flake_update!(target, rest.drop_last(2))
						_ => Err("unexpected nix flake update arguments: ${Str.join_with(rest, " ")}")
					}
				["derivation", "show", ..] => {
					if !argv.contains("allow-import-from-derivation") or !argv.contains("false") or argv.contains("extra-sandbox-paths") {
						return Err("preparation must forbid IFD and omit runtime isolation mounts")
					}
					drv = optional!("STUB_NIX_DRV") ?? "/nix/store/00000000000000000000000000000000-blueprint-app.drv"
					output = variable!("STUB_NIX_OUT")?
					written!("{${Json.to_str(drv)}:${Json.to_str({ outputs: { out: { path: output } } })}}\n")
				}
				["build", ..] => {
					drv = optional!("STUB_NIX_DRV") ?? "/nix/store/00000000000000000000000000000000-blueprint-app.drv"
					if !argv.contains("${drv}^*") or !argv.contains("--json") or argv.any(|argument| argument.contains("#packages.")) {
						return Err("execution must select the exact prepared derivation and decode native JSON")
					}

					# Record the witness before the CLI cleans its private directory.
					match optional!("STUB_NIX_ISOLATION_LOG") {
						Ok(log) => {
							mount = argv.find_first(|argument| argument.starts_with("/blueprint-isolation/witness="))
								.map_err(|_| "build has no runtime isolation mount")?
							file = mount.drop_prefix("/blueprint-isolation/witness=")
							directory = file.drop_suffix("/witness")
							witness = Path.read_utf8!(Path.utf8(file)).map_err(|_| "cannot read runtime witness")?
							Path.write_utf8!(Path.utf8(log), Json.to_str({ directory, witness })).map_err(|_| "cannot record runtime witness")?
						}
						Err(_) => {}
					}
					written!(Json.to_str([{ drvPath: optional!("STUB_NIX_RESULT_DRV") ?? drv, outputs: { out: variable!("STUB_NIX_OUT")? } }]).concat("\n"))
				}
				["develop", ..] =>
					if optional!("STUB_NIX_FAIL").is_ok() {
						_ = Stderr.line!("native package command failed")
						Ok(23)
					} else if optional!("STUB_NIX_RUN").is_ok() {
						entered!(argv)
					} else {
						Ok(0)
					}

				_ => Err("unexpected Nix invocation: ${Str.inspect(argv)}")
			}
		}
		Guix => {
			record!("guix-calls", argv)?
			Ok(99)
		}
		Python => {
			record!(optional!("STUB_PYTHON_LOG") ?? "python3-calls", argv)?
			Ok(97)
		}
		Readlink =>
			match optional!("STUB_READLINK") {
				Ok(identity) => written!("${identity}\n")
				Err(_) => Ok(1)
			}

		RocStable => {
			record!("roc-stable-calls", argv)?
			shown = match optional!("STUB_SHOW_EXE") {
				Ok(_) => "exe: ${Env.exe_path!().map_ok(Path.display) ?? "unknown"}\n"
				Err(_) => ""
			}
			written!("${shown}stub roc-stable: ${Str.join_with(argv, " ")}\n")
		}
	}
}

## Stand in for `nix develop ... --command`: run the command as a child with
## this process's streams and environment, and end as it ends.
entered! : List(Str) => Try(I32, Str)
entered! = |argv|
	match argv {
		["--command", program, .. as rest] =>
			match Cmd.new(OsStr.from_str(program)).args(rest.map(OsStr.from_str)).stdin(Inherit).stdout(Inherit).stderr(Inherit).run!() {
				Ok(Cmd.Output.{ status: Exited(code), .. }) => Ok(code)
				Ok(Cmd.Output.{ status: Signaled(signal), .. }) => Ok(128 + signal)
				Err(_) => Err("could not run ${program}")
			}

		[_, .. as rest] => entered!(rest)
		[] => Ok(0)
	}

## A variable that is set and not empty.
optional! : Str => Try(Str, [Unset])
optional! = |name|
	match Env.var_str!(OsStr.from_str(name)) {
		Ok(value) if !value.is_empty() => Ok(value)
		_ => Err(Unset)
	}

variable! : Str => Try(Str, Str)
variable! = |name| optional!(name).map_err(|_| "${name} is not set")

written! : Str => Try(I32, Str)
written! = |output| {
	Stdout.write!(output).map_err(|_| "cannot write to standard output")?
	Ok(0)
}

## Keep this invocation's arguments in a file of its own. basic-cli cannot
## append to a file, and two stubs running at once must not lose a record.
record! : Str, List(Str) => Try({}, Str)
record! = |directory, argv| {
	pid = Random.seed_u64!().map_err(|_| "cannot generate a unique invocation name")?.to_str()
	Path.create_all!(Path.utf8(directory)).map_err(|_| "cannot create ${directory}")?
	file = "${directory}/${StubTool.record_file(Utc.now!().to_nanos_since_epoch(), pid)}"
	Path.write_utf8!(Path.utf8(file), StubTool.record(argv)).map_err(|_| "cannot write ${file}")
}

## Stand in for `nix flake update`: write the native lock beside the generated
## `flake.nix`. With a barrier, say this point was reached and wait for release.
## Given input names, Nix keeps the other pins of the lock already there, so
## one must be.
flake_update! : Str, List(Str) => Try(I32, Str)
flake_update! = |target, names| {
	if !target.starts_with("path:/") {
		return Err("unexpected flake reference: ${target}")
	}
	generated = target.drop_prefix("path:")
	if !names.is_empty() and Path.read_utf8!(Path.utf8("${generated}/flake.lock")).is_err() {
		return Err("no ${generated}/flake.lock to keep the pins of inputs other than ${Str.join_with(names, " ")}")
	}
	match optional!("STUB_NIX_PAUSE") {
		Ok(barrier) => wait_at!(barrier)?
		Err(_) => {}
	}
	fixture_path = variable!("STUB_NIX_FIXTURE")?
	fixture = Path.read_utf8!(Path.utf8(fixture_path)).map_err(|_| "cannot read ${fixture_path}")?
	mode = variable!("STUB_NIX_MODE")?
	graph = match mode {
		"declared" => {
			flake = Path.read_utf8!(Path.utf8("${generated}/flake.nix")).map_err(|_| "cannot read ${generated}/flake.nix")?
			StubTool.declared_graph(fixture, StubTool.declared(flake))?
		}
		"local" => StubTool.local_graph(fixture, optional!("STUB_NIX_REV") ?? "c")?
		_ => return Err("STUB_NIX_MODE must be declared or local, not ${mode}")
	}
	Path.write_utf8!(Path.utf8("${generated}/flake.lock"), graph).map_err(|_| "cannot write ${generated}/flake.lock")?
	Ok(0)
}

wait_at! : Str => Try({}, Str)
wait_at! = |barrier| {
	Path.write_utf8!(Path.utf8("${barrier}.ready"), "").map_err(|_| "cannot write ${barrier}.ready")?
	var $waited = 0
	while !(Path.exists!(Path.utf8("${barrier}.release")) ?? False) {
		if $waited >= 30000 {
			return Err("${barrier}.release did not appear in 30 seconds")
		}
		Sleep.millis!(10)
		$waited = $waited + 10
	}
	Ok({})
}
