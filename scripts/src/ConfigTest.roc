import cli.Path
import Process
import Script
import "../../examples/composition/Blueprint.roc" as composition_app : Str
import "../../examples/composition/ProjectTasks.roc" as composition_tasks : Str
import "../../examples/composition/Releases.roc" as composition_releases : Str

## Whole-config validation happens in `roc check`, against the local platform
## and against a served platform bundle.
##
## Each fixture is one `Blueprint.roc`. The rules of `blueprint-core/Project.roc`
## have `expect`s of their own there; what is checked here is what only a
## compiler run can show: the platform's own cardinality rules in `Lower.roc`,
## the checked names, that a core rule and a heavy bound surface as a
## compile-time error, and that composed settings emit the same Spec.
ConfigTest := [].{

	## What `roc check` must do with a fixture: accept it, reject it as an
	## invalid Blueprint with this message, reject a quoted value with it, or
	## refuse it in another way, such as a type or a name, in these words.
	Kind : [Valid, Rejected(Str), BadQuote(Str), Refused(Str)]

	Fixture : { name : Str, kind : Kind, config : Str }

	## The whole suite, or the few fixtures a served bundle is smoke-tested with.
	Subset : [Full, Smoke]

	fixtures : List(Fixture)
	fixtures = valid_fixtures.concat(lower_fixtures).concat(quote_fixtures).concat(core_fixtures).concat(program_fixtures)

	## One valid config, one rejection from each layer, the imported
	## composition pair and one heavy bound.
	smoke_names = ["Valid", "MissingName", "UnknownSource", "BadWorkflowName", "Composed", "EquivalentComposition", "WorkflowExpansion"]

	## Fixtures whose emitted Spec is compared or searched.
	emitted_names = ["Valid", "Composed", "EquivalentComposition", "Builds", "ComposedBuilds", "Workflows", "ComposedWorkflows", "SystemTools", "Commands", "ConfiguredTools", "RocPackages", "Programs"]

	## Settings composed from an imported module emit the same Spec as inline ones.
	same_spec_pairs = [("Composed", "EquivalentComposition"), ("Builds", "ComposedBuilds"), ("Workflows", "ComposedWorkflows")]

	## A new optional field comes with a feature marker for older consumers.
	markers : List((Str, List(Str)))
	markers = [
		("Valid", ["(requires (\"explicit-sources\"))", "(ref \"github:NixOS/nixpkgs/nixos-unstable\")", "(version 1)"]),
		("Builds", ["(minor 0)", "(requires (\"explicit-sources\" \"sources\" \"builds\"))", "(build_sources ", "(builds "]),
		(
			"Workflows",
			[
				"(minor 0)",
				"(requires (\"explicit-sources\" \"builds\" \"workflows\"))",
				"(workflows ",
				"(RunTask \"check.all\" (\"\" \"two words\" \"\\\"quoted\\\"\" \"\$HOME\" \"line\\nbreak\" \"--flag\"))",
			],
		),
		("SystemTools", ["(requires (\"explicit-sources\" \"system-tools\"))", "(system_tools ", "(system \"x86_64-linux\")"]),
		("Commands", ["(requires (\"explicit-sources\" \"commands\"))", "(commands ", "(name \"roc-stable\")"]),
		(
			"ConfiguredTools",
			[
				"(requires (\"explicit-sources\" \"configured-tools\"))",
				"(configured_tools ",
				"(name \"rust-bin.stable.latest.default\")",
				"(Str \"rust-src\")",
			],
		),
		(
			"RocPackages",
			[
				"(requires (\"explicit-sources\" \"sources\" \"roc-packages\"))",
				"(roc_packages ",
				"(ref \"tarball+https://example.test/releases/download/1.0.0/abc123.tar.zst\")",
			],
		),
		(
			"Programs",
			[
				"(requires (\"explicit-sources\" \"programs\" \"expects\"))",
				"(programs ",
				"(environment_programs ",
				"(expects ",
				"(urls (\"https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-18-1df370f/roc_nightly-linux_x86_64-2026-10-18-1df370f.tar.gz\"))",
				"(unpack TarGz)",
				"(path \"roc_nightly-windows_x86_64-2026-10-18-1df370f/roc.exe\")",
				"(unpack Zip)",
				"(urls (\"https://example.test/1.0/tool-linux\" \"https://mirror.example.test/1.0/tool-linux\"))",
				"(urls (\"https://example.test/windows/notes-x86_64\"))",
				"(unpack File)",
				"(programs (\"roc-stable\" \"tool\" \"notes\"))",
				"(programs (\"git\" \"gh\"))",
			],
		),
	]

	## A fixture's app. One that names a module of the platform imports it.
	app_source : Str, Str -> Str
	app_source = |platform_ref, config| {
		modules = ["Recipes.", "System ->", "Config."].keep_if(|use| config.contains(use)).map(|use| use.drop_suffix(".").drop_suffix(" ->"))
		prelude = if modules.is_empty() "" else "${Str.join_with(modules.map(|needed| "import pf.${needed}"), "\n")}\n\n"
		"app [config] { pf: platform \"${platform_ref}\" }\n\n${prelude}config = ${config}\n"
	}

	## Every file the fixtures need, by name: one app per fixture, the four
	## imported modules and the apps that compose them.
	sources : Str -> List((Str, Str))
	sources = |platform_ref| {
		header = "app [config] { pf: platform \"${platform_ref}\" }\n"
		fixtures.map(|fixture| ("${fixture.name}.roc", app_source(platform_ref, fixture.config)))
			.concat([
				("ProjectBuilds.roc", settings_module("ProjectBuilds", build_settings)),
				("ComposedBuilds.roc", "${header}import ProjectBuilds\nconfig = [${build_base}].concat(ProjectBuilds.settings)\n"),
				("ProjectWorkflows.roc", settings_module("ProjectWorkflows", workflow_steps)),
				("ComposedWorkflows.roc", "${header}import ProjectWorkflows\nconfig = [${workflow_base}].concat(ProjectWorkflows.settings)\n"),
				# The real imported-module example, against this platform.
				("ProjectTasks.roc", composition_tasks),
				("Releases.roc", composition_releases),
				("Composed.roc", composition_app.replace_each("platform \"../../blueprint-platform/main.roc\"", "platform \"${platform_ref}\"")),
			])
	}

	## Apps `roc check` must accept that are not in `fixtures`.
	composed_names = ["ComposedBuilds", "ComposedWorkflows", "Composed"]

	## The fixtures of a subset, with composed apps as valid fixtures.
	selected : Subset -> List(Fixture)
	selected = |subset| {
		all = fixtures.concat(composed_names.map(|name| { name, kind: Valid, config: "" }))
		match subset {
			Full => all
			Smoke => all.keep_if(|fixture| smoke_names.contains(fixture.name))
		}
	}

	## Why `roc check` did not do what the fixture requires, or "" if it did.
	## A warning, a compiler crash or an unrelated error is not a rejection.
	problem : Fixture, Process.Outcome -> Str
	problem = |fixture, outcome| {
		log = "${outcome.stdout}${outcome.stderr}"
		code = outcome.code.to_str()
		match fixture.kind {
			Valid => if outcome.code == 0 "" else "expected ${fixture.name} to be accepted, got exit ${code}"
			Rejected(message) =>
				if outcome.code == 1 and log.contains("compile time crash") and log.contains("Invalid Blueprint.roc:") and log.contains(message) {
					""
				} else {
					"expected compile-time ${fixture.name} rejection containing '${message}' (exit 1), got exit ${code}"
				}
			# A rejected literal is reported with a caret on it, or against
			# the definition being evaluated with its line and column: which
			# of the two is not ours to rely on. Both say `invalid string`.
			BadQuote(message) =>
				if outcome.code == 1 and log.contains("invalid string") and log.contains(message) {
					""
				} else {
					"expected checked-name rejection for ${fixture.name}, got exit ${code}"
				}

			Refused(message) =>
				if outcome.code == 1 and log.contains(message) and !log.contains("Invalid Blueprint.roc:") {
					""
				} else {
					"expected ${fixture.name} to be refused with '${message}' (exit 1), got exit ${code}"
				}
		}
	}

	## Write the fixtures into `work`, check each, then run the ones whose Spec
	## is compared. `platform` is a path relative to `work`, or a bundle URL.
	## `drive!` runs a batch of compiler commands together and returns their
	## outcomes in order; a caller serving a bundle serves it meanwhile, and
	## gives in `arguments` what the compiler needs to find the rest there.
	run! : { roc : Str, platform_ref : Str, work : Str, subset : Subset, environment : List((Str, Str)), arguments : List(Str) }, (List(Process.Job) => Try(List(Process.Outcome), _)) => Try({}, _)
	run! = |options, drive!| {
		for (name, text) in sources(options.platform_ref) {
			Path.write_utf8!(Path.utf8("${options.work}/${name}"), text)?
		}
		chosen = selected(options.subset)
		compiler = |args, name| Process.with_env(Process.command(options.roc, args.concat(options.arguments).concat(["${name}.roc"]), options.work), options.environment)

		checked = drive!(chosen.map(|fixture| compiler(["check"], fixture.name)))?
		report_checks!(chosen, checked)?

		emitted = chosen.map(|fixture| fixture.name).keep_if(|name| emitted_names.contains(name))
		ran = drive!(emitted.map(|name| compiler([], name)))?
		specs = collect_specs!(emitted, ran, [])?
		compare_specs!(emitted, specs)?

		count = |keep| chosen.keep_if(keep).len().to_str()
		Script.info!(
			"   ",
			"${count(is_valid)} valid configs accepted; ${count(is_rejected)} semantic errors, ${count(is_bad_quote)} checked-name errors and ${count(is_refused)} type or name errors rejected at compile time; equivalent Spec verified",
		)
	}
}

