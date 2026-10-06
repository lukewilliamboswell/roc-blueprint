import cli.Path
import BuildHarness
import Script

## The workflow gates, against the real `./blueprint` and real Nix.
##
## Every CLI, compiler, task and build is real. Tasks and the recording `nix`
## each leave a record in one directory outside the project, so the order of
## effects within one `blueprint workflow` is observed and no observation
## changes the project a build copies.
BuildWorkflowGates := [].{

	## One expected effect: a task with its arguments, or a build of an artifact.
	Step : { kind : Str, argv : List(Str) }

	## The arguments the `app` build and the `leaf` workflow's task receive,
	## and the JSON the build must make of them.
	arguments = ["", "two words", "--", "--literal", "$HOME", "$(touch INJECTED)", "; touch INJECTED", "a'b\"c", "line\nbreak", "*", "$"]

	arguments_json = "[\"\",\"two words\",\"--\",\"--literal\",\"$HOME\",\"$(touch INJECTED)\",\"; touch INJECTED\",\"a'b\\\"c\",\"line\\nbreak\",\"*\",\"$\"]"

	task : List(Str) -> Step
	task = |argv| { kind: "task", argv }

	## The `record` task: its configured argument, then the workflow's.
	record : List(Str) -> Step
	record = |extra| task(["record", "configured argument"].concat(extra))

	build : Str -> Step
	build = |name| { kind: "build", argv: [name] }

	## The line a fixture task prints: its arguments, each followed by a NUL
	## byte, in hexadecimal.
	task_line : List(Str) -> Str
	task_line = |argv| "task ${BuildHarness.hex(argv.fold([], |bytes, arg| bytes.concat(arg.to_utf8()).append(0)))}"

	## What one recorded `nix` call did, if it was a build or ran a task:
	## the artifact a `nix build` named, or the command `nix develop` ran.
	observe : List(Str) -> [Built(Str), Ran(List(Str)), Other, Ambiguous]
	observe = |argv|
		match argv {
			["build", ..] =>
				match argv.keep_if(|arg| arg.contains("#packages.")) {
					[installable] => Built(installable.split_on(".").last() ?? "")
					_ => Ambiguous
				}

			["develop", ..] =>
				match argv.find_first_index(|arg| arg == "--command") {
					Ok(index) => Ran(argv.drop_first(index + 1))
					Err(_) => Other
				}

			_ => Other
		}

	## What stdout must hold for these steps: a store path for each build that
	## succeeded and its own line for each task. A failed build has an
	## invocation but must not publish a store path.
	published : List(Step), Bool -> List(Str)
	published = |steps, good| {
		successful = if good or steps.last().map_ok(|step| step.kind) != Ok("build") steps else steps.drop_last(1)
		successful.map(|step| if step.kind == "build" "build" else task_line(step.argv))
	}

	## Run every gate, then the smoke test of a copy of `examples/artifacts`.
	run! : Path => Try({}, _)
	run! = |root| BuildHarness.run!(root, "workflows", gates!)
}

State : { place : BuildHarness.Layout, config : Str }

first_source : List(U8)
first_source = "first".to_utf8().append(0).concat("revision\n".to_utf8())

second_source : List(U8)
second_source = "second".to_utf8().append(0).concat("revision".to_utf8()).append(255).append('\n')

prepared_bytes : List(U8)
prepared_bytes = "task-generated".to_utf8().append(0).concat("bytes\n".to_utf8())

edited_bytes : List(U8)
edited_bytes = "changed by task".to_utf8().append(0).append(254).append('\n')

asset_bytes : List(U8)
asset_bytes = "locked workflow asset\n".to_utf8()

dirty_bytes : List(U8)
dirty_bytes = "dirty locked source".to_utf8().append(0).append('\n')

text : List(U8) -> Str
text = |bytes| Str.from_utf8_lossy(bytes)

read! : Str => Try(List(U8), _)
read! = |file| Path.read_bytes!(Path.utf8(file))

count : Str, Str -> U64
count = |whole, part| whole.split_on(part).len() - 1

