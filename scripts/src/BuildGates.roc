import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Random
import BuildHarness
import Integrity
import Script

## The sandboxed-build gates, against the real `./blueprint` and real Nix.
##
## Builds are real derivations whose commands are the Roc scripts of
## `fixtures/builds`, run as `roc-stable` inside the sandbox. No build is
## mocked and no gate rests on a sandbox option alone. The gates that need no
## sandbox run `./blueprint __build-runner` on the host, as a derivation would.
BuildGates := [].{

	## A project file the build must see: the suite's own record of what it
	## wrote, never read back from a build.
	Entry : { name : List(U8), data : List(U8), executable : Bool }

	## The arguments the `app` build and the `args` task receive, and the JSON
	## the fixture scripts must make of them.
	arguments = ["", "two words", "--literal", "$HOME", "$(touch INJECTED)", "; touch INJECTED", "a'b\"c", "line\nbreak", "*", "$"]

	arguments_json = "[\"\",\"two words\",\"--literal\",\"$HOME\",\"$(touch INJECTED)\",\"; touch INJECTED\",\"a'b\\\"c\",\"line\\nbreak\",\"*\",\"$\"]"

	## The fixture files copied into the project.
	fixture_files = ["build.roc", "probe.roc", "task.roc", "assets/message.txt"]

	## What the `bundle` build must write for these files: a line per file,
	## ordered by name, with the name and bytes in hexadecimal.
	manifest : List(Entry) -> Str
	manifest = |ledger| {
		lines = ledger.map(|entry| "${BuildHarness.hex(entry.name)} ${if entry.executable "x" else "-"} ${BuildHarness.hex(entry.data)}\n")
		Str.join_with(BuildHarness.sorted(lines), "")
	}

	## The ledger with `name` holding `data`, added if it is new.
	with_file : List(Entry), Str, List(U8) -> List(Entry)
	with_file = |ledger, name, data| without_file(ledger, name).append({ name: name.to_utf8(), data, executable: Bool.False })

	without_file : List(Entry), Str -> List(Entry)
	without_file = |ledger, name| ledger.keep_if(|entry| entry.name != name.to_utf8())

	## The bytes of the three artifacts for the given project files.
	expected : List(U8), List(U8), List(U8) -> { library : List(U8), bundle : List(U8), application : List(U8) }
	expected = |untracked, task, asset| {
		library = "library".to_utf8().append(0).concat(untracked).append('|').concat(task)
		bundle = library.append('|').concat(asset)
		{ library, bundle, application: "app".to_utf8().append(0).concat(bundle).append('|').concat(arguments_json.to_utf8()) }
	}

	## A build specification: each field with its JSON value. A later field of
	## the same name replaces an earlier one.
	specification : List((Str, Str)) -> Str
	specification = |fields| {
		chosen = |name| List.last(fields.keep_if(|(field, _)| field == name))
		var $names = []
		for (name, _) in fields {
			if !$names.contains(name) {
				$names = $names.append(name)
			}
		}
		members = $names.map(
			|name|
				match chosen(name) {
					Ok((_, value)) => "${Json.to_str(name)}:${value}"
					Err(_) => ""
				},
		)
		"{${Str.join_with(members, ",")}}"
	}

	## Run every gate.
	run! : Path => Try({}, _)
	run! = |root| BuildHarness.run!(root, "builds", gates!)
}

State : { place : BuildHarness.Layout, config : Str, ledger : List(BuildGates.Entry) }

text : List(U8) -> Str
text = |bytes| Str.from_utf8_lossy(bytes)

quote : Str -> Str
quote = |value| Json.to_str(value)

read! : Str => Try(List(U8), _)
read! = |file| Path.read_bytes!(Path.utf8(file))

write! : Str, List(U8) => Try({}, _)
write! = |file, data| Path.write_bytes!(Path.utf8(file), data)

remove! : Str => Try({}, _)
remove! = |file| Path.delete!(Path.utf8(file))

## How many times `part` occurs in `whole`.
count : Str, Str -> U64
count = |whole, part| whole.split_on(part).len() - 1

## Where `part` first occurs in `whole`, in bytes.
position : Str, Str -> U64
position = |whole, part| (whole.split_on(part).first() ?? "").to_utf8().len()