is_valid : ConfigTest.Fixture -> Bool
is_valid = |fixture|
	match fixture.kind {
		Valid => True
		_ => False
	}

is_rejected : ConfigTest.Fixture -> Bool
is_rejected = |fixture|
	match fixture.kind {
		Rejected(_) => True
		_ => False
	}

is_refused : ConfigTest.Fixture -> Bool
is_refused = |fixture|
	match fixture.kind {
		Refused(_) => True
		_ => False
	}

is_bad_quote : ConfigTest.Fixture -> Bool
is_bad_quote = |fixture|
	match fixture.kind {
		BadQuote(_) => True
		_ => False
	}

report_checks! : List(ConfigTest.Fixture), List(Process.Outcome) => Try({}, _)
report_checks! = |chosen, outcomes| {
	if chosen.len() != outcomes.len() {
		return Script.fail!("expected ${chosen.len().to_str()} compiler results, got ${outcomes.len().to_str()}")
	}
	var $index = 0
	for fixture in chosen {
		outcome = outcomes.get($index) ?? { code: -1, stdout: "", stderr: "" }
		reason = ConfigTest.problem(fixture, outcome)
		if !reason.is_empty() {
			return Script.fail!("${outcome.stdout}${outcome.stderr}\n${reason}")
		}
		$index = $index + 1
	}
	Ok({})
}