## Everything a workflow may not touch when it must have no effect.
state! : BuildHarness.Suite, BuildHarness.Layout => Try((List(BuildHarness.Event), List(Str), List(Str)), _)
state! = |suite, place| Ok((BuildHarness.events!(suite)?, BuildHarness.snapshot!(place.workspace)?, BuildHarness.snapshot!(place.generated)?))

gates! : BuildHarness.Suite => Try({}, _)
gates! = |suite| {
	BuildHarness.warm!(suite)?
	state = prepare!(suite)?
	place = state.place
	project = place.project
	record = BuildWorkflowGates.record
	task = BuildWorkflowGates.task
	build = BuildWorkflowGates.build
	arguments = BuildWorkflowGates.arguments

	ci = workflow!(suite, place, "ci", [task(["prepare"]), build("app"), record(["after build"])], "")?
	_ = artifact!(ci.outputs.first() ?? "", first_source, prepared_bytes)?
	BuildHarness.require!(read!("${project}/task-produced.bin")? == prepared_bytes, "task-generated project source missing")?
	Script.pass!("real task -> build -> task, exact artifact/build argv")?
	noops!(suite, place)?

	_ = workflow!(suite, place, "nested", [record(["first"]), record(arguments), record(["middle"]), record(arguments), record(arguments), record(["last"])], "")?
	Script.pass!("nested and repeated workflows preserve exact order and argv")?

	failed_task = workflow!(suite, place, "task-failure", [record(["before failure"]), task(["fail"])], "intentional task failure")?
	BuildHarness.require!(failed_task.ran.err.contains("task fail exited with code 23"), "task failure lost its real exit status")?
	failed_build = workflow!(suite, place, "build-failure", [record(["before failure"]), build("fail")], "intentional build failure")?
	BuildHarness.require!(failed_build.ran.err.contains("builder failed with exit code 29"), "build failure lost its real exit status")?
	Script.pass!("failing task/build prevents all later task and build effects")?

	fresh = workflow!(suite, place, "fresh", [build("app"), task(["edit"]), build("app"), record(["after refresh"])], "")?
	(before_edit, after_edit) = match fresh.outputs {
		[one, two] => (one, two)
		_ => ("", "")
	}
	first_library = artifact!(before_edit, first_source, prepared_bytes)?
	second_library = artifact!(after_edit, second_source, edited_bytes)?
	BuildHarness.require!(before_edit != after_edit, "edited source reused stale app")?
	BuildHarness.require!(first_library != second_library, "edited source reused stale dependency")?
	BuildHarness.require!(read!("${project}/source.bin")? == second_source, "edit task did not change project source")?
	BuildHarness.require!(read!("${project}/task-produced.bin")? == edited_bytes, "edit task did not change generated source")?
	Script.pass!("build -> source-editing task -> same build refreshes dependency bytes")?

	repeat = [build("app"), record(["unchanged"]), build("app")]
	repeated = workflow!(suite, place, "repeat", repeat, "")?
	cached = repeated.outputs.first() ?? ""
	BuildHarness.require!(repeated.outputs == [cached, cached], "unchanged repeat changed store identity")?
	_ = artifact!(cached, second_source, edited_bytes)?
	Script.pass!("repeated explicit builds retain unchanged store identity")?

	reject_capabilities!(suite, state)?

	# Remove only disposable old roots so they cannot become ordinary inputs.
	Path.delete_all!(Path.utf8(place.generated))?
	outside = { ..place, workspace: "${suite.work}/outside-work", generated: "${suite.work}/outside-generated" }
	moved = workflow!(suite, outside, "repeat", repeat, "")?
	BuildHarness.require!(moved.outputs == [cached, cached], "out-of-tree layout changed artifact")?
	_ = artifact!(cached, second_source, edited_bytes)?
	BuildHarness.require!(
		(Path.is_dir!(Path.utf8(outside.generated)) ?? Bool.False) and !BuildHarness.exists!(outside.workspace),
		"caller-selected out-of-tree roots not used",
	)?
	BuildHarness.require!(
		!BuildHarness.exists!("${suite.caller}/Blueprint.lock") and !BuildHarness.exists!("${suite.caller}/.blueprint"),
		"invocation cwd was used",
	)?
	Script.pass!("out-of-tree workspace/generated roots from unrelated cwd")?

	# Preflight succeeds initially; the intervening task dirties locked bytes.
	# The second build must verify again rather than return its earlier output.
	dirty = workflow!(suite, outside, "dirty-source", [build("app"), task(["dirty"])], "blueprint update")?
	BuildHarness.require!(dirty.outputs == [cached], "dirty second build published a stale output")?
	BuildHarness.require!(count(dirty.ran.err, "built app:") == 1, "the dirty workflow reported another build:\n${dirty.ran.err}")?
	_ = artifact!(cached, second_source, edited_bytes)?
	BuildHarness.require!(read!("${project}/assets/message.txt")? == dirty_bytes, "dirty task did not execute")?
	(events, workspace, generated) = state!(suite, outside)?
	_ = BuildHarness.refused!(suite, outside, ["workflow", "ci"], "blueprint update")?
	(later_events, later_workspace, later_generated) = state!(suite, outside)?
	recent = later_events.drop_first(events.len())
	BuildHarness.require!(
		recent.all(|entry| entry.kind == "nix" and entry.argv.take_first(2) == ["hash", "path"]),
		"dirty authority allowed user effects: ${Str.inspect(recent)}",
	)?
	BuildHarness.require!(later_workspace == workspace and later_generated == generated, "dirty initial source staged files")?
	Script.pass!("dirty locked source aborts later build without stale publication")?
	checks = BuildHarness.names!(suite.logs)?.keep_if(|name| name.ends_with(".argv")).len()
	Script.pass!("workflows, real Nix: all gates passed (${checks.to_str()} process checks, ${later_events.keep_if(|entry| entry.kind == "nix").len().to_str()} Nix calls)")?
	example_smoke!(suite)
}

