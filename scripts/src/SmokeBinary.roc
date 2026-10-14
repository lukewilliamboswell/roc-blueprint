import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import FlakeLock
import Process
import Script
import "../../blueprint-cli/compiler-version" as roc_version : Str
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
## and the compiler at the nightly in `blueprint-cli/compiler-version`. The three files are
## compiled into this program, so they cannot disagree with it and a machine
## that runs it needs none of them. `Floating` writes instead what a new
## user's project holds, for the weekly run that watches upstream.
##
## `NoNix` is the other kind of project, for a machine that has no Nix at
## all: its compiler is a fetched program, it expects `git` of the machine
## and names its Roc packages, and nothing in it is Nix's. The binary must
## update it, say that its tasks need no provider, and build, link and run a
## basic-cli script with the fetched compiler, downloading that compiler once
## and nothing the second time.
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

	## The project the binary is given: one whose tools Nix installs, with
	## what it resolves, or one that takes nothing from Nix.
	Mode : [Nix(Inputs), NoNix]

	## The Roc packages of the script the Nix-free project runs: basic-cli
	## and the package it depends on.
	roc_packages = [
		"https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
		"https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	]

	## A script that is built against a platform and linked before it runs,
	## which a script with no platform is not.
	linked_script : Str
	linked_script =
		Str.join_with(
			[
				"#!/usr/bin/env roc-stable",
				"app [main!] { cli: platform \"${roc_packages.first() ?? ""}\" }",
				"",
				"import cli.Stdout",
				"",
				"main! = |_args| Stdout.line!(\"${linked_greeting}\")",
				"",
			],
			"\n",
		)

	linked_greeting = "Hello from a roc-stable script that was built and linked without Nix"

	## The project that takes nothing from Nix: the compiler of `tag` as a
	## fetched program, `git` expected of the machine, and the script's Roc
	## packages.
	no_nix_roc : Str, Str -> Str
	no_nix_roc = |platform_path, tag|
		Str.join_with(
			[
				"app [config] { pf: platform \"${platform_path}\" }",
				"",
				"import pf.Recipes",
				"",
				"config = [",
				"	Name(\"smoke\"),",
				"	Systems([\"x86_64-linux\", \"aarch64-linux\", \"aarch64-darwin\", \"x86_64-windows\"]),",
				"	Environment(\"dev\", [",
				"		Programs([Fetch(\"roc-stable\", Recipes.roc_nightly(\"${tag}\"))]),",
				"		Expect([\"git\"]),",
				"		RocPackages([${Str.join_with(roc_packages.map(|url| "\"${url}\""), ", ")}]),",
				"	]),",
				"	Task(\"script\", [Use(\"dev\"), Run([\"roc-stable\", \"hello.roc\"])]),",
				"]",
				"",
			],
			"\n",
		)

	## What `blueprint requirements --json` must say of that project: no
	## provider, and `git` expected. The report is read as JSON, so its
	## spacing and the fields this does not name may change.
	needs_no_provider : Str -> Bool
	needs_no_provider = |report| {
		parsed : Try({ providers : List(Str), expects : List(Str) }, _)
		parsed = Json.parse(report)
		match parsed {
			Ok(found) => found.providers.is_empty() and found.expects == ["git"]
			Err(_) => False
		}
	}

	## How often `part` occurs in `text`.
	occurrences : Str, Str -> U64
	occurrences = |text, part| text.split_on(part).len() - 1

	## How often the binary said it fetched the compiler that reads
	## Blueprint.roc. An update that could not ask what a release publishes
	## also fetches `roc-stable` for the other systems to hash it, which is
	## not that.
	compiler_fetches : Str -> U64
	compiler_fetches = |stderr| occurrences(stderr, "blueprint: fetching roc from ")

	## A package source, the Roc overlay and the compiler attribute in it.
	References : { source : Str, overlay : Str, compiler : Str }

	floating : References
	floating = { source: "github:NixOS/nixpkgs/nixos-unstable", overlay: "github:roc-lang/roc-overlay", compiler: "rocpkgs.nightly" }

	## The pins of the committed files, or which of them has none.
	pinned : Try(References, [NoPin(Str)])
	pinned = references(fixture_lock, flake_lock, roc_version)

	references : Str, Str, Str -> Try(References, [NoPin(Str)])
	references = |packages_lock, overlay_lock, version| {
		tag = version.split_on("\n").first() ?? ""
		if !tag.starts_with("nightly-") {
			return Err(NoPin("blueprint-cli/compiler-version"))
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
		Str.join_with(
			["app [config] { pf: platform \"${platform_path}\" }", "", "config = [", "	Name(\"smoke\"),"]
				.concat([
					"	Packages(\"default\", From(NixPackages(\"${inputs.source}\"))),",
					"	Overlay(\"roc\", \"${inputs.overlay}\"),",
					"	Environment(\"dev\", [Tools([\"default#git\"]), Overlays([\"roc\"]), Command(\"roc-stable\", \"default#${inputs.compiler}\")]),",
					"	Shell(\"default\", [Use(\"dev\")]),",
					"	Task(\"git\", [Use(\"dev\"), Run([\"git\", \"--version\"])]),",
					"	Task(\"script\", [Use(\"dev\"), Run([\"./hello.roc\"])]),",
					"]",
					"",
				]),
			"\n",
		)
	}

	## What a command line asks for: the binary, after an optional
	## `--floating` or `--no-nix`.
	requested : List(Str) -> Try({ binary : Str, mode : Mode }, [Usage])
	requested = |arguments| {
		(mode, rest) = match arguments {
			["--floating", .. as others] => (Nix(Floating), others)
			["--no-nix", .. as others] => (NoNix, others)
			_ => (Nix(Pinned), arguments)
		}
		match rest {
			[binary] => if binary.is_empty() or binary.starts_with("-") Err(Usage) else Ok({ binary, mode })
			_ => Err(Usage)
		}
	}

	## Whether a program started under this name is the stand-in Python.
	is_python : Str -> Bool
	is_python = |program| (Process.portable(program).split_on("/").last() ?? "").drop_suffix(".exe") == "python3"

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
	run! : Str, Mode => Try({}, _)
	run! = |binary, mode| {
		root = Process.portable(Path.to_str(Path.canonicalize!(Env.cwd!()?)?)?)
		blueprint = Process.portable(Path.to_str(Path.canonicalize!(Path.utf8(binary))?)?)
		# macOS temporary directories sit behind a symlink; the relative
		# platform path must be computed from the real location.
		# A relative platform dependency cannot cross Windows drive letters.
		# Keep the project on the checkout's drive, even when TEMP is on C:.
		temporary = if Env.platform!().os == WINDOWS {
			cache = Path.utf8("${root}/.cache")
			cache.create_all!()?
			Env.create_temp_dir_in!(cache, "blueprint-smoke-")?
		} else {
			Env.create_temp_dir_with_prefix!("blueprint-smoke-")?
		}
		work = Process.portable(Path.to_str(Path.canonicalize!(temporary)?)?)
		result = smoke!(root, blueprint, work, mode)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

smoke! : Str, Str, Str, SmokeBinary.Mode => Try({}, _)
smoke! = |root, blueprint, work, mode| {
	project = "${work}/project"
	Path.create_all!(Path.utf8(project))?
	platform_path = Process.relative(project, "${root}/blueprint-platform/main.roc")
	match mode {
		Nix(inputs) => {
			references = match SmokeBinary.resolved(inputs) {
				Ok(chosen) => chosen
				Err(NoPin(file)) => return Script.fail!("${file} has no pin for the smoke test")
			}
			Script.info!("==>", "packages ${if references.source.is_empty() "the provider's default" else references.source}, overlay ${references.overlay}, compiler ${references.compiler}")?
			Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), SmokeBinary.blueprint_roc(platform_path, references))?
			Path.write_utf8!(Path.utf8("${project}/hello.roc"), SmokeBinary.hello_script)?
		}
		NoNix => {
			tag = roc_version.trim()
			Script.info!("==>", "no Nix: roc-stable is the fetched ${tag}, git is the machine's")?
			Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), SmokeBinary.no_nix_roc(platform_path, tag))?
			Path.write_utf8!(Path.utf8("${project}/hello.roc"), SmokeBinary.linked_script)?
		}
	}
	if Env.platform!().os != WINDOWS {
		Cmd.new("chmod").args(["+x", "${project}/hello.roc"].map(OsStr.from_str)).exec!().map_err(|_| ChmodFailed)?
	}

	# Leave no Roc for the binary to find.
	search = Process.search_path!()
	with_roc = Process.holding!(search, "roc")
	without_roc = search.keep_if(|directory| !with_roc.contains(directory))
	if !Process.holding!(without_roc, "roc").is_empty() {
		return Script.fail!("a roc is still on PATH")
	}

	# The Nix-free project is for a machine without Nix: with one here, a
	# pass would not show that nothing started it.
	nix_in = match mode {
		NoNix => Process.holding!(without_roc, "nix")
		Nix(_) => []
	}
	if !nix_in.is_empty() {
		return Script.fail!("nix is on PATH in ${Str.join_with(nix_in, ", ")}: --no-nix is for a machine without it")
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
	python_path = "${stand_in}/python3${if Env.platform!().os == WINDOWS ".exe" else ""}"
	if Env.platform!().os == WINDOWS {
		Path.utf8(target).copy!(Path.utf8(python_path)).map_err(|_| LinkFailed)?
	} else {
		Cmd.new("ln").args(["-s", target, python_path].map(OsStr.from_str)).exec!().map_err(|_| LinkFailed)?
	}
	probe = Process.command(python_path, ["--version"], project)
	probed = Process.capture!({ ..probe, cmd: probe.cmd.clear_envs().envs([(SmokeBinary.witness_variable, witness)].map(|(key, value)| (OsStr.from_str(key), OsStr.from_str(value)))) })?
	if probed.code == 0 or (records and !(Path.is_file!(Path.utf8(witness)) ?? False)) {
		return Script.fail!("the stand-in python3 does not fail and record its use (exit ${probed.code.to_str()})")
	}
	if records {
		Path.delete!(Path.utf8(witness))?
	}

	# The Nix-free project starts from nothing: a store and a Roc package
	# cache of this run's own, so that what it downloads can be counted.
	private = match mode {
		Nix(_) => []
		NoNix => [("XDG_CACHE_HOME", "${work}/cache")]
	}
	kept = ["ROC", "PATH"].concat(private.map(|(name, _)| name))
	inherited = Env.dict!().map(|(name, value)| (OsStr.display(name), OsStr.display(value))).keep_if(|(name, _)| !kept.contains(name))
	variables = inherited.concat(private).concat([("PATH", Str.join_with([stand_in].concat(without_roc), if Env.platform!().os == WINDOWS ";" else ":")), (SmokeBinary.witness_variable, witness)])
	binary = |args| {
		job = Process.command(blueprint, args, project)
		{ ..job, cmd: job.cmd.clear_envs().envs(variables.map(|(key, value)| (OsStr.from_str(key), OsStr.from_str(value)))) }
	}

	# Every command reads Blueprint.roc first, so this one fetches the
	# compiler when there is none: its standard error says so.
	version = Process.succeed!(binary(["--version"]))?
	Stdout.write!(version.stderr)?
	Stdout.write!(version.stdout)?
	described = match mode {
		Nix(inputs) => {
			_ = Process.succeed!(binary(["update"]))?
			git = Process.succeed!(binary(["run", "git"]))?
			Process.check!(git.stdout.split_on("\n").any(|line| line.starts_with("git version ")), "`blueprint run git` printed: ${git.stdout}")?
			script = Process.succeed!(binary(["run", "script"]))?
			Process.check!(script.stdout.drop_suffix("\n") == "Hello from a roc-stable script", "`blueprint run script` printed: ${script.stdout}")?
			match inputs {
				Pinned => "pinned inputs"
				Floating => "floating inputs"
			}
		}
		NoNix => {
			without_nix!(project, binary, version.stderr)?
			"no Nix: one download of the compiler, no provider required, a script built and linked, and nothing downloaded the second time"
		}
	}
	if Path.exists!(Path.utf8(witness))? {
		return Script.fail!("blueprint used a host python3: ${Path.read_utf8!(Path.utf8(witness)) ?? ""}")
	}
	machine = Env.platform!()
	python = if records "a python3 that records its use" else "a failing python3"
	Script.pass!("blueprint binary smoke test passed on ${Str.inspect(machine.os)} ${Str.inspect(machine.arch)} with ${described}, no roc and ${python} on PATH")
}