## The Spec each app printed, in the order of `names`.
collect_specs! : List(Str), List(Process.Outcome), List(Str) => Try(List(Str), _)
collect_specs! = |names, outcomes, specs|
	match (names, outcomes) {
		([], []) => Ok(specs)
		([name, .. as other_names], [outcome, .. as other_outcomes]) => {
			if outcome.code != 0 {
				return Script.fail!("${outcome.stdout}${outcome.stderr}\nrunning ${name}.roc exited with code ${outcome.code.to_str()}")
			}
			collect_specs!(other_names, other_outcomes, specs.append(outcome.stdout))
		}
		_ => Script.fail!("the compiler results do not match the apps that were run")
	}

spec_of : List(Str), List(Str), Str -> Try(Str, [NotEmitted])
spec_of = |names, specs, name|
	match names.find_first_index(|candidate| candidate == name) {
		Ok(index) => specs.get(index).map_err(|_| NotEmitted)
		Err(_) => Err(NotEmitted)
	}

## Compare the emitted Spec, not private lowering details.
compare_specs! : List(Str), List(Str) => Try({}, _)
compare_specs! = |names, specs| {
	for (left, right) in ConfigTest.same_spec_pairs {
		match (spec_of(names, specs, left), spec_of(names, specs, right)) {
			(Ok(left_spec), Ok(right_spec)) =>
				if left_spec != right_spec {
					return Script.fail!("--- ${left}\n${left_spec}\n+++ ${right}\n${right_spec}\nexpected identical semantic Spec for ${left} and ${right}")
				}
			_ => {}
		}
	}
	for (name, expected) in ConfigTest.markers {
		match spec_of(names, specs, name) {
			Ok(spec) => {
				match missing_marker(name, spec, expected) {
					Ok(marker) => return Script.fail!("${spec}\nthe Spec of ${name} does not contain ${marker}")
					Err(NoneMissing) => {}
				}
			}
			Err(NotEmitted) => {}
		}
	}
	Ok({})
}

## The first expected text a Spec lacks. A shared Roc bundle has one source.
missing_marker : Str, Str, List(Str) -> Try(Str, [NoneMissing])
missing_marker = |name, spec, expected|
	match expected.find_first(|marker| !spec.contains(marker)) {
		Ok(marker) => Ok(marker)
		Err(_) =>
			if name == "RocPackages" and spec.split_on("name \"roc-abc123\"").len() != 2 {
				Ok("exactly one source named roc-abc123")
			} else {
				Err(NoneMissing)
			}
	}

settings_module : Str, Str -> Str
settings_module = |name, settings|
	"import pf.Config\n${name} :: [].{\n\tsettings : List(Config.Setting)\n\tsettings = [${settings}]\n}\n"

build_base =
	\\Name("builds"), Executor("native", Adapter("fixture", "")), Resolver("fixture", ["assets"]), Environment("builder", []), Source("assets", "path:./assets")

build_settings =
	\\Build("app", [Execute("native"), Use("builder"), Inputs(["assets"]), Needs(["library"]), Run(["python3", "build.py", "", "two words", "$HOME"]), Output("dist/app")]), Build("library", [Execute("native"), Use("builder"), Run(["python3", "library.py"]), Output("dist/library")])

workflow_base =
	\\Name("workflows"), Executor("native", Adapter("fixture", "")), Environment("dev", []), Task("check.all", [Use("dev"), Run(["true"])]), Build("app", [Execute("native"), Use("dev"), Run(["true"]), Output("out")])

## Typed workflow references keep argv and repeated task and build steps.
workflow_steps =
	\\Workflow("ci", [RunWorkflow("leaf"), BuildArtifact("app"), RunWorkflow("leaf"), BuildArtifact("app")]), Workflow("leaf", [RunTask("check.all", ["", "two words", "\\"quoted\\"", "$HOME", "line\\nbreak", "--flag"])])

valid : Str, Str -> ConfigTest.Fixture
valid = |name, config| { name, kind: Valid, config }

rejected : Str, Str, Str -> ConfigTest.Fixture
rejected = |name, message, config| { name, kind: Rejected(message), config }

bad_quote : Str, Str, Str -> ConfigTest.Fixture
bad_quote = |name, message, config| { name, kind: BadQuote(message), config }

refused : Str, Str, Str -> ConfigTest.Fixture
refused = |name, message, config| { name, kind: Refused(message), config }