prepare! : BuildHarness.Suite => Try(State, _)
prepare! = |suite| {
	project = "${suite.work}/project"
	fixture = "${suite.root}/fixtures/workflows"
	Path.create_all!(Path.utf8("${project}/assets"))?
	for name in ["task.roc", "build.roc", "assets/message.txt"] {
		Path.write_bytes!(Path.utf8("${project}/${name}"), read!("${fixture}/${name}")?)?
	}
	BuildHarness.require!(read!("${project}/assets/message.txt")? == asset_bytes, "fixture asset differs from independent expected bytes")?
	config = BuildHarness.render(
		Path.read_utf8!(Path.utf8("${fixture}/Blueprint.roc.in"))?,
		BuildHarness.pinned_values(suite.pins).concat(
			[("PLATFORM", BuildHarness.relative(project, "${suite.root}/blueprint-platform/main.roc")), ("EVENTS", suite.events)],
		),
	)
	BuildHarness.require!(!config.contains("@"), "the fixture template has a placeholder nothing fills:\n${config}")?
	Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), config)?
	Path.write_bytes!(Path.utf8("${project}/source.bin"), first_source)?
	place = BuildHarness.layout(project)
	_ = BuildHarness.ok!(suite, place, ["check"])?
	for name in ["ci", "empty", "nested-empty"] {
		before = BuildHarness.events!(suite)?
		refused = BuildHarness.refused!(suite, place, ["workflow", name], "blueprint update")?
		BuildHarness.require!(refused.stdout.is_empty(), "${name}: missing authority produced stdout")?
		BuildHarness.require!(BuildHarness.events!(suite)? == before, "${name}: missing authority executed an operation")?
		BuildHarness.require!(
			!BuildHarness.exists!(place.workspace) and !BuildHarness.exists!(place.generated),
			"${name}: missing authority staged files",
		)?
	}
	Script.pass!("missing authority rejects productive and no-op workflows without effects")?
	_ = BuildHarness.ok!(suite, place, ["update"])?
	BuildHarness.require!(Path.is_file!(Path.utf8(place.lock)) ?? Bool.False, "update did not initialize authority")?
	authority = text(read!(place.lock)?)
	# Offline, an update can only arrive at the committed pins.
	for source in [suite.pins.nixpkgs, suite.pins.overlay].concat(suite.pins.bundles) {
		BuildHarness.require!(authority.contains(source.nar_hash), "the authority does not pin ${source.ref} at ${source.nar_hash}")?
	}
	BuildHarness.mode!("444", Path.utf8(place.lock))?
	Ok({ place, config })
}