## The Nix-free project, on a machine that has no `nix`: what each command
## printed on standard error is shown, since it says what was downloaded.
## `before` is what the first command of the run printed there.
without_nix! : Str, (List(Str) -> Process.Job), Str => Try({}, _)
without_nix! = |project, binary, before| {
	updated = Process.succeed!(binary(["update"]))?
	Stdout.write!(updated.stderr)?
	Stdout.write!(updated.stdout)?
	Process.check!(SmokeBinary.compiler_fetches("${before}${updated.stderr}") == 1, "the compiler was not fetched exactly once before the first run")?
	Process.check!(updated.stderr.contains("is the download of Roc this blueprint already holds; its digest is recorded from the store"), "the first update fetched roc-stable for this machine a second time, though it is the compiler it had just fetched")?
	Process.check!(Path.is_file!(Path.utf8("${project}/Blueprint.lock")) ?? False, "update wrote no Blueprint.lock")?

	needs = Process.succeed!(binary(["requirements", "--json"]))?
	Stdout.write!(needs.stdout)?
	Process.check!(SmokeBinary.needs_no_provider(needs.stdout), "`blueprint requirements --json` does not say that the tasks need no provider and expect git")?

	first = Process.succeed!(binary(["run", "script"]))?
	Stdout.write!(first.stderr)?
	Stdout.write!(first.stdout)?
	Process.check!(first.stdout.drop_suffix("\n") == SmokeBinary.linked_greeting, "`blueprint run script` printed: ${first.stdout}")?
	Process.check!(!first.stderr.contains("blueprint: fetching roc"), "the run after the update fetched the compiler again:\n${first.stderr}")?

	second = Process.succeed!(binary(["run", "script"]))?
	Stdout.write!(second.stdout)?
	Process.check!(second.stdout.drop_suffix("\n") == SmokeBinary.linked_greeting, "the second `blueprint run script` printed: ${second.stdout}")?
	Process.check!(!second.stderr.contains("fetching"), "the second run downloaded something:\n${second.stderr}")?
	Process.check!(!(Path.exists!(Path.utf8("${project}/.blueprint/flake.nix")) ?? True), "a flake was generated for a project that takes nothing from Nix")
}

