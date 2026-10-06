import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import Process
import Script

## Run a built `blueprint` binary on this machine with no Roc of its own: it
## must fetch its compiler, evaluate a `Blueprint.roc`, realise an environment
## and run a `roc-stable` script in it, all without a host Python.
##
## This program is cross-built for every released system, so a machine with
## only Nix can run it. Built that way it is also the Python it leaves on
## `PATH`: started under the name `python3`, it records that it was used and
## fails.
SmokeBinary := [].{

	## Where a `python3` started by the binary under test records its arguments.
	witness_variable = "BLUEPRINT_SMOKE_PYTHON_USED"

	hello_script =
		\\#!/usr/bin/env roc-stable
		\\main! = |_args| {
		\\    echo!("Hello from a roc-stable script")
		\\    Ok({})
		\\}
		\\

	## The project the binary is given. `packages_ref` names the default
	## package source where the built-in one does not support this machine.
	blueprint_roc : Str, Str -> Str
	blueprint_roc = |platform_path, packages_ref| {
		source = if packages_ref.is_empty() [] else ["	Packages(\"default\", From(NixPackages(\"${packages_ref}\"))),"]
		Str.join_with(
			["app [config] { pf: platform \"${platform_path}\" }", "", "config = [", "	Name(\"smoke\"),"]
				.concat(source)
				.concat([
					"	Overlay(\"roc\", \"github:roc-lang/roc-overlay\"),",
					"	Environment(\"dev\", [Tools([\"git\"]), Overlays([\"roc\"]), Command(\"roc-stable\", \"rocpkgs.nightly\")]),",
					"	Shell(\"default\", [Use(\"dev\")]),",
					"	Task(\"git\", [Use(\"dev\"), Run([\"git\", \"--version\"])]),",
					"	Task(\"script\", [Use(\"dev\"), Run([\"./hello.roc\"])]),",
					"]",
					"",
				]),
			"\n",
		)
	}

	## Whether a program started under this name is the stand-in Python.
	is_python : Str -> Bool
	is_python = |program| (program.split_on("/").last() ?? "") == "python3"

	## Whether this program is being run by `roc` from its source: the
	## executable is then the compiler's temporary host, named after the
	## script, and cannot be started on its own.
	is_script_host : Str -> Bool
	is_script_host = |executable| executable.ends_with(".roc")

	## Record the use and fail, as the stand-in `python3`.
	python! : List(Str) => Try({}, [Exit(I32)])
	python! = |args| {
		match Env.var_str!(OsStr.from_str(witness_variable)) {
			Ok(witness) => {
				_ = Path.write_utf8!(Path.utf8(witness), "${Str.join_with(args, " ")}\n")
			}
			Err(_) => {}
		}
		Err(Exit(97))
	}

	## Smoke-test the binary at `binary`, from the repository root.
	run! : Str => Try({}, _)
	run! = |binary| {
		root = Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?
		blueprint = Path.to_str(Path.canonicalize!(Path.utf8(binary))?)?
		# macOS temporary directories sit behind a symlink; the relative
		# platform path must be computed from the real location.
		work = Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-smoke-")?)?)?
		result = smoke!(root, blueprint, work)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

smoke! : Str, Str, Str => Try({}, _)
smoke! = |root, blueprint, work| {
	project = "${work}/project"
	Path.create_all!(Path.utf8(project))?
	packages_ref = Env.var_str!(OsStr.from_str("SMOKE_PACKAGES")) ?? ""
	platform_path = Process.relative(project, "${root}/blueprint-platform/main.roc")
	Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), SmokeBinary.blueprint_roc(platform_path, packages_ref))?
	Path.write_utf8!(Path.utf8("${project}/hello.roc"), SmokeBinary.hello_script)?
	Cmd.new_str("chmod").args_str(["+x", "${project}/hello.roc"]).exec_cmd!().map_err(|_| ChmodFailed)?

	# Leave no Roc for the binary to find.
	search = Process.search_path!()
	with_roc = Process.holding!(search, "roc")
	without_roc = search.keep_if(|directory| !with_roc.contains(directory))
	if !Process.holding!(without_roc, "roc").is_empty() {
		return Script.fail!("a roc is still on PATH")
	}

	# Leave no usable Python either: the first python3 on PATH fails. Built as
	# a program, that python3 is this program, which also records that it was
	# started. Run by `roc` as a script there is no program of its own to link
	# to, so it is the system's `false`, which only fails.
	stand_in = "${work}/no-python"
	witness = "${work}/python3-was-used"
	Path.create_all!(Path.utf8(stand_in))?
	own = Path.to_str(Env.exe_path!()?)?
	records = !SmokeBinary.is_script_host(own)
	target = if records {
		own
	} else {
		match Process.holding!(without_roc, "false") {
			[directory, ..] => "${directory}/false"
			[] => return Script.fail!("there is no `false` on PATH to stand in for python3")
		}
	}
	Cmd.new_str("ln").args_str(["-s", target, "${stand_in}/python3"]).exec_cmd!().map_err(|_| LinkFailed)?
	probe = Process.command("${stand_in}/python3", ["--version"], project)
	probed = Process.capture!({ ..probe, cmd: probe.cmd.clear_envs().envs_str([(SmokeBinary.witness_variable, witness)]) })?
	if probed.code == 0 or (records and !(Path.is_file!(Path.utf8(witness)) ?? False)) {
		return Script.fail!("the stand-in python3 does not fail and record its use (exit ${probed.code.to_str()})")
	}
	if records {
		Path.delete!(Path.utf8(witness))?
	}

	inherited = Env.dict!().map(|(name, value)| (OsStr.display(name), OsStr.display(value))).keep_if(|(name, _)| name != "ROC" and name != "PATH")
	variables = inherited.concat([("PATH", Str.join_with([stand_in].concat(without_roc), ":")), (SmokeBinary.witness_variable, witness)])
	binary = |args| {
		job = Process.command(blueprint, args, project)
		{ ..job, cmd: job.cmd.clear_envs().envs_str(variables) }
	}

	version = Process.succeed!(binary(["--version"]))?
	Stdout.write!(version.stdout)?
	_ = Process.succeed!(binary(["update"]))?
	git = Process.succeed!(binary(["run", "git"]))?
	Process.check!(git.stdout.split_on("\n").any(|line| line.starts_with("git version ")), "`blueprint run git` printed: ${git.stdout}")?
	script = Process.succeed!(binary(["run", "script"]))?
	Process.check!(script.stdout.drop_suffix("\n") == "Hello from a roc-stable script", "`blueprint run script` printed: ${script.stdout}")?
	if Path.exists!(Path.utf8(witness))? {
		return Script.fail!("blueprint used a host python3: ${Path.read_utf8!(Path.utf8(witness)) ?? ""}")
	}
	machine = Env.platform!()
	python = if records "a python3 that records its use" else "a failing python3"
	Script.pass!("blueprint binary smoke test passed on ${Str.inspect(machine.os)} ${Str.inspect(machine.arch)}, with no roc and ${python} on PATH")
}

expect SmokeBinary.is_python("python3") and SmokeBinary.is_python("/tmp/work/no-python/python3")
expect !SmokeBinary.is_python("smoke-x86_64-linux") and !SmokeBinary.is_python("dist/smoke-aarch64-darwin") and !SmokeBinary.is_python("")
expect !SmokeBinary.blueprint_roc("../pf/main.roc", "").contains("Packages(")
expect SmokeBinary.blueprint_roc("../pf/main.roc", "").starts_with("app [config] { pf: platform \"../pf/main.roc\" }\n\nconfig = [\n\tName(\"smoke\"),\n\tOverlay(")
expect SmokeBinary.blueprint_roc("../pf/main.roc", "github:NixOS/nixpkgs/abc").contains("\tName(\"smoke\"),\n\tPackages(\"default\", From(NixPackages(\"github:NixOS/nixpkgs/abc\"))),\n\tOverlay(")
expect SmokeBinary.is_script_host("/home/me/.cache/roc/nightly/tmp/G7Edog/smoke_binary.roc") and !SmokeBinary.is_script_host("/repo/dist/smoke-x86_64-linux")