## Run a workflow and compare what it did, in order, with `expected`: the
## recorded tasks and builds, the commands Nix ran for the tasks, and stdout.
## With `refusal`, the workflow must fail saying it.
workflow! : BuildHarness.Suite, BuildHarness.Layout, Str, List(BuildWorkflowGates.Step), Str => Try({ outputs : List(Str), ran : BuildHarness.Outcome }, _)
workflow! = |suite, place, name, expected, refusal| {
	good = refusal.is_empty()
	start = BuildHarness.events!(suite)?.len()
	ran = if good BuildHarness.ok!(suite, place, ["workflow", name])? else BuildHarness.refused!(suite, place, ["workflow", name], refusal)?
	var $observed = []
	var $commands = []
	for entry in BuildHarness.events!(suite)?.drop_first(start) {
		if entry.kind == "task" {
			$observed = $observed.append(BuildWorkflowGates.task(entry.argv))
		} else {
			action = BuildWorkflowGates.observe(entry.argv)
			BuildHarness.require!(action != Ambiguous, "${name}: a build named no single artifact: ${Str.inspect(entry.argv)}")?
			$observed = $observed.concat(built_steps(action))
			$commands = $commands.concat(ran_command(action))
		}
	}
	BuildHarness.require!($observed == expected, "${name}: effect order ${Str.inspect($observed)}, expected ${Str.inspect(expected)}")?
	tasks = expected.keep_if(|step| step.kind == "task").map(|step| ["roc-stable", "task.roc", "--", suite.events].concat(step.argv))
	BuildHarness.require!($commands == tasks, "${name}: task process argv ${Str.inspect($commands)}, expected ${Str.inspect(tasks)}")?
	lines = ran.out.split_on("\n").drop_last(1)
	outputs = lines.keep_if(|line| line.starts_with("/nix/store/"))
	for output in outputs {
		BuildHarness.require!(BuildHarness.exists!(output), "reported artifact missing: ${output}")?
	}
	printed = lines.map(|line| if line.starts_with("/nix/store/") "build" else line)
	wanted = BuildWorkflowGates.published(expected, good)
	BuildHarness.require!(printed == wanted, "${name}: stdout order ${Str.inspect(printed)}, expected ${Str.inspect(wanted)}")?
	Ok({ outputs, ran })
}

built_steps : [Built(Str), Ran(List(Str)), Other, Ambiguous] -> List(BuildWorkflowGates.Step)
built_steps = |action|
	match action {
		Built(name) => [BuildWorkflowGates.build(name)]
		_ => []
	}

ran_command : [Built(Str), Ran(List(Str)), Other, Ambiguous] -> List(List(Str))
ran_command = |action|
	match action {
		Ran(argv) => [argv]
		_ => []
	}

## An `app` artifact must hold exactly these source, generated and asset
## bytes, the build's arguments, and a library built from the same source.
## Returns the library's store path.
artifact! : Str, List(U8), List(U8) => Try(Str, _)
artifact! = |output, source, generated| {
	BuildHarness.require!(Path.is_dir!(Path.utf8(output)) ?? Bool.False, "the app artifact is not a directory: ${output}")?
	BuildHarness.require!(BuildHarness.sorted(BuildHarness.names!(output)?) == ["argv.json", "library-path", "payload"], "the app artifact holds something else: ${output}")?
	wanted_library = "library".to_utf8().append(0).concat(source)
	wanted = "app".to_utf8().append(0).concat(wanted_library).append('|').concat(generated).append('|').concat(asset_bytes)
	BuildHarness.require!(read!("${output}/payload")? == wanted, "stale or incorrect artifact bytes: ${output}")?
	BuildHarness.require!(text(read!("${output}/argv.json")?) == "${BuildWorkflowGates.arguments_json}\n", "build argv changed")?
	library = text(read!("${output}/library-path")?).trim()
	BuildHarness.require!(library.starts_with("/nix/store/") and (Path.is_file!(Path.utf8(library)) ?? Bool.False), "the app names no library: ${library}")?
	BuildHarness.require!(read!(library)? == wanted_library, "stale dependency bytes")?
	Ok(library)
}