gates! : BuildHarness.Suite => Try({}, _)
gates! = |suite| {
	BuildHarness.warm!(suite)?
	payload = "${suite.tools}/runner-payload"
	BuildHarness.build_tool!(suite, "fixtures/builds/runner_payload.roc", payload)?
	base = host_specification!(suite)?
	reject_unsafe_fetched_sources!(suite, base, payload)?
	runner_mechanics!(suite, base, payload)?
	prepared = prepare!(suite)?
	place = prepared.place

	# Ordinary operations must neither initialize authority nor stage files.
	for args in [["gen"], ["shell"], ["run", "args"], ["build", "app"]] {
		_ = BuildHarness.refused!(suite, place, args, "blueprint update")?
		BuildHarness.require!(
			!BuildHarness.exists!(place.workspace) and !BuildHarness.exists!(place.generated),
			"missing lock caused staging",
		)?
	}
	_ = BuildHarness.ok!(suite, place, ["update"])?
	BuildHarness.require!(Path.is_file!(Path.utf8(place.lock)) ?? Bool.False, "explicit update did not create authority")?
	first_authority = read!(place.lock)?
	BuildHarness.require!(!text(first_authority).contains(place.project), "authority contains absolute checkout paths")?
	# Offline, an update can only arrive at the committed pins.
	for source in [suite.pins.nixpkgs, suite.pins.overlay].concat(suite.pins.bundles) {
		BuildHarness.require!(text(first_authority).contains(source.nar_hash), "the authority does not pin ${source.ref} at ${source.nar_hash}")?
	}
	BuildHarness.mode!("444", Path.utf8(place.lock))?
	for directory in [place.workspace, place.generated] {
		Path.create_all!(Path.utf8(directory))?
		write!("${directory}/excluded-secret", "generated excluded".to_utf8())?
	}
	_ = BuildHarness.ok!(suite, place, ["gen"])?
	echoed = BuildHarness.ok!(suite, place, ["run", "args", "--"].concat(BuildGates.arguments))?
	BuildHarness.require!(echoed.out == "${BuildGates.arguments_json}\n", "the args task printed: ${echoed.out}")?
	shell = BuildHarness.blueprint!(suite, place, ["shell"], { code: 0, stdin: "printf 'shell control\\n'\nexit\n".to_utf8(), service: NoService })?
	BuildHarness.require!(shell.out == "shell control\n", "the shell printed: ${shell.out}")?
	# The probe adds a project file, so it runs before the first graph.
	probed = isolation!(suite, prepared)?
	first = graph!(suite, probed)?
	Script.pass!("file/directory/diamond graph, argv, readonly, exclusions")?

	reject_unsandboxed_runner!(suite, probed, base)?
	reject_unsafe_project_entries!(suite, place)?

	# One round changes an untracked file and has a task generate another.
	changed = "second".to_utf8().append(0).concat("revision\n".to_utf8())
	write!("${place.project}/untracked.txt", changed)?
	_ = BuildHarness.ok!(suite, place, ["run", "edit"])?
	generated = "task-generated".to_utf8().append(0).concat("bytes\n".to_utf8())
	edited = { ..probed, ledger: BuildGates.with_file(BuildGates.with_file(probed.ledger, "untracked.txt", changed), "task-produced.txt", generated) }
	second = graph!(suite, edited)?
	BuildHarness.require!(first != second, "an untracked edit and a task-generated file reused an obsolete artifact")?
	# Undoing both gives the first project again, so nothing of them may remain.
	remove!("${place.project}/task-produced.txt")?
	write!("${place.project}/untracked.txt", "first\n".to_utf8())?
	third = graph!(suite, probed)?
	BuildHarness.require!(second != third, "a deleted file survived a fresh build")?
	BuildHarness.require!(first == third, "the first project again did not give the first artifact again")?
	Script.pass!("fresh project copies after untracked edits, tasks and deletions")?

	for (name, diagnostic) in [("missing", "declared output is missing"), ("symlink", "symlink in declared output path"), ("nested-link", "symlink is not allowed")] {
		failed = BuildHarness.refused!(suite, place, ["build", name], diagnostic)?
		BuildHarness.require!(failed.stdout.is_empty() and !failed.err.contains("built "), "failed build published success metadata")?
	}
	Script.pass!("missing/symlink outputs fail without publishing success")?

	# A build sees its environment's tools and nothing else: neither a tool of
	# another environment nor the shell and coreutils earlier versions supplied.
	for (name, tool) in [("undeclared", "roc-stable"), ("undeclared-shell", "sh"), ("undeclared-coreutils", "ls")] {
		failed = BuildHarness.refused!(suite, place, ["build", name], "build command not found: ${tool}")?
		BuildHarness.require!(failed.stdout.is_empty() and !failed.err.contains("built "), "undeclared tool published success")?
	}
	Script.pass!("undeclared build tools are not found")?

	staged = (BuildHarness.tree!(place.generated)?, BuildHarness.tree!(place.workspace)?)
	write!("${place.project}/assets/message.txt", "explicitly updated\n".to_utf8())?
	for args in [["gen"], ["shell"], ["run", "args"], ["build", "app"]] {
		_ = BuildHarness.refused!(suite, place, args, "blueprint update")?
		BuildHarness.require!(
			staged == (BuildHarness.tree!(place.generated)?, BuildHarness.tree!(place.workspace)?),
			"dirty locked source caused staging",
		)?
	}
	BuildHarness.require!(read!(place.lock)? == first_authority, "dirty input rewrote pins")?
	_ = BuildHarness.ok!(suite, place, ["update"])?
	authority = read!(place.lock)?
	BuildHarness.require!(authority != first_authority, "update kept old hash")?
	original = graph!(suite, probed)?
	Script.pass!("dirty local source rejected until explicit update")?

	# Relocation changes all caller roots but retains the exact authority.
	relocated = "${suite.work}/relocated"
	BuildHarness.tool!("cp", ["-a", "--", place.project, relocated])?
	Path.delete_all!(Path.utf8("${relocated}/work"))?
	Path.delete_all!(Path.utf8("${relocated}/generated"))?
	outside = { project: relocated, workspace: "${suite.work}/outside-work", generated: "${suite.work}/outside-nix", lock: "${relocated}/authority.lock" }
	_ = BuildHarness.ok!(suite, outside, ["gen"])?
	derived = text(read!("${outside.generated}/flake.lock")?)
	BuildHarness.require!(derived.contains("${relocated}/assets"), "the derived lock does not name the relocated source:\n${derived}")?
	BuildHarness.require!(!derived.contains(place.project), "the derived lock names the first checkout:\n${derived}")?
	moved = graph!(suite, { ..probed, place: outside })?
	BuildHarness.require!(moved == original, "relocation changed the actual artifact")?
	_ = BuildHarness.ok!(suite, outside, ["run", "args", "--", ""])?
	_ = BuildHarness.blueprint!(suite, outside, ["shell"], { code: 0, stdin: "exit\n".to_utf8(), service: NoService })?
	BuildHarness.require!(read!(outside.lock)? == authority, "relocation changed pins")?
	Script.pass!("relocation, rebased native lock, out-of-tree caller paths")?

	reject_remote_symlink_build!(suite)?
	checks = BuildHarness.names!(suite.logs)?.keep_if(|name| name.ends_with(".argv")).len()
	Script.pass!("builds, real Nix: all gates passed (${checks.to_str()} process checks, ${BuildHarness.events!(suite)?.len().to_str()} Nix calls)")?
	Script.info!("INFO", "final artifact: ${moved}")
}