expect SmokeBinary.is_python("python3") and SmokeBinary.is_python("/tmp/work/no-python/python3")
expect !SmokeBinary.is_python("smoke-x86_64-linux") and !SmokeBinary.is_python("dist/smoke-aarch64-darwin") and !SmokeBinary.is_python("")
# The floating project is what a new user's holds: a branch of nixpkgs, the
# overlay's default branch and its newest nightly.
expect SmokeBinary.blueprint_roc("../pf/main.roc", SmokeBinary.floating).starts_with("app [config] { pf: platform \"../pf/main.roc\" }\n\nconfig = [\n\tName(\"smoke\"),\n\tPackages(\"default\", From(NixPackages(\"github:NixOS/nixpkgs/nixos-unstable\"))),\n\tOverlay(\"roc\", \"github:roc-lang/roc-overlay\"),\n")
expect SmokeBinary.blueprint_roc("../pf/main.roc", SmokeBinary.floating).contains("Command(\"roc-stable\", \"default#rocpkgs.nightly\")")

sample_pins : SmokeBinary.References
sample_pins = { source: "github:NixOS/nixpkgs/abc", overlay: "github:roc-lang/roc-overlay/def", compiler: "rocpkgs.nightly-2026-10-13-b17d287" }

# The pinned project names a revision or tag for everything it resolves.
expect SmokeBinary.blueprint_roc("../pf/main.roc", sample_pins).contains("\tName(\"smoke\"),\n\tPackages(\"default\", From(NixPackages(\"github:NixOS/nixpkgs/abc\"))),\n\tOverlay(\"roc\", \"github:roc-lang/roc-overlay/def\"),\n")
expect SmokeBinary.blueprint_roc("../pf/main.roc", sample_pins).contains("Command(\"roc-stable\", \"default#rocpkgs.nightly-2026-10-13-b17d287\")")