noops! : BuildHarness.Suite, BuildHarness.Layout => Try({}, _)
noops! = |suite, place| {
	# An existing nonempty generated tree must not even be restaged. A build
	# keeps nothing in a workspace that is not the generated root.
	BuildHarness.require!(
		!BuildHarness.snapshot!(place.generated)?.is_empty() and BuildHarness.snapshot!(place.workspace)?.is_empty(),
		"no-op test needs prior state",
	)?
	for name in ["empty", "nested-empty"] {
		before = state!(suite, place)?
		ran = BuildHarness.ok!(suite, place, ["workflow", name])?
		BuildHarness.require!(ran.stdout.is_empty(), "${name}: no-op produced stdout")?
		BuildHarness.require!(state!(suite, place)? == before, "${name}: no-op invoked Nix or changed generated state")?
	}
	Script.pass!("empty and nested-empty workflows preserve all state with zero Nix calls")
}

reject_capabilities! : BuildHarness.Suite, State => Try({}, _)
reject_capabilities! = |suite, state| {
	config = Path.utf8("${state.place.project}/Blueprint.roc")
	for (name, old, new) in [
		("unsupported-task", "Task(\"later\", [Use(\"builder\")", "Task(\"later\", [Use(\"foreign\")"),
		("unsupported-build", "Build(\"later-library\", [Use(\"builder\")", "Build(\"later-library\", [Use(\"foreign\")"),
	] {
		BuildHarness.require!(count(state.config, old) == 1, "vacuous negative fixture edit")?
		Path.write_utf8!(config, state.config.replace_each(old, new))?
		before = state!(suite, state.place)?
		refused = BuildHarness.refused!(suite, state.place, ["workflow", name], "Guix")?
		BuildHarness.require!(state!(suite, state.place)? == before, "${name} performed effects before whole-closure preflight")?
		BuildHarness.require!(refused.stdout.is_empty(), "unsupported closure produced a marker")?
	}
	Path.write_utf8!(config, state.config)?
	Script.pass!("nested later-task and transitive build capability errors before effects")
}