valid_fixtures : List(ConfigTest.Fixture)
valid_fixtures = [
	valid(
		"Valid",
		\\[Name("valid"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("dev", [Tools(["nix#git"])]), Shell("default", [Use("dev")])]
		,
	),
	valid(
		"EquivalentComposition",
		\\[Name("composed"), Systems(["x86_64-linux"]), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("base", [Tools(["nix#git"])]), Environment("dev", [Tools(["nix#git", "nix#python3"])]), Environment("release", [Tools(["nix#git", "nix#python3"]), Programs([Fetch("blueprint", Recipes.file("https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.5.0/blueprint-{system}"))])]), Shell("default", [Use("dev")]), Task("fmt", [Use("dev"), Run(["python3", "--version"])]), Task("test", [Use("dev"), Run(["git", "--version"])]), Task("args", [Use("dev"), Run(["python3", "-c", "import json, sys; print(json.dumps(sys.argv[1:]))", "configured argument"])])]
		,
	),
	valid(
		"Commands",
		\\[Name("commands"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Input("roc", "github:roc-lang/roc-overlay"), Environment("base", [Command("vcs", "nix#git"), Command("py", "nix#python3")]), Environment("dev", [Extend("base"), Overlays(["roc"]), Command("py", "nix#python312"), Command("roc-stable", "nix#rocpkgs.nightly")]), Shell("default", [Use("dev")])]
		,
	),
	valid(
		"ConfiguredTools",
		\\[Name("configured"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Input("rust", "github:oxalica/rust-overlay"), Environment("base", [Overlays(["rust"]), ToolWith("nix#rust-bin.stable.latest.default", [("targets", List([Str("x86_64-unknown-linux-musl")]))])]), Environment("dev", [Extend("base"), ToolWith("nix#rust-bin.stable.latest.default", [("targets", List([Str("aarch64-unknown-linux-musl")])), ("extensions", List([Str("rust-src")]))])]), Shell("default", [Use("dev")])]
		,
	),
	valid(
		"RocPackages",
		\\[Name("packages"), Environment("base", [RocPackages(["https://example.test/releases/download/1.0.0/abc123.tar.zst"])]), Environment("dev", [Extend("base"), RocPackages(["https://example.test/releases/download/1.0.0/abc123.tar.zst", "https://example.test/releases/download/2.0.0/def456.tar.zst"])]), Shell("default", [Use("dev")])]
		,
	),
	valid(
		"SystemTools",
		\\[Name("systems"), Systems(["x86_64-linux", "aarch64-darwin"]), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("base", [Tools(["nix#git"]), ToolsFor("x86_64-linux", ["nix#wayland"])]), Environment("dev", [Extend("base"), ToolsFor("x86_64-linux", ["nix#alsa-lib"])]), Shell("default", [Use("dev")])]
		,
	),
	# Builds use ordinary typed settings, including forward dependencies.
	valid("Builds", "[${build_base}, ${build_settings}]"),
	valid("Workflows", "[${workflow_base}, ${workflow_steps}]"),
]

## Setting cardinality is the platform's own rule: the Spec holds one value, so
## only `Lower.roc` can see a setting given twice or not at all.
lower_fixtures : List(ConfigTest.Fixture)
lower_fixtures = [
	rejected(
		"MissingName",
		"MissingName",
		\\[Environment("dev", [])]
		,
	),
	rejected(
		"DuplicateName",
		"DuplicateName",
		\\[Name("one"), Name("two")]
		,
	),
	rejected(
		"DuplicateSystems",
		"DuplicateSystems",
		\\[Name("duplicate"), Systems(["x86_64-linux"]), Systems(["aarch64-linux"])]
		,
	),
	rejected(
		"MissingShellUse",
		"MissingUse",
		\\[Name("invalid"), Shell("default", [])]
		,
	),
	rejected(
		"DuplicateShellUse",
		"DuplicateUse",
		\\[Name("invalid"), Environment("dev", []), Shell("default", [Use("dev"), Use("dev")])]
		,
	),
	rejected(
		"MissingTaskUse",
		"MissingUse",
		\\[Name("invalid"), Task("check", [Run(["git"])])]
		,
	),
	rejected(
		"DuplicateTaskUse",
		"DuplicateUse",
		\\[Name("invalid"), Environment("dev", []), Task("check", [Use("dev"), Use("dev"), Run(["git"])])]
		,
	),
	rejected(
		"MissingRun",
		"MissingRun",
		\\[Name("invalid"), Environment("dev", []), Task("check", [Use("dev")])]
		,
	),
	rejected(
		"DuplicateRun",
		"DuplicateRun",
		\\[Name("invalid"), Environment("dev", []), Task("check", [Use("dev"), Run(["git"]), Run(["git"])])]
		,
	),
	rejected(
		"DuplicateTools",
		"DuplicateTools",
		\\[Name("invalid"), Environment("dev", [Tools([]), Tools([])])]
		,
	),
	rejected(
		"DuplicateOverlays",
		"DuplicateOverlays",
		\\[Name("invalid"), Environment("dev", [Overlays([]), Overlays([])])]
		,
	),
	rejected(
		"DuplicateExtend",
		"DuplicateExtend",
		\\[Name("invalid"), Environment("base", []), Environment("dev", [Extend("base"), Extend("base")])]
		,
	),
	rejected(
		"DuplicateToolWith",
		"DuplicateToolWith",
		\\[Name("invalid"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("dev", [ToolWith("nix#zig", []), ToolWith("nix#zig", [])])]
		,
	),
	rejected(
		"PlainAndConfiguredTool",
		"tool is both plain and configured",
		\\[Name("invalid"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("base", [Tools(["nix#zig"])]), Environment("dev", [Extend("base"), ToolWith("nix#zig", [])])]
		,
	),
	rejected(
		"DuplicateRocPackages",
		"DuplicateRocPackages",
		\\[Name("invalid"), Environment("dev", [RocPackages([]), RocPackages([])])]
		,
	),
	rejected(
		"InsecureRocPackage",
		"invalid Roc package URL",
		\\[Name("invalid"), Environment("dev", [RocPackages(["http://example.test/abc123.tar.zst"])])]
		,
	),
	rejected(
		"UnhashedRocPackage",
		"invalid Roc package URL",
		\\[Name("invalid"), Environment("dev", [RocPackages(["https://example.test/archive.tar.gz"])])]
		,
	),
	rejected(
		"MissingBuildUse",
		"MissingUse",
		\\[Name("bad"), Build("app", [Run(["true"]), Output("out")])]
		,
	),
	rejected(
		"MissingBuildRun",
		"MissingRun",
		\\[Name("bad"), Build("app", [Use("builder"), Output("out")])]
		,
	),
	rejected(
		"MissingBuildOutput",
		"MissingOutput",
		\\[Name("bad"), Build("app", [Use("builder"), Run(["true"])])]
		,
	),
	rejected(
		"DuplicateBuildUse",
		"DuplicateUse",
		\\[Name("bad"), Build("app", [Use("builder"), Use("builder"), Run(["true"]), Output("out")])]
		,
	),
	rejected(
		"DuplicateBuildRun",
		"DuplicateRun",
		\\[Name("bad"), Build("app", [Use("builder"), Run(["true"]), Run(["true"]), Output("out")])]
		,
	),
	rejected(
		"DuplicateBuildOutput",
		"DuplicateOutput",
		\\[Name("bad"), Build("app", [Use("builder"), Run(["true"]), Output("out"), Output("out")])]
		,
	),
	rejected(
		"DuplicateBuildInputs",
		"DuplicateInputs",
		\\[Name("bad"), Build("app", [Execute("native"), Use("builder"), Inputs([]), Inputs([]), Run(["true"]), Output("out")])]
		,
	),
	rejected(
		"DuplicateBuildNeeds",
		"DuplicateNeeds",
		\\[Name("bad"), Build("app", [Execute("native"), Use("builder"), Needs([]), Needs([]), Run(["true"]), Output("out")])]
		,
	),
]

## A quoted value that is not what its type requires fails with that type's
## own `from_quote` message.
quote_fixtures : List(ConfigTest.Fixture)
quote_fixtures = [
	bad_quote(
		"BadWorkflowName",
		"invalid workflow name",
		\\[Name("bad"), Workflow("bad/name", [])]
		,
	),
	bad_quote(
		"BadRunWorkflowName",
		"invalid workflow name",
		\\[Name("bad"), Workflow("ci", [RunWorkflow("bad/name")])]
		,
	),
	bad_quote(
		"BadRunTaskName",
		"is not a task name",
		\\[Name("bad"), Workflow("ci", [RunTask("bad..name", [])])]
		,
	),
	bad_quote(
		"BadArtifactName",
		"is not an input name",
		\\[Name("bad"), Workflow("ci", [BuildArtifact("bad/name")])]
		,
	),
	# A tool with no source is refused where it is written, with both fixes.
	bad_quote(
		"UnqualifiedTool",
		"names no package source",
		\\[Name("bad"), Environment("dev", [Tools(["git"])])]
		,
	),
	bad_quote(
		"UnqualifiedCommand",
		"names no package source",
		\\[Name("bad"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("dev", [Command("roc-stable", "rocpkgs.nightly")])]
		,
	),
	bad_quote(
		"BadTool",
		"invalid tool reference",
		\\[Name("bad"), Environment("dev", [Tools(["one#two#three"])])]
		,
	),
	bad_quote(
		"BadSystem",
		"is not a system",
		\\[Name("bad"), Systems(["linux"])]
		,
	),
	bad_quote(
		"BadFlakeRef",
		"is not a flake reference",
		\\[Name("bad"), Input("tools", "roc-lang/roc-overlay")]
		,
	),
	bad_quote(
		"BadEnvName",
		"is not an environment or shell name",
		\\[Name("bad"), Environment("bad/name", [])]
		,
	),
]

## Witnesses that the shared validator runs at compile time: one reference
## rule, one graph rule, one argv rule, and two bounds on generated graphs.
core_fixtures : List(ConfigTest.Fixture)
core_fixtures = [
	refused(
		"AutoSource",
		"type mismatch",
		\\[Name("invalid"), Packages("default", Auto), Environment("dev", [])]
		,
	),
	rejected(
		"UnknownSource",
		"unknown source",
		\\[Name("invalid"), Environment("dev", [Tools(["missing#git"])])]
		,
	),
	rejected(
		"BuildCycle",
		"build cycle",
		\\[Name("bad"), Executor("native", Adapter("fixture", "")), Environment("builder", []), Build("app", [Execute("native"), Use("builder"), Needs(["library"]), Run(["true"]), Output("out")]), Build("library", [Execute("native"), Use("builder"), Needs(["app"]), Run(["true"]), Output("out")])]
		,
	),
	rejected("WorkflowNul", "NUL in argv", "[${workflow_base}, Workflow(\"ci\", [RunTask(\"check.all\", [Str.from_utf8([0]) ?? \"\"])])]"),
	rejected("BuildDepth", "build dependencies exceed 128 levels", build_chain(129)),
	rejected("WorkflowExpansion", "workflow expansion exceeds 4096 atomic steps", doubling_workflows(14)),
]

## `count` builds, each needing the one before it.
build_chain : U64 -> Str
build_chain = |count| {
	var $items = ["Name(\"deep\")", "Environment(\"builder\", [])", "Executor(\"native\", Adapter(\"fixture\", \"\"))"]
	var $index = 0
	while $index < count {
		needs = if $index == 0 "" else "Needs([\"b${($index - 1).to_str()}\"]), "
		$items = $items.append("Build(\"b${$index.to_str()}\", [Execute(\"native\"), Use(\"builder\"), ${needs}Run([\"true\"]), Output(\"out\")])")
		$index = $index + 1
	}
	"[${Str.join_with($items, ", ")}]"
}

## `count` workflows, each running the one before it twice; the first runs a task.
doubling_workflows : U64 -> Str
doubling_workflows = |count| {
	var $items = ["Name(\"graph\")", "Environment(\"dev\", [])", "Task(\"check\", [Use(\"dev\"), Run([\"true\"])])"]
	var $index = 0
	while $index < count {
		steps = if $index == 0 {
			"RunTask(\"check\", [])"
		} else {
			previous = "RunWorkflow(\"w${($index - 1).to_str()}\")"
			"${previous}, ${previous}"
		}
		$items = $items.append("Workflow(\"w${$index.to_str()}\", [${steps}])")
		$index = $index + 1
	}
	"[${Str.join_with($items, ", ")}]"
}

accepted : Process.Outcome
accepted = { code: 0, stdout: "No errors found", stderr: "" }

crashed : Str -> Process.Outcome
crashed = |text| { code: 1, stdout: "", stderr: text }

expect ConfigTest.fixtures.len() == 76
expect ConfigTest.selected(Full).len() == 79 and ConfigTest.selected(Smoke).map(|fixture| fixture.name) == ["Valid", "EquivalentComposition", "MissingName", "BadWorkflowName", "UnknownSource", "WorkflowExpansion", "Composed"]

# Every name is used once, and every name another table mentions exists.
expect {
	names = ConfigTest.selected(Full).map(|fixture| fixture.name)
	pair_names = ConfigTest.same_spec_pairs.fold([], |all, (left, right)| all.concat([left, right]))
	mentioned = ConfigTest.smoke_names.concat(ConfigTest.emitted_names).concat(pair_names).concat(ConfigTest.markers.map(|(name, _)| name))
	names.all(|name| names.keep_if(|other| other == name).len() == 1) and mentioned.all(|name| names.contains(name))
}

# Every compared or searched Spec is emitted.
expect ConfigTest.same_spec_pairs.all(|(left, right)| ConfigTest.emitted_names.contains(left) and ConfigTest.emitted_names.contains(right))
expect ConfigTest.markers.all(|(name, _)| ConfigTest.emitted_names.contains(name))

expect ConfigTest.app_source("../pf/main.roc", "[Name(\"x\")]") == "app [config] { pf: platform \"../pf/main.roc\" }\n\nconfig = [Name(\"x\")]\n"
expect ConfigTest.app_source("../pf/main.roc", "[Fetch(\"roc\", Recipes.roc_nightly(\"x\"))]") == "app [config] { pf: platform \"../pf/main.roc\" }\n\nimport pf.Recipes\n\nconfig = [Fetch(\"roc\", Recipes.roc_nightly(\"x\"))]\n"
expect ConfigTest.sources("https://example.test/pf.tar.zst").all(|(_, text)| !text.contains("blueprint-platform/main.roc"))
expect ConfigTest.sources("PLATFORM").keep_if(|(name, text)| name != "ProjectBuilds.roc" and name != "ProjectWorkflows.roc" and name != "ProjectTasks.roc" and name != "Releases.roc" and !text.contains("platform \"PLATFORM\"")) == []

# The fixture text keeps the escapes a Blueprint.roc would have.
expect workflow_steps.contains("\"\\\"quoted\\\"\", \"\$HOME\", \"line\\nbreak\"")

# Only the exit code, the two crash markers and the message make a rejection.
expect ConfigTest.problem(valid("A", ""), accepted) == ""
expect ConfigTest.problem(valid("A", ""), { ..accepted, code: 2 }) == "expected A to be accepted, got exit 2"
expect ConfigTest.problem(rejected("A", "MissingName", ""), crashed("compile time crash\nInvalid Blueprint.roc: MissingName: declare Name once")) == ""
expect ConfigTest.problem(rejected("A", "MissingName", ""), accepted) != ""
expect ConfigTest.problem(rejected("A", "MissingName", ""), crashed("Invalid Blueprint.roc: MissingName")) != ""
expect ConfigTest.problem(rejected("A", "MissingName", ""), crashed("compile time crash\nMissingName")) != ""
expect ConfigTest.problem(rejected("A", "MissingName", ""), crashed("compile time crash\nInvalid Blueprint.roc: DuplicateName")) != ""
expect ConfigTest.problem(rejected("A", "MissingName", ""), { ..crashed("compile time crash\nInvalid Blueprint.roc: MissingName"), code: 2 }) == "expected compile-time A rejection containing 'MissingName' (exit 1), got exit 2"
expect ConfigTest.problem(bad_quote("A", "is not a system", ""), crashed("invalid string: \"linux\" is not a system")) == ""
expect ConfigTest.problem(bad_quote("A", "is not a system", ""), crashed("\"linux\" is not a system")) == "expected checked-name rejection for A, got exit 1"

expect build_chain(2) == "[Name(\"deep\"), Environment(\"builder\", []), Executor(\"native\", Adapter(\"fixture\", \"\")), Build(\"b0\", [Execute(\"native\"), Use(\"builder\"), Run([\"true\"]), Output(\"out\")]), Build(\"b1\", [Execute(\"native\"), Use(\"builder\"), Needs([\"b0\"]), Run([\"true\"]), Output(\"out\")])]"
expect doubling_workflows(2).ends_with("Workflow(\"w0\", [RunTask(\"check\", [])]), Workflow(\"w1\", [RunWorkflow(\"w0\"), RunWorkflow(\"w0\")])]")

expect missing_marker("Builds", "(builds (a))", ["(builds "]) == Err(NoneMissing)
expect missing_marker("Builds", "(tasks ())", ["(builds "]) == Ok("(builds ")
expect missing_marker("RocPackages", "name \"roc-abc123\" name \"roc-abc123\"", []) == Ok("exactly one source named roc-abc123")
expect missing_marker("RocPackages", "name \"roc-abc123\"", []) == Err(NoneMissing)

expect spec_of(["A", "B"], ["a", "b"], "B") == Ok("b")
expect spec_of(["A", "B"], ["a", "b"], "C") == Err(NotEmitted)

## A recipe of the fixture's own, with its type, for the fixtures that need
## one beside `config`.
recipe_definition =
	\\
	\\
	\\tool : System -> Config.Download
	\\tool = |system|
	\\	match system {
	\\		"x86_64-linux" => Mirrored(File("https://example.test/1.0/tool-linux"), ["https://mirror.example.test/1.0/tool-linux"])
	\\		_ => Unavailable
	\\	}
	\\
	\\roc_stable = Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-18-1df370f"))

## Fetched programs and expected tools: what is accepted, and each mistake
## with the check that refuses it. A quoted value is refused by its own type
## where it is written; a value the list cannot hold is a type error; a
## misspelt binding is no name at all; and what only the whole configuration
## shows is lowering's or the shared validator's.
program_fixtures : List(ConfigTest.Fixture)
program_fixtures = [
	# Recipes from the platform, a template and a function of the fixture's
	# own, one unavailable on a declared system; a shared binding; programs
	# and expectations inherited parent first.
	valid(
		"Programs",
		"[Name(\"programs\"), Systems([\"x86_64-linux\", \"x86_64-windows\"]), Environment(\"base\", [Programs([roc_stable]), Expect([\"git\"])]), Environment(\"dev\", [Extend(\"base\"), Programs([Fetch(\"tool\", tool), roc_stable, Fetch(\"notes\", Recipes.file(\"https://example.test/{os}/notes-{arch}\"))]), Expect([\"gh\"])]), Task(\"check\", [Use(\"dev\"), Run([\"scripts/check_all.roc\"])])]${recipe_definition}",
	),
	valid(
		"SystemText",
		"[Name(\"programs\"), Systems([\"x86_64-linux\"]), Environment(\"dev\", [Programs([Fetch(\"tool\", |system| if system == \"x86_64-linux\" File(\"https://example.test/tool-\${system.to_str()}\") else Unavailable)])])]",
	),
	rejected(
		"DuplicatePrograms",
		"DuplicatePrograms: environment dev",
		\\[Name("invalid"), Environment("dev", [Programs([]), Programs([])])]
		,
	),
	rejected(
		"DuplicateExpect",
		"DuplicateExpect: environment dev",
		\\[Name("invalid"), Environment("dev", [Expect(["git"]), Expect(["gh"])])]
		,
	),
	rejected(
		"UnavailableEverywhere",
		"Fetch roc-stable: its recipe answers Unavailable",
		\\[Name("invalid"), Systems(["riscv64-linux"]), Environment("dev", [Programs([Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-18-1df370f"))])])]
		,
	),
	rejected(
		"TwoProgramsOneName",
		"two different programs are named tool",
		\\[Name("invalid"), Environment("one", [Programs([Fetch("tool", Recipes.file("https://example.test/1.0/tool-{system}"))])]), Environment("two", [Programs([Fetch("tool", Recipes.file("https://example.test/2.0/tool-{system}"))])])]
		,
	),
	rejected(
		"DuplicateMirror",
		"program tool on x86_64-linux names a URL twice",
		\\[Name("invalid"), Systems(["x86_64-linux"]), Environment("dev", [Programs([Fetch("tool", |_| Mirrored(File("https://example.test/tool"), ["https://example.test/tool"]))])])]
		,
	),
	# A URL that is assembled is not checked where it is written: the shared
	# validator refuses it, with the URL on a line of its own.
	rejected(
		"InsecureAssembledUrl",
		"has a URL that is not",
		"[Name(\"invalid\"), Systems([\"x86_64-linux\"]), Environment(\"dev\", [Programs([Fetch(\"tool\", |system| File(\"http://example.test/tool-\${system.to_str()}\"))])])]",
	),
	rejected(
		"ProgramAndCommand",
		"has roc-stable as both",
		\\[Name("invalid"), Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))), Environment("base", [Command("roc-stable", "nix#rocpkgs.nightly")]), Environment("dev", [Extend("base"), Programs([Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-18-1df370f"))])])]
		,
	),
	rejected(
		"ProgramAndExpect",
		"has tool as both a program",
		\\[Name("invalid"), Environment("dev", [Programs([Fetch("tool", Recipes.file("https://example.test/tool"))]), Expect(["tool"])])]
		,
	),
	# A misspelt system is refused in a pattern and beside `==`, though the
	# branch it guards would never be taken.
	bad_quote(
		"SystemTypoInPattern",
		"is not an operating system Blueprint",
		"[Name(\"bad\"), Environment(\"dev\", [Programs([Fetch(\"tool\", typo)])])]\n\ntypo : System -> Config.Download\ntypo = |system|\n\tmatch system {\n\t\t\"x86_64-linux\" => File(\"https://example.test/tool\")\n\t\t\"aarch64-linx\" => File(\"https://example.test/tool-arm\")\n\t\t_ => Unavailable\n\t}",
	),
	bad_quote(
		"SystemTypoInEquality",
		"is not an architecture Blueprint knows",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("tool", |system| if system == "x86-linux" Unavailable else File("https://example.test/tool"))])])]
		,
	),
	bad_quote(
		"SystemTypoInSystems",
		"is not a system",
		\\[Name("bad"), Systems(["x86_64-linux", "macos"])]
		,
	),
	bad_quote(
		"SwappedArchiveArguments",
		"is a URL, not the path of a program",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("tool", |_| Archive("tool/bin/tool", TarGz, "https://example.test/tool.tar.gz"))])])]
		,
	),
	bad_quote(
		"BadMember",
		"is not the path of a program inside",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("tool", |_| Archive("https://example.test/tool.tar.gz", TarGz, "../bin/tool"))])])]
		,
	),
	bad_quote(
		"BadNightlyTag",
		"is not a Roc nightly tag",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("roc-stable", Recipes.roc_nightly("v1.0"))])])]
		,
	),
	bad_quote(
		"InsecureUrl",
		"is not a download URL",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("tool", |_| File("http://example.test/tool"))])])]
		,
	),
	bad_quote(
		"InsecureMirror",
		"is not a download URL",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("tool", |_| Mirrored(File("https://example.test/tool"), ["http://mirror.example.test/tool"]))])])]
		,
	),
	bad_quote(
		"InsecureTemplate",
		"is not a download URL",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("tool", Recipes.file("http://example.test/tool-{system}"))])])]
		,
	),
	bad_quote(
		"BadPlaceholder",
		"has a placeholder other than",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("tool", Recipes.file("https://example.test/tool-{sytem}"))])])]
		,
	),
	bad_quote(
		"PlaceholderInHost",
		"has a placeholder in its host",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("tool", Recipes.file("https://{os}.example.test/tool"))])])]
		,
	),
	bad_quote(
		"BadFetchName",
		"is not a program name",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("bin/tool", |_| Unavailable)])])]
		,
	),
	bad_quote(
		"BadExpectName",
		"is not a program name",
		\\[Name("bad"), Environment("dev", [Expect(["/usr/bin/git"])])]
		,
	),
	# A program is a value: its name alone is not one, and a binding that is
	# misspelt is not in scope.
	refused(
		"NameForProgram",
		"from_quote",
		\\[Name("bad"), Environment("dev", [Programs(["roc-stable"])])]
		,
	),
	refused(
		"MisspeltBinding",
		"Nothing is named roc_stabel in this scope",
		"[Name(\"bad\"), Environment(\"dev\", [Programs([roc_stabel])])]${recipe_definition}",
	),
	# A recipe that cannot answer says so itself, and the compiler says where.
	refused(
		"CrashingRecipe",
		"tool 2.0 has no build for x86_64-darwin",
		\\[Name("bad"), Environment("dev", [Programs([Fetch("tool", |system| if system == "x86_64-darwin" { crash "tool 2.0 has no build for x86_64-darwin" } else File("https://example.test/tool"))])])]
		,
	),
	# The trap of this compiler: a System is not text, so it cannot stand in a
	# URL as it is. `Recipes.file` and `system.to_str()` are the ways to write it.
	refused(
		"SystemInUrl",
		"from_interpolation",
		"[Name(\"bad\"), Environment(\"dev\", [Programs([Fetch(\"tool\", |system| File(\"https://example.test/tool-\${system}\"))])])]",
	),
]