lock_sample : Str, Str, Str -> Str
lock_sample = |node, repo, rev| "{\n  \"nodes\": {\n    \"${node}\": {\n      \"locked\": {\n        \"narHash\": \"sha256-AAAA\",\n        \"owner\": \"o\",\n        \"repo\": \"${repo}\",\n        \"rev\": \"${rev}\",\n        \"type\": \"github\"\n      }\n    }\n  }\n}\n"

expect SmokeBinary.references(lock_sample("nixpkgs", "nixpkgs", "abc"), lock_sample("roc-overlay", "roc-overlay", "def"), "nightly-1\n") == Ok({ source: "github:o/nixpkgs/abc", overlay: "github:o/roc-overlay/def", compiler: "rocpkgs.nightly-1" })

# A file without its pin is named; nothing falls back to a floating reference.
expect SmokeBinary.references("{}", lock_sample("roc-overlay", "roc-overlay", "def"), "nightly-1\n") == Err(NoPin("fixtures/consumer/inputs.lock"))
expect SmokeBinary.references(lock_sample("nixpkgs", "nixpkgs", "abc"), lock_sample("nixpkgs", "nixpkgs", "abc"), "nightly-1\n") == Err(NoPin("flake.lock"))
expect SmokeBinary.references(lock_sample("nixpkgs", "nixpkgs", "abc"), lock_sample("roc-overlay", "roc-overlay", "def"), "\n") == Err(NoPin("blueprint-cli/compiler-version"))

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