## The project: the fixture files, files of every mode a build must copy
## faithfully, and entries a build must never see.
prepare! : BuildHarness.Suite => Try(State, _)
prepare! = |suite| {
	project = "${suite.work}/project"
	fixture = "${suite.root}/fixtures/builds"
	Path.create_all!(Path.utf8("${project}/packages"))?
	write!("${project}/packages/unused-source", "unselected local input\n".to_utf8())?
	Path.create_dir!(Path.utf8("${project}/assets"))?
	# Independent expected source ledger, never populated from a build.
	var $ledger = []
	for name in BuildGates.fixture_files {
		source = Path.utf8("${fixture}/${name}")
		BuildHarness.require!(Path.type!(source)? == IsFile, "fixture file is not a regular file: ${name}")?
		data = Path.read_bytes!(source)?
		write!("${project}/${name}", data)?
		BuildHarness.mode!("644", Path.utf8("${project}/${name}"))?
		if !name.starts_with("assets/") {
			$ledger = BuildGates.with_file($ledger, name, data)
		}
	}
	template = Path.read_utf8!(Path.utf8("${fixture}/Blueprint.roc.in"))?
	config = BuildHarness.render(
		template,
		BuildHarness.pinned_values(suite.pins).append(("PLATFORM", BuildHarness.relative(project, "${suite.root}/blueprint-platform/main.roc"))),
	)
	BuildHarness.require!(!config.contains("@"), "the fixture template has a placeholder nothing fills:\n${config}")?
	Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), config)?
	write!("${project}/untracked.txt", "first\n".to_utf8())?
	nested = "#!/bin/sh\n# unused nested bytes\n".to_utf8()
	Path.create_dir!(Path.utf8("${project}/nested"))?
	write!("${project}/nested/unused-executable", nested)?
	BuildHarness.mode!("755", Path.utf8("${project}/nested/unused-executable"))?
	$ledger = BuildGates.with_file(BuildGates.with_file($ledger, "Blueprint.roc", config.to_utf8()), "untracked.txt", "first\n".to_utf8())
		.append({ name: "nested/unused-executable".to_utf8(), data: nested, executable: Bool.True })
	# Nix records only whether the owner may execute a file, and a name need
	# not be UTF-8.
	raw = "not-utf8-".to_utf8().append(255)
	for (name, bits, executable) in [
		("group-only-tool".to_utf8(), "654", Bool.False),
		("private-tool".to_utf8(), "700", Bool.True),
		("setuid-tool".to_utf8(), "4755", Bool.True),
		("read-only".to_utf8(), "444", Bool.False),
		(raw, "600", Bool.False),
	] {
		data = name.append(255).append(0).append('\n')
		file = Path.unix_bytes("${project}/".to_utf8().concat(name))
		Path.write_bytes!(file, data)?
		BuildHarness.mode!(bits, file)?
		$ledger = $ledger.append({ name, data, executable })
	}
	for name in [".git", ".hg", ".svn", ".jj", "nested/.git"] {
		Path.create_all!(Path.utf8("${project}/${name}"))?
		write!("${project}/${name}/excluded-secret", "VCS excluded".to_utf8())?
	}
	# An excluded entry is never inspected, so a link there is not refused.
	BuildHarness.link!("${project}/untracked.txt", "${project}/.git/link")?
	place = BuildHarness.layout(project)
	_ = BuildHarness.ok!(suite, place, ["check"])?
	Ok({ place, config, ledger: $ledger })
}

