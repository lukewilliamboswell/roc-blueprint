import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import FlakeLock
import Process
import Script
import "../../.roc-version" as roc_version : Str
import "../../flake.lock" as flake_lock : Str
import "../../fixtures/consumer/inputs.lock" as fixture_lock : Str

## Run a built `blueprint` binary on this machine with no Roc of its own: it
## must fetch its compiler, evaluate a `Blueprint.roc`, realise an environment
## and run a `roc-stable` script in it, all without a host Python.
##
## This program is cross-built for every released system, so a machine with
## only Nix can run it. Built that way it is also the Python it leaves on
## `PATH`: started under the name `python3`, it records that it was used and
## fails.
##
## The project it writes pins everything it resolves, so a release is gated
## on this repository and not on what moved upstream that day: packages at the
## nixpkgs revision of `fixtures/consumer/inputs.lock`, the overlay at the
## roc-overlay revision of `flake.lock` (the two the real-Nix scenarios use)
## and the compiler at the nightly in `.roc-version`. The three files are
## compiled into this program, so they cannot disagree with it and a machine
## that runs it needs none of them. `Floating` writes instead what a new
## user's project holds, for the weekly run that watches upstream.
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

	## What the project resolves: fixed revisions, or whatever is newest.
	Inputs : [Pinned, Floating]

	## A package source, the Roc overlay and the compiler attribute in it.
	## An empty `source` leaves the provider's default source.
	References : { source : Str, overlay : Str, compiler : Str }

	floating : References
	floating = { source: "", overlay: "github:roc-lang/roc-overlay", compiler: "rocpkgs.nightly" }

	## The pins of the committed files, or which of them has none.
	pinned : Try(References, [NoPin(Str)])
	pinned = references(fixture_lock, flake_lock, roc_version)

	references : Str, Str, Str -> Try(References, [NoPin(Str)])
	references = |packages_lock, overlay_lock, version| {
		tag = version.split_on("\n").first() ?? ""
		if !tag.starts_with("nightly-") {
			return Err(NoPin(".roc-version"))
		}
		Ok({
			source: FlakeLock.ref(FlakeLock.locked(packages_lock, "nixpkgs").map_err(|_| NoPin("fixtures/consumer/inputs.lock"))?),
			overlay: FlakeLock.ref(FlakeLock.locked(overlay_lock, "roc-overlay").map_err(|_| NoPin("flake.lock"))?),
			compiler: "rocpkgs.${tag}",
		})
	}

	resolved : Inputs -> Try(References, [NoPin(Str)])
	resolved = |inputs|
		match inputs {
			Pinned => pinned
			Floating => Ok(floating)
		}

	## The project the binary is given.
	blueprint_roc : Str, References -> Str
	blueprint_roc = |platform_path, inputs| {
		declared = if inputs.source.is_empty() [] else ["	Packages(\"default\", From(NixPackages(\"${inputs.source}\"))),"]
		Str.join_with(
			["app [config] { pf: platform \"${platform_path}\" }", "", "config = [", "	Name(\"smoke\"),"]
				.concat(declared)
				.concat([
					"	Overlay(\"roc\", \"${inputs.overlay}\"),",
					"	Environment(\"dev\", [Tools([\"git\"]), Overlays([\"roc\"]), Command(\"roc-stable\", \"${inputs.compiler}\")]),",
					"	Shell(\"default\", [Use(\"dev\")]),",
					"	Task(\"git\", [Use(\"dev\"), Run([\"git\", \"--version\"])]),",
					"	Task(\"script\", [Use(\"dev\"), Run([\"./hello.roc\"])]),",
					"]",
					"",
				]),
			"\n",
		)
	}

	## What a command line asks for: the binary, after an optional `--floating`.
	requested : List(Str) -> Try({ binary : Str, inputs : Inputs }, [Usage])
	requested = |arguments| {
		(inputs, rest) = match arguments {
			["--floating", .. as others] => (Floating, others)
			_ => (Pinned, arguments)
		}
		match rest {
			[binary] => if binary.is_empty() or binary.starts_with("-") Err(Usage) else Ok({ binary, inputs })
			_ => Err(Usage)
		}
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
	run! : Str, Inputs => Try({}, _)
	run! = |binary, inputs| {
		root = Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?
		blueprint = Path.to_str(Path.canonicalize!(Path.utf8(binary))?)?
		# macOS temporary directories sit behind a symlink; the relative
		# platform path must be computed from the real location.
		work = Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-smoke-")?)?)?
		result = smoke!(root, blueprint, work, inputs)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

smoke! : Str, Str, Str, SmokeBinary.Inputs => Try({}, _)
smoke! = |root, blueprint, work, inputs| {
	project = "${work}/project"
	Path.create_all!(Path.utf8(project))?
	references = match SmokeBinary.resolved(inputs) {
		Ok(chosen) => chosen
		Err(NoPin(file)) => return Script.fail!("${file} has no pin for the smoke test")
	}
	Script.info!("==>", "packages ${if references.source.is_empty() "the provider's default" else references.source}, overlay ${references.overlay}, compiler ${references.compiler}")?
	platform_path = Process.relative(project, "${root}/blueprint-platform/main.roc")
	Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), SmokeBinary.blueprint_roc(platform_path, references))?
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
	resolved = match inputs {
		Pinned => "pinned"
		Floating => "floating"
	}
	Script.pass!("blueprint binary smoke test passed on ${Str.inspect(machine.os)} ${Str.inspect(machine.arch)} with ${resolved} inputs, no roc and ${python} on PATH")
}

expect SmokeBinary.is_python("python3") and SmokeBinary.is_python("/tmp/work/no-python/python3")
expect !SmokeBinary.is_python("smoke-x86_64-linux") and !SmokeBinary.is_python("dist/smoke-aarch64-darwin") and !SmokeBinary.is_python("")
# The floating project is what a new user's holds: no package source of its
# own, the overlay's default branch and its newest nightly.
expect !SmokeBinary.blueprint_roc("../pf/main.roc", SmokeBinary.floating).contains("Packages(")
expect SmokeBinary.blueprint_roc("../pf/main.roc", SmokeBinary.floating).starts_with("app [config] { pf: platform \"../pf/main.roc\" }\n\nconfig = [\n\tName(\"smoke\"),\n\tOverlay(\"roc\", \"github:roc-lang/roc-overlay\"),\n")
expect SmokeBinary.blueprint_roc("../pf/main.roc", SmokeBinary.floating).contains("Command(\"roc-stable\", \"rocpkgs.nightly\")")

sample_pins : SmokeBinary.References
sample_pins = { source: "github:NixOS/nixpkgs/abc", overlay: "github:roc-lang/roc-overlay/def", compiler: "rocpkgs.nightly-2026-10-04-130536d" }

# The pinned project names a revision or tag for everything it resolves.
expect SmokeBinary.blueprint_roc("../pf/main.roc", sample_pins).contains("\tName(\"smoke\"),\n\tPackages(\"default\", From(NixPackages(\"github:NixOS/nixpkgs/abc\"))),\n\tOverlay(\"roc\", \"github:roc-lang/roc-overlay/def\"),\n")
expect SmokeBinary.blueprint_roc("../pf/main.roc", sample_pins).contains("Command(\"roc-stable\", \"rocpkgs.nightly-2026-10-04-130536d\")")

lock_sample : Str, Str, Str -> Str
lock_sample = |node, repo, rev| "{\n  \"nodes\": {\n    \"${node}\": {\n      \"locked\": {\n        \"narHash\": \"sha256-AAAA\",\n        \"owner\": \"o\",\n        \"repo\": \"${repo}\",\n        \"rev\": \"${rev}\",\n        \"type\": \"github\"\n      }\n    }\n  }\n}\n"

expect SmokeBinary.references(lock_sample("nixpkgs", "nixpkgs", "abc"), lock_sample("roc-overlay", "roc-overlay", "def"), "nightly-1\n") == Ok({ source: "github:o/nixpkgs/abc", overlay: "github:o/roc-overlay/def", compiler: "rocpkgs.nightly-1" })

# A file without its pin is named; nothing falls back to a floating reference.
expect SmokeBinary.references("{}", lock_sample("roc-overlay", "roc-overlay", "def"), "nightly-1\n") == Err(NoPin("fixtures/consumer/inputs.lock"))
expect SmokeBinary.references(lock_sample("nixpkgs", "nixpkgs", "abc"), lock_sample("nixpkgs", "nixpkgs", "abc"), "nightly-1\n") == Err(NoPin("flake.lock"))
expect SmokeBinary.references(lock_sample("nixpkgs", "nixpkgs", "abc"), lock_sample("roc-overlay", "roc-overlay", "def"), "\n") == Err(NoPin(".roc-version"))

# The committed files hold all three pins, each a full revision or a nightly tag.
expect SmokeBinary.resolved(Floating) == Ok(SmokeBinary.floating)
expect match SmokeBinary.resolved(Pinned) {
	Ok(pins) =>
		pins.source.starts_with("github:NixOS/nixpkgs/") and pins.source.to_utf8().len() == 61
			and pins.overlay.starts_with("github:roc-lang/roc-overlay/") and pins.overlay.to_utf8().len() == 68
				and pins.compiler.starts_with("rocpkgs.nightly-2")
	Err(_) => False
}
expect SmokeBinary.is_script_host("/home/me/.cache/roc/nightly/tmp/G7Edog/smoke_binary.roc") and !SmokeBinary.is_script_host("/repo/dist/smoke-x86_64-linux")

expect SmokeBinary.requested(["dist/blueprint-x86_64-linux"]) == Ok({ binary: "dist/blueprint-x86_64-linux", inputs: Pinned })
expect SmokeBinary.requested(["--floating", "dist/blueprint-x86_64-linux"]) == Ok({ binary: "dist/blueprint-x86_64-linux", inputs: Floating })
expect [[], ["--floating"], ["--pinned", "blueprint"], ["blueprint", "--floating"], ["--floating", "--floating", "blueprint"], ["a", "b"], [""]].all(|arguments| SmokeBinary.requested(arguments) == Err(Usage))