expect SmokeBinary.requested(["dist/blueprint-x86_64-linux"]) == Ok({ binary: "dist/blueprint-x86_64-linux", mode: Nix(Pinned) })
expect SmokeBinary.requested(["--floating", "dist/blueprint-x86_64-linux"]) == Ok({ binary: "dist/blueprint-x86_64-linux", mode: Nix(Floating) })
expect SmokeBinary.requested(["--no-nix", "dist/blueprint-x86_64-linux"]) == Ok({ binary: "dist/blueprint-x86_64-linux", mode: NoNix })
expect [[], ["--floating"], ["--no-nix"], ["--pinned", "blueprint"], ["blueprint", "--floating"], ["blueprint", "--no-nix"], ["--floating", "--floating", "blueprint"], ["--no-nix", "--floating", "blueprint"], ["a", "b"], [""]].all(|arguments| SmokeBinary.requested(arguments) == Err(Usage))

# The Nix-free project names no package source, overlay or tool of one: its
# compiler is a fetched program and git is the machine's.
expect {
	text = SmokeBinary.no_nix_roc("../pf/main.roc", "nightly-2026-10-13-b17d287")
	text.starts_with("app [config] { pf: platform \"../pf/main.roc\" }\n\nimport pf.Recipes\n\nconfig = [\n\tName(\"smoke\"),\n\tSystems([\"x86_64-linux\", \"aarch64-linux\", \"aarch64-darwin\", \"x86_64-windows\"]),\n\tEnvironment(\"dev\", [\n\t\tPrograms([Fetch(\"roc-stable\", Recipes.roc_nightly(\"nightly-2026-10-13-b17d287\"))]),\n\t\tExpect([\"git\"]),\n\t\tRocPackages([\"https://github.com/roc-lang/basic-cli/")
		and ["NixPackages", "Overlay(", "Tools(", "Command(", "#"].all(|part| !text.contains(part))
}
expect SmokeBinary.linked_script.starts_with("#!/usr/bin/env roc-stable\napp [main!] { cli: platform \"https://github.com/roc-lang/basic-cli/releases/download/")

# The report is read as JSON: no provider and git expected, whatever else it
# holds; a provider, another expectation or text that is no report is not it.
expect SmokeBinary.needs_no_provider("{\"format\":1,\"system\":\"x86_64-linux\",\"providers\":[],\"expects\":[\"git\"],\"tasks\":[\n {\"name\":\"script\",\"environment\":\"dev\",\"providers\":[],\"tools\":[],\"programs\":[\"roc-stable\"],\"unavailable\":[],\"expects\":[\"git\"],\"roc_packages\":2}]}\n")
expect !SmokeBinary.needs_no_provider("{\"format\":1,\"system\":\"x86_64-linux\",\"providers\":[\"nix\"],\"expects\":[\"git\"],\"tasks\":[]}")
expect !SmokeBinary.needs_no_provider("{\"format\":1,\"system\":\"x86_64-linux\",\"providers\":[],\"expects\":[],\"tasks\":[]}") and !SmokeBinary.needs_no_provider("providers: none")
expect SmokeBinary.occurrences("a fetching b fetching c", "fetching") == 2 and SmokeBinary.occurrences("none", "fetching") == 0

# The compiler's own fetch is counted; the other systems' downloads of an
# update that GitHub would not answer are not.
expect
	SmokeBinary.compiler_fetches(
		"blueprint: fetching roc from https://github.com/roc-lang/nightlies/releases/download/t/roc_nightly-macos_apple_silicon-t.tar.gz\nblueprint: asking https://api.github.com/repos/roc-lang/nightlies/releases/tags/t what roc-lang/nightlies publishes for its release t\nblueprint: could not ask for the digests roc-lang/nightlies publishes for its release t: HTTP 403\nblueprint: roc-stable for aarch64-darwin is the download of Roc this blueprint already holds; its digest is recorded from the store\nblueprint: fetching roc-stable for x86_64-linux from https://github.com/roc-lang/nightlies/releases/download/t/roc_nightly-linux_x86_64-t.tar.gz to record its digest\n",
	) == 1
expect SmokeBinary.compiler_fetches("blueprint: fetching roc-stable from https://example.org/roc.tar.gz\n") == 0