## Build an artifact and return the store path `blueprint` printed.
build! : BuildHarness.Suite, BuildHarness.Layout, Str, BuildHarness.Service => Try(Str, _)
build! = |suite, place, name, service| {
	ran = BuildHarness.blueprint!(suite, place, ["build", name], { code: 0, stdin: [], service })?
	output = ran.out.drop_suffix("\n")
	BuildHarness.require!(output.starts_with("/nix/store/") and !output.contains("\n"), "build ${name} printed: ${ran.out}")?
	BuildHarness.require!(BuildHarness.exists!(output), "reported output does not exist: ${output}")?
	BuildHarness.require!(ran.err.contains("built ${name}:") and ran.err.contains(" -> ${output}"), "build ${name} did not report its artifact:\n${ran.err}")?
	Ok(output)
}

## Build the whole graph and compare every artifact with the ledger.
graph! : BuildHarness.Suite, State => Try(Str, _)
graph! = |suite, state| {
	project = state.place.project
	task = if BuildHarness.exists!("${project}/task-produced.txt") read!("${project}/task-produced.txt")? else "<absent>".to_utf8()
	wanted = BuildGates.expected(read!("${project}/untracked.txt")?, task, read!("${project}/assets/message.txt")?)
	ran = BuildHarness.ok!(suite, state.place, ["build", "app"])?
	output = ran.out.drop_suffix("\n")
	BuildHarness.require!(output.starts_with("/nix/store/") and ran.err.contains(" -> ${output}"), "build app printed: ${ran.out}")?
	BuildHarness.require!((Path.is_file!(Path.utf8(output)) ?? Bool.False) and read!(output)? == wanted.application, "the app artifact holds other bytes: ${output}")?
	labels = ["building library:", "building bundle:", "building app:"]
	places = labels.map(|label| position(ran.err, label))
	BuildHarness.require!(places == places.sort(), "metadata is not dependency-first")?
	BuildHarness.require!(labels.all(|label| count(ran.err, label) == 1), "shared dependency was duplicated")?
	library = build!(suite, state.place, "library", NoService)?
	BuildHarness.require!((Path.is_file!(Path.utf8(library)) ?? Bool.False) and read!(library)? == wanted.library, "the library artifact holds other bytes: ${library}")?
	directory = build!(suite, state.place, "bundle", NoService)?
	BuildHarness.require!(Path.is_dir!(Path.utf8(directory)) ?? Bool.False, "the bundle artifact is not a directory: ${directory}")?
	contents = BuildHarness.tree!(directory)?
	BuildHarness.require!(contents.map(|file| file.name) == ["manifest", "payload", "proof"], "the bundle artifact holds: ${Str.inspect(contents.map(|file| file.name))}")?
	holds = |name, data| contents.any(|file| file.name == name and file.data == data)
	BuildHarness.require!(holds("payload", wanted.bundle), "the bundle payload holds other bytes")?
	BuildHarness.require!(holds("proof", "source+dependency readonly\n".to_utf8()), "the bundle did not prove its inputs read-only")?
	BuildHarness.require!(
		holds("manifest", BuildGates.manifest(state.ledger).to_utf8()),
		"in-derivation source bytes/modes differ from fixture ledger; see ${directory}/manifest",
	)?
	BuildHarness.require!(!BuildHarness.exists!("${project}/INJECTED"), "argv injection")?
	Ok(output)
}

