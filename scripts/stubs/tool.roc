#!/usr/bin/env roc
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
	nix: "../../blueprint-nix/main.roc",
}

import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
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
##   nix         record; `flake update` writes a `flake.lock` from `STUB_NIX_FIXTURE`
##               as `STUB_NIX_MODE` says (`declared` or `local`, the latter with
##               `STUB_NIX_REV`), after waiting at `STUB_NIX_PAUSE` if set;
##               `build` prints `STUB_NIX_OUT`; `develop` exits 23 if `STUB_NIX_FAIL`
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
			ran = Cmd.new_str(real).args(args).stdin(Inherit).stdout(Inherit).stderr(Inherit).run!()
			match ran {
				Ok({ status: Exited(code), .. }) => Ok(code)
				Ok({ status: Signaled(signal), .. }) => Ok(128 + signal)
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
			record!("nix-calls", argv)?
			match argv {
				["flake", "update", "--flake", target] => flake_update!(target)
				["build", ..] => written!("${variable!("STUB_NIX_OUT")?}\n")
				["develop", ..] =>
					if optional!("STUB_NIX_FAIL").is_ok() {
						_ = Stderr.line!("native package command failed")
						Ok(23)
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
	}
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
	self = Path.canonicalize!(Path.utf8("/proc/self")).map_ok(Path.display).map_err(|_| "cannot read /proc/self")?
	pid = self.split_on("/").last() ?? ""
	Path.create_all!(Path.utf8(directory)).map_err(|_| "cannot create ${directory}")?
	file = "${directory}/${StubTool.record_file(Utc.now!(), pid)}"
	Path.write_utf8!(Path.utf8(file), StubTool.record(argv)).map_err(|_| "cannot write ${file}")
}

## Stand in for `nix flake update`: write the native lock beside the generated
## `flake.nix`. With a barrier, say this point was reached and wait for release.
flake_update! : Str => Try(I32, Str)
flake_update! = |target| {
	if !target.starts_with("path:/") {
		return Err("unexpected flake reference: ${target}")
	}
	generated = target.drop_prefix("path:")
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