## Exercise the complete public example, changing only temporary setup inputs:
## where the platform is, and the pins the suite has fetched.
example_smoke! : BuildHarness.Suite => Try({}, _)
example_smoke! = |suite| {
	source = "${suite.root}/examples/artifacts"
	project = "${suite.work}/example-project"
	original = BuildHarness.tree!(source)?
	started = BuildHarness.names!(suite.logs)?.len()
	# A user may already have run update/build in the documented example.
	# Carry authored files only, never its ignored authority/workspace.
	for name in ["Blueprint.roc", "README.md", "assets/heading.txt", "src/message.txt", "scripts/check.roc", "scripts/build_library.roc", "scripts/build_app.roc"] {
		directory = Str.join_with("${project}/${name}".split_on("/").drop_last(1), "/")
		Path.create_all!(Path.utf8(directory))?
		Path.write_bytes!(Path.utf8("${project}/${name}"), read!("${source}/${name}")?)?
	}
	authored = text(read!("${source}/Blueprint.roc")?)
	replacements = [
		("\"../../blueprint-platform/main.roc\"", "\"${BuildHarness.relative(project, "${suite.root}/blueprint-platform/main.roc")}\""),
		("Name(\"artifacts\"),", "Name(\"artifacts\"),\n\tPackages(\"default\", From(NixPackages(\"${suite.pins.nixpkgs.ref}\"))),"),
		("\"github:roc-lang/roc-overlay\"", "\"${suite.pins.overlay.ref}\""),
	]
	for (old, _) in replacements {
		BuildHarness.require!(count(authored, old) == 1, "the example no longer holds ${old} exactly once")?
	}
	# The example names what the suite has fetched; anything else needs the network.
	for needed in ["rocpkgs.${suite.pins.compiler}"].concat(suite.pins.bundles.map(|bundle| bundle.ref)) {
		BuildHarness.require!(authored.contains("\"${needed}\""), "the example does not use the pinned ${needed}")?
	}
	config = "${project}/Blueprint.roc"
	Path.write_utf8!(Path.utf8(config), replacements.fold(authored, |edited, (old, new)| edited.replace_each(old, new)))?
	place = BuildHarness.layout(project)
	_ = BuildHarness.command!(suite, { argv: [suite.roc, "check", config], cwd: suite.caller, extra: [], stdin: [], code: 0, service: NoService })?
	_ = BuildHarness.refused!(suite, place, ["build", "app"], "blueprint update")?
	_ = BuildHarness.ok!(suite, place, ["update"])?
	BuildHarness.require!(Path.is_file!(Path.utf8(place.lock)) ?? Bool.False, "example update did not publish authority")?
	BuildHarness.mode!("444", Path.utf8(place.lock))?
	built = BuildHarness.ok!(suite, place, ["build", "app"])?
	output = built.out.trim()
	BuildHarness.require!(
		output.starts_with("/nix/store/") and (Path.is_file!(Path.utf8(output)) ?? Bool.False),
		"example must report its resolved file artifact",
	)?
	wanted = "Artifact example\nHELLO FROM THE WORKING TREE\n".to_utf8()
	BuildHarness.require!(read!(output)? == wanted, "example artifact bytes differ")?
	workflow = BuildHarness.ok!(suite, place, ["workflow", "ci"])?
	BuildHarness.require!(workflow.out == "source checked\n${built.out}", "example task/build workflow order or artifact identity differs")?
	BuildHarness.require!(read!(output)? == wanted, "workflow changed artifact bytes")?
	BuildHarness.require!(!BuildHarness.exists!("${project}/dist"), "build wrote into project checkout")?
	BuildHarness.require!(BuildHarness.tree!(source)? == original, "example smoke mutated checked-in files")?
	checks = (BuildHarness.names!(suite.logs)?.len() - started) // 3
	Script.pass!("artifacts example copy: compiler, explicit update, real build/workflow, exact bytes and immutable authority (${checks.to_str()} process checks)")
}

expect BuildWorkflowGates.arguments_json == Json.to_str(BuildWorkflowGates.arguments)
expect BuildWorkflowGates.record(["x"]) == { kind: "task", argv: ["record", "configured argument", "x"] }
expect BuildWorkflowGates.task_line(["record", "", "a b"]) == "task 7265636f7264000061206200"
expect BuildWorkflowGates.observe(["build", "--no-link", "path:/w/generated#packages.x86_64-linux.app"]) == Built("app")
expect BuildWorkflowGates.observe(["build", "--no-link"]) == Ambiguous
expect BuildWorkflowGates.observe(["develop", "--no-update-lock-file", "path:/w#devShells.x.y", "--command", "roc-stable", "task.roc", ""]) == Ran(["roc-stable", "task.roc", ""])
expect BuildWorkflowGates.observe(["develop", "path:/w#devShells.x.y"]) == Other
expect BuildWorkflowGates.observe(["eval", "--json"]) == Other and BuildWorkflowGates.observe([]) == Other

# A failed final build has no store path; a failed final task has its line.
expect {
	steps = [BuildWorkflowGates.task(["a"]), BuildWorkflowGates.build("app")]
	BuildWorkflowGates.published(steps, Bool.True) == ["task 6100", "build"] and BuildWorkflowGates.published(steps, Bool.False) == ["task 6100"]
		and BuildWorkflowGates.published([BuildWorkflowGates.build("app"), BuildWorkflowGates.task(["a"])], Bool.False) == ["build", "task 6100"]
}

expect count("built app: x built app: y", "built app:") == 2