## A specification whose witness names namespaces this host lacks.
##
## The runner compares a build's namespaces with the caller's witness. A
## hand-written witness that differs from this process therefore lets the
## remaining checks run here without a sandbox; the production witness is the
## one the CLI observes for itself.
host_specification! : BuildHarness.Suite => Try(List((Str, Str)), _)
host_specification! = |suite| {
	empty = "${suite.work}/runner-empty"
	Path.create_dir!(Path.utf8(empty))?
	control = "${suite.work}/host-control"
	Path.write_utf8!(Path.utf8(control), "host control")?
	Ok([
		("project", quote(empty)),
		("inputs", quote(empty)),
		("artifacts", quote(empty)),
		("path", quote(Env.var_str!("PATH") ?? "")),
		("output", quote("output")),
		("isolation", "{\"mnt\":\"mnt:[0]\",\"net\":\"net:[0]\"}"),
		("argv", Json.to_str(["cp", "--", control, "output"])),
		("readlink", quote(BuildHarness.which!("readlink")?)),
		("chmod", quote(BuildHarness.which!("chmod")?)),
	])
}

## Run the production build runner on the host, as a derivation does. Each
## run gets its own build directory, specification and `$out`.
runner! : BuildHarness.Suite, Str, I32 => Try({ ran : BuildHarness.Outcome, top : Str }, _)
runner! = |suite, specification, code| {
	top = Path.to_str(Env.create_temp_dir_in!(Path.utf8(suite.work), "runner-")?)?
	Path.create_dir!(Path.utf8("${top}/build"))?
	Path.write_utf8!(Path.utf8("${top}/spec.json"), specification)?
	ran = BuildHarness.command!(
		suite,
		{ argv: [suite.blueprint, "__build-runner", "${top}/spec.json"], cwd: "${top}/build", extra: [("out", "${top}/out")], stdin: [], code, service: NoService },
	)?
	Ok({ ran, top })
}

## Exit codes, the declared PATH and output checks, without Nix.
runner_mechanics! : BuildHarness.Suite, List((Str, Str)), Str => Try({}, _)
runner_mechanics! = |suite, base, payload| {
	control = runner!(suite, BuildGates.specification(base), 0)?
	BuildHarness.require!(text(read!("${control.top}/out")?) == "host control", "the host control build wrote other bytes: ${control.top}")?
	_ = runner!(suite, BuildGates.specification(base.append(("argv", Json.to_str([payload, "exit", "7"])))), 7)?
	_ = runner!(suite, BuildGates.specification(base.append(("argv", Json.to_str([payload, "terminate"])))), 143)?
	for (fields, diagnostic) in [
		# Only the declared path is searched, not this process's own.
		([("path", quote("${suite.work}/runner-empty")), ("argv", "[\"env\"]")], "build command not found: env"),
		([("argv", Json.to_str([payload, "direct-out"]))], "build wrote directly to $out instead of declared Output"),
		([("argv", Json.to_str([payload, "replace-workspace"]))], "build replaced the project workspace"),
		([("output", quote("../escape"))], "invalid declared relative output"),
		([("argv", "[\"mkfifo\",\"output\"]")], "special file is not allowed in build output/source"),
	] {
		failed = runner!(suite, BuildGates.specification(base.concat(fields)), 1)?
		BuildHarness.require!(failed.ran.err.contains(diagnostic), "the runner did not say \"${diagnostic}\":\n${failed.ran.err}")?
		BuildHarness.require!(failed.ran.err.starts_with("blueprint build: "), "the runner's diagnostic has another prefix:\n${failed.ran.err}")?
		if !diagnostic.contains("$out") {
			BuildHarness.require!(!BuildHarness.exists!("${failed.top}/out"), "failure published")?
		}
	}
	Script.pass!("runner exit codes, declared PATH and output checks (host, hand-written witness)")
}

