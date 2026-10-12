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
	## invalid Blueprint with this message, or reject a quoted name with it.
	Kind : [Valid, Rejected(Str), BadQuote(Str)]

	Fixture : { name : Str, kind : Kind, config : Str }

	## The whole suite, or the few fixtures a served bundle is smoke-tested with.
	Subset : [Full, Smoke]

	fixtures : List(Fixture)
	fixtures = valid_fixtures.concat(lower_fixtures).concat(quote_fixtures).concat(core_fixtures)

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
		("Builds", ["(minor 7)", "(requires (\"sources\" \"builds\"))", "(build_sources ", "(builds "]),
		(
			"Workflows",
			[
				"(minor 7)",
				"(requires (\"builds\" \"workflows\"))",
				"(workflows ",
				"(RunTask \"check.all\" (\"\" \"two words\" \"\\\"quoted\\\"\" \"\$HOME\" \"line\\nbreak\" \"--flag\"))",
			],
		),
		("SystemTools", ["(requires (\"system-tools\"))", "(system_tools ", "(system \"x86_64-linux\")"]),
		("Commands", ["(requires (\"commands\"))", "(commands ", "(name \"roc-stable\")"]),
		(
			"ConfiguredTools",
			[
				"(requires (\"configured-tools\"))",
				"(configured_tools ",
				"(name \"rust-bin.stable.latest.default\")",
				"(Str \"rust-src\")",
			],
		),
		(
			"RocPackages",
			[
				"(requires (\"sources\" \"roc-packages\"))",
				"(roc_packages ",
				"(ref \"tarball+https://example.test/releases/download/1.0.0/abc123.tar.zst\")",
			],
		),
		(
			"Programs",
			[
				"(requires (\"programs\" \"expects\"))",
				"(programs ",
				"(environment_programs ",
				"(expects ",
				"(url \"https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_x86_64-2026-10-04-130536d.tar.gz\")",
				"(unpack TarGz)",
				"(path \"roc_nightly-windows_x86_64-2026-10-04-130536d/roc.exe\")",
				"(unpack Zip)",
				"(url \"https://example.test/releases/1.0/tool-x86_64-linux\")",
				"(unpack File)",
				"(programs (\"roc-stable\" \"tool\"))",
				"(programs (\"git\" \"gh\"))",
			],
		),
	]

	## A fixture's app. One that names a recipe of the platform imports them.
	app_source : Str, Str -> Str
	app_source = |platform_ref, config| {
		prelude = if config.contains("Recipes.") "import pf.Recipes\n\n" else ""
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
			BadQuote(message) =>
				if outcome.code == 1 and log.contains("invalid string") and log.contains(message) {
					""
				} else {
					"expected checked-name rejection for ${fixture.name}, got exit ${code}"
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
			"${count(is_valid)} valid configs accepted; ${count(is_rejected)} semantic errors and ${count(is_bad_quote)} checked-name errors rejected at compile time; equivalent Spec verified",
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
is_rejected = |fixture| !is_valid(fixture) and !is_bad_quote(fixture)

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
	\\Name("builds"), Environment("builder", []), Source("assets", "path:./assets")

build_settings =
	\\Build("app", [Use("builder"), Inputs(["assets"]), Needs(["library"]), Run(["python3", "build.py", "", "two words", "$HOME"]), Output("dist/app")]), Build("library", [Use("builder"), Run(["python3", "library.py"]), Output("dist/library")])

workflow_base =
	\\Name("workflows"), Environment("dev", []), Task("check.all", [Use("dev"), Run(["true"])]), Build("app", [Use("dev"), Run(["true"]), Output("out")])

## Typed workflow references keep argv and repeated task and build steps.
workflow_steps =
	\\Workflow("ci", [RunWorkflow("leaf"), BuildArtifact("app"), RunWorkflow("leaf"), BuildArtifact("app")]), Workflow("leaf", [RunTask("check.all", ["", "two words", "\\"quoted\\"", "$HOME", "line\\nbreak", "--flag"])])

valid : Str, Str -> ConfigTest.Fixture
valid = |name, config| { name, kind: Valid, config }

rejected : Str, Str, Str -> ConfigTest.Fixture
rejected = |name, message, config| { name, kind: Rejected(message), config }

bad_quote : Str, Str, Str -> ConfigTest.Fixture
bad_quote = |name, message, config| { name, kind: BadQuote(message), config }

valid_fixtures : List(ConfigTest.Fixture)
valid_fixtures = [
	valid(
		"Valid",
		\\[Name("valid"), Environment("dev", [Tools(["git"])]), Shell("default", [Use("dev")])]
		,
	),
	valid(
		"EquivalentComposition",
		\\[Name("composed"), Systems(["x86_64-linux"]), Fetch("blueprint", |system| File(Str.concat("https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.5.0/blueprint-", system))), Environment("base", [Tools(["git"])]), Environment("dev", [Tools(["git", "python3"])]), Environment("release", [Tools(["git", "python3"]), Programs(["blueprint"])]), Shell("default", [Use("dev")]), Task("fmt", [Use("dev"), Run(["python3", "--version"])]), Task("test", [Use("dev"), Run(["git", "--version"])]), Task("args", [Use("dev"), Run(["python3", "-c", "import json, sys; print(json.dumps(sys.argv[1:]))", "configured argument"])])]
		,
	),
	valid(
		"Commands",
		\\[Name("commands"), Overlay("roc", "github:roc-lang/roc-overlay"), Environment("base", [Command("vcs", "git"), Command("py", "python3")]), Environment("dev", [Extend("base"), Overlays(["roc"]), Command("py", "python312"), Command("roc-stable", "rocpkgs.nightly")]), Shell("default", [Use("dev")])]
		,
	),
	valid(
		"ConfiguredTools",
		\\[Name("configured"), Overlay("rust", "github:oxalica/rust-overlay"), Environment("base", [Overlays(["rust"]), ToolWith("rust-bin.stable.latest.default", [("targets", List([Str("x86_64-unknown-linux-musl")]))])]), Environment("dev", [Extend("base"), ToolWith("rust-bin.stable.latest.default", [("targets", List([Str("aarch64-unknown-linux-musl")])), ("extensions", List([Str("rust-src")]))])]), Shell("default", [Use("dev")])]
		,
	),
	valid(
		"RocPackages",
		\\[Name("packages"), Environment("base", [RocPackages(["https://example.test/releases/download/1.0.0/abc123.tar.zst"])]), Environment("dev", [Extend("base"), RocPackages(["https://example.test/releases/download/1.0.0/abc123.tar.zst", "https://example.test/releases/download/2.0.0/def456.tar.zst"])]), Shell("default", [Use("dev")])]
		,
	),
	valid(
		"SystemTools",
		\\[Name("systems"), Systems(["x86_64-linux", "aarch64-darwin"]), Environment("base", [Tools(["git"]), ToolsFor("x86_64-linux", ["wayland"])]), Environment("dev", [Extend("base"), ToolsFor("x86_64-linux", ["alsa-lib"])]), Shell("default", [Use("dev")])]
		,
	),
	# Recipes from the platform and from a lambda, one of them unavailable on a
	# declared system; selections and expectations inherit parent first.
	valid(
		"Programs",
		\\[Name("programs"), Systems(["x86_64-linux", "x86_64-windows"]), Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-04-130536d")), Fetch("tool", |system| if system == "x86_64-linux" File(Str.concat("https://example.test/releases/1.0/tool-", system)) else Unavailable), Environment("base", [Programs(["roc-stable"]), Expect(["git"])]), Environment("dev", [Extend("base"), Programs(["tool", "roc-stable"]), Expect(["gh"])]), Task("check", [Use("dev"), Run(["scripts/check_all.roc"])])]
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
		\\[Name("invalid"), Environment("dev", [ToolWith("zig", []), ToolWith("zig", [])])]
		,
	),
	rejected(
		"PlainAndConfiguredTool",
		"tool is both plain and configured",
		\\[Name("invalid"), Environment("base", [Tools(["zig"])]), Environment("dev", [Extend("base"), ToolWith("zig", [])])]
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
		"DuplicateFetch",
		"DuplicateFetch: tool",
		\\[Name("invalid"), Fetch("tool", |_| File("https://example.test/tool")), Fetch("tool", |_| Unavailable)]
		,
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
	# What a recipe calls invalid is reported in its own words, never a crash
	# of the recipe. The compiler wraps a long message, so each of these is
	# matched by its start; `Lower.roc` holds the whole text.
	rejected(
		"InvalidRecipe",
		"Fetch roc-stable: \"v1.0\" is not a Roc nightly tag",
		\\[Name("invalid"), Fetch("roc-stable", Recipes.roc_nightly("v1.0"))]
		,
	),
	rejected(
		"InvalidLocalRecipe",
		"Fetch tool: no build for x86_64-linux",
		\\[Name("invalid"), Systems(["x86_64-linux"]), Fetch("tool", |system| Invalid(Str.concat("no build for ", system)))]
		,
	),
	rejected(
		"UnavailableEverywhere",
		"Fetch roc-stable: its recipe answers Unavailable",
		\\[Name("invalid"), Systems(["riscv64-linux"]), Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-04-130536d"))]
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
		\\[Name("bad"), Build("app", [Use("builder"), Inputs([]), Inputs([]), Run(["true"]), Output("out")])]
		,
	),
	rejected(
		"DuplicateBuildNeeds",
		"DuplicateNeeds",
		\\[Name("bad"), Build("app", [Use("builder"), Needs([]), Needs([]), Run(["true"]), Output("out")])]
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
		\\[Name("bad"), Overlay("tools", "roc-lang/roc-overlay")]
		,
	),
	bad_quote(
		"BadEnvName",
		"is not an environment or shell name",
		\\[Name("bad"), Environment("bad/name", [])]
		,
	),
	bad_quote(
		"BadFetchName",
		"is not a program name",
		\\[Name("bad"), Fetch("bin/tool", |_| Unavailable)]
		,
	),
	bad_quote(
		"BadProgramsName",
		"is not a program name",
		\\[Name("bad"), Environment("dev", [Programs(["-tool"])])]
		,
	),
	bad_quote(
		"BadExpectName",
		"is not a program name",
		\\[Name("bad"), Environment("dev", [Expect(["/usr/bin/git"])])]
		,
	),
]

## Witnesses that the shared validator runs at compile time: one reference
## rule, one graph rule, one argv rule, two bounds on generated graphs, and
## what it makes of a recipe's answers.
core_fixtures : List(ConfigTest.Fixture)
core_fixtures = [
	rejected(
		"UnknownSource",
		"unknown source",
		\\[Name("invalid"), Environment("dev", [Tools(["missing#git"])])]
		,
	),
	rejected(
		"BuildCycle",
		"build cycle",
		\\[Name("bad"), Environment("builder", []), Build("app", [Use("builder"), Needs(["library"]), Run(["true"]), Output("out")]), Build("library", [Use("builder"), Needs(["app"]), Run(["true"]), Output("out")])]
		,
	),
	rejected(
		"InsecureDownload",
		"is not a download URL",
		\\[Name("invalid"), Systems(["x86_64-linux"]), Fetch("tool", |_| File("http://example.test/tool"))]
		,
	),
	rejected(
		"UndeclaredProgram",
		"selects program roc-stable",
		\\[Name("invalid"), Environment("dev", [Programs(["roc-stable"])])]
		,
	),
	rejected(
		"ProgramAndCommand",
		"has roc-stable as both",
		\\[Name("invalid"), Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-04-130536d")), Environment("base", [Command("roc-stable", "rocpkgs.nightly")]), Environment("dev", [Extend("base"), Programs(["roc-stable"])])]
		,
	),
	rejected(
		"ProgramAndExpect",
		"has tool as both a program",
		\\[Name("invalid"), Fetch("tool", |_| File("https://example.test/tool")), Environment("dev", [Programs(["tool"]), Expect(["tool"])])]
		,
	),
	rejected("WorkflowNul", "NUL in argv", "[${workflow_base}, Workflow(\"ci\", [RunTask(\"check.all\", [Str.from_utf8([0]) ?? \"\"])])]"),
	rejected("BuildDepth", "build dependencies exceed 128 levels", build_chain(129)),
	rejected("WorkflowExpansion", "workflow expansion exceeds 4096 atomic steps", doubling_workflows(14)),
]

## `count` builds, each needing the one before it.
build_chain : U64 -> Str
build_chain = |count| {
	var $items = ["Name(\"deep\")", "Environment(\"builder\", [])"]
	var $index = 0
	while $index < count {
		needs = if $index == 0 "" else "Needs([\"b${($index - 1).to_str()}\"]), "
		$items = $items.append("Build(\"b${$index.to_str()}\", [Use(\"builder\"), ${needs}Run([\"true\"]), Output(\"out\")])")
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

expect ConfigTest.fixtures.len() == 60
expect ConfigTest.selected(Full).len() == 63 and ConfigTest.selected(Smoke).map(|fixture| fixture.name) == ["Valid", "EquivalentComposition", "MissingName", "BadWorkflowName", "UnknownSource", "WorkflowExpansion", "Composed"]

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

expect build_chain(2) == "[Name(\"deep\"), Environment(\"builder\", []), Build(\"b0\", [Use(\"builder\"), Run([\"true\"]), Output(\"out\")]), Build(\"b1\", [Use(\"builder\"), Needs([\"b0\"]), Run([\"true\"]), Output(\"out\")])]"
expect doubling_workflows(2).ends_with("Workflow(\"w0\", [RunTask(\"check\", [])]), Workflow(\"w1\", [RunWorkflow(\"w0\"), RunWorkflow(\"w0\")])]")

expect missing_marker("Builds", "(builds (a))", ["(builds "]) == Err(NoneMissing)
expect missing_marker("Builds", "(tasks ())", ["(builds "]) == Ok("(builds ")
expect missing_marker("RocPackages", "name \"roc-abc123\" name \"roc-abc123\"", []) == Ok("exactly one source named roc-abc123")
expect missing_marker("RocPackages", "name \"roc-abc123\"", []) == Err(NoneMissing)

expect spec_of(["A", "B"], ["a", "b"], "B") == Ok("b")
expect spec_of(["A", "B"], ["a", "b"], "C") == Err(NotEmitted)