## Filesystem unit gate for the runner's local/remote source boundary. The
## production runner checks a source farm on the host.
reject_unsafe_fetched_sources! : BuildHarness.Suite, List((Str, Str)), Str => Try({}, _)
reject_unsafe_fetched_sources! = |suite, base, payload| {
	source = "${suite.work}/fetched-source"
	Path.create_dir!(Path.utf8(source))?
	write!("${source}/data", "locked bytes\n".to_utf8())?
	farm = "${suite.work}/source-farm"
	Path.create_dir!(Path.utf8(farm))?
	BuildHarness.link!(source, "${farm}/assets")?
	sentinel = "${suite.work}/fetched-source-run-was-executed"
	specification = BuildGates.specification(base.concat([("inputs", quote(farm)), ("argv", Json.to_str([payload, "mark", sentinel]))]))
	safe = runner!(suite, specification, 0)?
	BuildHarness.require!(text(read!("${safe.top}/out")?) == "safe source", "the safe source build wrote other bytes: ${safe.top}")?
	remove!(sentinel)?
	for target in ["${source}/data", "${suite.work}/outside-source"] {
		BuildHarness.link!(target, "${source}/link")?
		linked = runner!(suite, specification, 1)?
		BuildHarness.require!(linked.ran.err.contains("symlink is not allowed"), "a link to ${target} in a source was not refused:\n${linked.ran.err}")?
		remove!("${source}/link")?
	}
	BuildHarness.fifo!("${source}/pipe")?
	special = runner!(suite, specification, 1)?
	BuildHarness.require!(special.ran.err.contains("special file is not allowed"), "a FIFO in a source was not refused:\n${special.ran.err}")?
	remove!("${source}/pipe")?
	# A fetched root link is not confused with the allowed farm link.
	BuildHarness.link!(source, "${suite.work}/fetched-root-link")?
	remove!("${farm}/assets")?
	BuildHarness.link!("${suite.work}/fetched-root-link", "${farm}/assets")?
	aliased = runner!(suite, specification, 1)?
	BuildHarness.require!(aliased.ran.err.contains("symlink is not allowed"), "a source that is itself a link was not refused:\n${aliased.ran.err}")?
	# Only generated links belong in a farm.
	remove!("${farm}/assets")?
	write!("${farm}/plain", "not a link\n".to_utf8())?
	plain = runner!(suite, specification, 1)?
	BuildHarness.require!(plain.ran.err.contains("expected generated source link"), "a plain file in a source farm was not refused:\n${plain.ran.err}")?
	BuildHarness.require!(!BuildHarness.exists!(sentinel), "user Run reached past an unsafe source")?
	Script.pass!("fetched source filesystem policy (runner unit gate)")
}

## This process's namespace, as a build's witness would name it.
namespace! : Str => Try(Str, _)
namespace! = |name| {
	output = Cmd.new("readlink").args(["/proc/self/ns/${name}"]).exec_output!().map_err(|_| ToolFailed("readlink /proc/self/ns/${name}"))?
	Ok(output.stdout_utf8.drop_suffix("\n"))
}

## Execute the real runner on the host; it must never reach the user's Run.
## Uses the namespace identities the CLI staged for a real build.
reject_unsandboxed_runner! : BuildHarness.Suite, State, List((Str, Str)) => Try({}, _)
reject_unsandboxed_runner! = |suite, state, base| {
	source = "${suite.work}/runner-source"
	Path.create_dir!(Path.utf8(source))?
	write!("${source}/input", "project bytes only\n".to_utf8())?
	mnt = namespace!("mnt")?
	net = namespace!("net")?
	flake = "${state.place.generated}/flake.nix"
	_ = build!(suite, state.place, "library", NoService)?
	staged = read!(flake)?
	BuildHarness.require!(
		text(staged).contains("isolation = { mnt = \"${mnt}\"; net = \"${net}\"; };"),
		"staged build did not capture caller namespaces",
	)?
	BuildHarness.require!(!text(staged).contains("@blueprint-caller"), "staged build kept an unobserved placeholder")?
	_ = build!(suite, state.place, "library", NoService)?
	BuildHarness.require!(read!(flake)? == staged, "witness defeats build caching")?
	marker = "${suite.work}/unsandboxed-run-was-executed"
	fields = base.concat([("project", quote(source)), ("inputs", quote(source)), ("artifacts", quote(source)), ("argv", Json.to_str(["touch", marker]))])
	witness = |mnt_value, net_value| ("isolation", "{\"mnt\":${quote(mnt_value)},\"net\":${quote(net_value)}}")
	cases = [
		(fields.append(witness(mnt, net)), "Build shares caller mnt namespace."),
		(fields.append(witness(mnt, "net:[0]")), "Build shares caller mnt namespace."),
		(fields.append(witness("mnt:[0]", net)), "Build shares caller net namespace."),
		(fields.append(witness("invalid", net)), "Invalid caller mnt namespace."),
		(fields.append(witness("mnt:[0]", "net:[0] ")), "Invalid caller net namespace."),
		(fields.append(("isolation", "null")), "Missing caller namespace observations."),
		(fields.append(("isolation", "{\"mnt\":\"mnt:[0]\"}")), "Missing caller namespace observations."),
		# A witness that differs still fails closed when the build's own
		# namespaces cannot be read.
		(fields.append(("readlink", quote("${suite.work}/no-readlink"))), "Cannot read build mnt namespace"),
		(fields.keep_if(|(name, _)| name != "isolation"), "Missing caller namespace observations."),
	]
	for (candidate, reason) in cases {
		failed = runner!(suite, BuildGates.specification(candidate), 1)?
		BuildHarness.require!(
			failed.ran.err.contains("blueprint build: cannot verify build isolation; user Run was not executed"),
			"the runner did not refuse an unverified build:\n${failed.ran.err}",
		)?
		BuildHarness.require!(failed.ran.err.contains("daemon configuration"), "the refusal names no remedy:\n${failed.ran.err}")?
		BuildHarness.require!(failed.ran.err.contains(reason), "the refusal did not say \"${reason}\":\n${failed.ran.err}")?
		BuildHarness.require!(!BuildHarness.exists!(marker), "unsandboxed user Run executed")?
		BuildHarness.require!(BuildHarness.sorted(BuildHarness.names!(failed.top)?) == ["build", "spec.json"], "isolation check happened after an effect")?
		BuildHarness.require!(BuildHarness.names!("${failed.top}/build")?.is_empty(), "isolation check happened after workspace setup")?
	}
	Script.pass!("unsandboxed runner fails closed before user Run (${cases.len().to_str()} cases)")
}

## Symlinks and special files are refused wherever the build reads.
reject_unsafe_project_entries! : BuildHarness.Suite, BuildHarness.Layout => Try({}, _)
reject_unsafe_project_entries! = |suite, place| {
	project = place.project
	for kind in ["file-link", "dir-link", "dangling", "fifo"] {
		for directory in ["", "nested/"] {
			bad = "${project}/${directory}bad"
			message = if kind == "fifo" {
				BuildHarness.fifo!(bad)?
				"snapshot refuses special file: ${bad}"
			} else {
				target = if kind == "file-link" "untracked.txt" else if kind == "dir-link" "nested" else "absent"
				BuildHarness.link!("${project}/${target}", bad)?
				"snapshot refuses symlink: ${bad}"
			}
			failed = BuildHarness.refused!(suite, place, ["build", "library"], message)?
			BuildHarness.require!(failed.stdout.is_empty() and !failed.err.contains("built "), "refused project entry published success")?
			remove!(bad)?
		}
	}
	# Excluded entries are never inspected, whatever they are.
	BuildHarness.fifo!("${project}/.git/fifo")?
	_ = build!(suite, place, "library", NoService)?
	remove!("${project}/.git/fifo")?
	Script.pass!("project symlinks and special files refused at any depth; excluded entries never inspected")
}

## The same probes that reach a host file and a host listener from a task
## must find neither from a build.
isolation! : BuildHarness.Suite, State => Try(State, _)
isolation! = |suite, state| {
	# A unique nonce prevents a cached derivation from faking isolation.
	token = Integrity.digest("${Random.seed_u64!()?.to_str()} ${Random.seed_u64!()?.to_str()}".to_utf8())
	# The marker needs traversable parents: a temporary directory or HOME may
	# be 0700, which would make denial a permissions result, not isolation.
	host = Env.create_temp_dir_in!(Path.utf8("/var/tmp"), "blueprint-host-probe-")?
	result = probe!(suite, state, token, Path.to_str(host)?)
	_ = Path.delete_all!(host)
	result
}

probe! : BuildHarness.Suite, State, Str, Str => Try(State, _)
probe! = |suite, state, token, host| {
	place = state.place
	BuildHarness.mode!("755", Path.utf8(host))?
	marker = "${host}/undeclared-host-marker"
	write!(marker, token.to_utf8())?
	BuildHarness.mode!("644", Path.utf8(marker))?
	{ listener, port } = BuildHarness.listen!()?
	settings = "{\"marker\":${quote(marker)},\"port\":${port.to_str()},\"token\":${quote(token)}}".to_utf8()
	write!("${place.project}/probe.json", settings)?
	probed = { ..state, ledger: BuildGates.with_file(state.ledger, "probe.json", settings) }
	# This process answers the listener while each command runs.
	echo = Echo(listener, token.to_utf8())
	reachable = "host-file readable; host-TCP reachable\n"
	before = BuildHarness.blueprint!(suite, place, ["run", "control"], { code: 0, stdin: [], service: echo })?
	BuildHarness.require!(before.out == reachable, "host control before build")?
	output = build!(suite, place, "isolation", echo)?
	BuildHarness.require!(text(read!(output)?) == "host-file denied\nhost-TCP denied\n", "sandbox proof bytes differ")?
	after = BuildHarness.blueprint!(suite, place, ["run", "control"], { code: 0, stdin: [], service: echo })?
	BuildHarness.require!(after.out == reachable, "host control after build")?
	BuildHarness.require!(text(read!(marker)?) == token, "host marker changed")?
	listener.close!()?
	Script.pass!("host-file/TCP isolation; same probes pass as host tasks")?
	Ok(probed)
}

## Actual HTTP fetch and sandboxed production runner, not helper calls.
reject_remote_symlink_build! : BuildHarness.Suite => Try({}, _)
reject_remote_symlink_build! = |suite| {
	project = "${suite.work}/remote-project"
	served = "${suite.work}/http-sources"
	archive = "${suite.work}/archive"
	for directory in [project, served, "${archive}/source"] {
		Path.create_all!(Path.utf8(directory))?
	}
	nonce = Integrity.digest("${Random.seed_u64!()?.to_str()} ${Random.seed_u64!()?.to_str()}".to_utf8())
	Path.write_utf8!(Path.utf8("${archive}/source/data"), nonce)?
	BuildHarness.link!("data", "${archive}/source/link")?
	BuildHarness.tool!("tar", ["-czf", "${served}/unsafe.tar.gz", "-C", archive, "source"])?
	remove!("${archive}/source/link")?
	BuildHarness.tool!("tar", ["-czf", "${served}/safe.tar.gz", "-C", archive, "source"])?
	{ listener, port } = BuildHarness.listen!()?
	http = Http(listener, served)
	place = BuildHarness.layout(project)
	fixture = "${suite.root}/fixtures/builds/remote"
	template = Path.read_utf8!(Path.utf8("${fixture}/Blueprint.roc.in"))?
	config = |archive_name|
		BuildHarness.render(
			template,
			BuildHarness.pinned_values(suite.pins).concat([
				("PLATFORM", BuildHarness.relative(project, "${suite.root}/blueprint-platform/main.roc")),
				("SOURCE", "http://127.0.0.1:${port.to_str()}/${archive_name}"),
				("NONCE", nonce),
			]),
		)
	write!("${project}/run.roc", read!("${fixture}/run.roc")?)?
	Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), config("unsafe.tar.gz"))?
	updated = BuildHarness.blueprint!(suite, place, ["update"], { code: 0, stdin: [], service: http })?
	BuildHarness.require!(updated.requests.contains("/unsafe.tar.gz"), "unsafe HTTP source not fetched")?
	refused = BuildHarness.blueprint!(suite, place, ["build", "remote"], { code: 1, stdin: [], service: http })?
	BuildHarness.require!(refused.err.contains("symlink is not allowed"), "the fetched symlink was not refused:\n${refused.err}")?
	BuildHarness.require!(refused.err.contains("/link"), "the refusal does not name the link:\n${refused.err}")?
	BuildHarness.require!(!"${refused.out}${refused.err}".contains("USER_RUN_REACHED_${nonce}"), "user Run reached despite unsafe fetched source")?
	BuildHarness.require!(refused.stdout.is_empty() and !refused.err.contains("built "), "unsafe fetched source published success")?
	# Same production Run succeeds with the symlink-free archive. Its nonce
	# prevents a cached result from faking this control.
	Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), config("safe.tar.gz"))?
	again = BuildHarness.blueprint!(suite, place, ["update"], { code: 0, stdin: [], service: http })?
	BuildHarness.require!(again.requests.contains("/safe.tar.gz"), "safe HTTP source not fetched")?
	output = build!(suite, place, "remote", http)?
	BuildHarness.require!(text(read!(output)?) == nonce, "safe-source Run not reached")?
	listener.close!()?
	Script.pass!("HTTP-fetched symlink rejected by sandboxed production runner; same Run succeeds with safe source")
}

expect BuildGates.arguments_json == Json.to_str(BuildGates.arguments)
expect count("a building x: b building x:", "building x:") == 2 and count("none", "building x:") == 0
expect position("ab building x:", "building x:") == 3

expect {
	ledger = BuildGates.with_file(BuildGates.with_file([], "b", [1]), "a", [255, 0]).append({ name: [255], data: [], executable: Bool.True })
	BuildGates.manifest(ledger) == "61 - ff00\n62 - 01\nff x \n"
}

expect BuildGates.without_file(BuildGates.with_file(BuildGates.with_file([], "a", [1]), "a", [2]), "b") == [{ name: ['a'], data: [2], executable: Bool.False }]
expect BuildGates.without_file(BuildGates.with_file([], "a", [1]), "a") == []

expect {
	made = BuildGates.expected("u".to_utf8(), "t".to_utf8(), "a".to_utf8())
	made.library == ['l', 'i', 'b', 'r', 'a', 'r', 'y', 0, 'u', '|', 't'] and made.bundle == made.library.concat("|a".to_utf8())
		and made.application == "app".to_utf8().append(0).concat(made.bundle).append('|').concat(BuildGates.arguments_json.to_utf8())
}

expect BuildGates.specification([("argv", "[\"a\"]"), ("output", "\"o\""), ("argv", "[\"b\"]")]) == "{\"argv\":[\"b\"],\"output\":\"o\"}"
expect BuildGates.specification([]) == "{}"
