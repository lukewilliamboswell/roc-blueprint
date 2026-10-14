import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import core.Lock
import core.Spec
import CliHarness
import Integrity
import Process
import RocPackagesTest
import Script
import Serve

## The real `./blueprint` and the real compiler on projects that fetch
## programs and expect tools of the machine. Nothing selects how a project is
## run but its own Blueprint.roc: one with no Nix tool never starts Nix, which
## is a stub here that records being started. Downloads come from a server on
## the loopback address and the store is a directory of the test's own. The
## first cases write the lock entries they need themselves, to say exactly
## what a run finds there. The last write none: `blueprint update` resolves
## them, with no Nix on PATH where the project declares nothing Nix resolves,
## and what a release publishes is asked of the same loopback server.
CliProgramsTest := [].{

	## Run every case from the repository root, in a temporary directory that is
	## removed afterwards.
	run! : Path => Try({}, _)
	run! = |repository| {
		bench = CliHarness.open!(repository, "blueprint-programs-", ["roc-record", "nix"])?
		result = served!(bench)
		CliHarness.close!(bench)
		result
	}

	## A Blueprint.roc with these settings, for the platform at this path.
	blueprint_roc : Str, List(Str) -> Str
	blueprint_roc = |platform_path, settings| "app [config] { pf: platform \"${platform_path}\" }\nconfig = [\n${Str.join_with(settings.map(|line| "\t${line}\n"), "")}]\n"

	## A project whose one environment fetches `roc-stable` from an archive
	## and `tool` as one file, and expects what it does of the machine. `extra` are further
	## settings of that environment.
	fetching : { roc : List(Str), tool : Str, expects : List(Str), extra : Str } -> List(Str)
	fetching = |given| [
		"Name(\"programs-test\"),",
		"Environment(\"dev\", [Programs([Fetch(\"roc-stable\", |_| ${mirrored("Archive(\"${given.roc.first() ?? ""}\", TarGz, \"pkg/roc-stable\")", given.roc.drop_first(1))}), Fetch(\"tool\", |_| File(\"${given.tool}\"))]), Expect([${Str.join_with(given.expects.map(|name| "\"${name}\""), ", ")}])${given.extra}]),",
		"Shell(\"default\", [Use(\"dev\")]),",
		"Task(\"say\", [Use(\"dev\"), Run([\"roc-stable\", \"configured\"])]),",
		"Task(\"tool\", [Use(\"dev\"), Run([\"tool\", \"--flag\"])]),",
		"Task(\"fail\", [Use(\"dev\"), Run([\"false\"])]),",
		"Workflow(\"both\", [RunTask(\"say\", [\"first\"]), RunTask(\"tool\", [])]),",
	]

	## A download as a recipe writes it, with its alternates when it has any.
	mirrored : Str, List(Str) -> Str
	mirrored = |download, alternates|
		if alternates.is_empty() download else "Mirrored(${download}, [${Str.join_with(alternates.map(|url| "\"${url}\""), ", ")}])"
}

Test : { bench : CliHarness.Bench, env : List((OsStr, OsStr)), store : Str }

## What a URL serves, for a lock entry.
Served : { url : Str, bytes : List(U8) }

served! : CliHarness.Bench => Try({}, _)
served! = |bench| {
	server = Serve.open!()?
	result = cases!(bench, server)
	_ = server.shut!()
	result
}

## Run `./blueprint` while the server answers, and return what it printed.
## The authority must be the same file afterwards, not written since.
run! : Test, Serve, Str, List(Str), I32, List((Str, Str)) => Try(Process.Outcome, _)
run! = |test, server, cwd, args, status, overrides| {
	authority = "${cwd}/Blueprint.lock"
	before = CliHarness.identity!(authority)?
	outcome = match server.drive!([job(test, cwd, args, overrides)])? {
		[only] => only
		_ => return Script.fail!("blueprint ${Str.join_with(args, " ")} did not report one result")
	}
	what = "blueprint ${Str.join_with(args, " ")}"
	CliHarness.check!(outcome.code == status, "${what} exited with code ${outcome.code.to_str()}, expected ${status.to_str()}:\n${outcome.stdout}${outcome.stderr}")?
	CliHarness.check!(CliHarness.identity!(authority)? == before, "${what} changed the authority ${authority}")?
	Ok(outcome)
}

job : Test, Str, List(Str), List((Str, Str)) -> Process.Job
job = |test, cwd, args, overrides| {
	cmd: Cmd.new(OsStr.from_str(test.bench.blueprint)).args(args.map(OsStr.from_str)).cwd(Path.utf8(cwd)).clear_envs().envs(CliHarness.setting(test.env, overrides)),
	label: "blueprint ${Str.join_with(args, " ")}",
}

## A new project directory holding a Blueprint.roc with these settings.
project! : Test, Str, List(Str) => Try(Str, _)
project! = |test, name, settings| {
	cwd = "${test.bench.work}/${name}"
	Path.create_dir!(Path.utf8(cwd))?
	platform_path = RocPackagesTest.relative(cwd, "${test.bench.root}/blueprint-platform/main.roc")
	Path.write_utf8!(Path.utf8("${cwd}/Blueprint.roc"), CliProgramsTest.blueprint_roc(platform_path, settings))?
	Ok(cwd)
}

## Write the lock a project's Spec asks for, as an update that resolved these
## downloads would: an entry for each program whose first URL is among them.
lock! : Test, Serve, Str, List(Served) => Try({}, _)
lock! = |test, server, cwd, downloads| {
	printed = run!(test, server, cwd, ["spec"], 0, [])?
	spec = match Spec.parse(printed.stdout) {
		Ok(parsed) => parsed
		Err(_) => return Script.fail!("blueprint spec did not print a Spec:\n${printed.stdout}")
	}
	var $fetched = []
	for program in spec.programs {
		match downloads.find_first(|download| program.urls.first() == Ok(download.url)) {
			Ok(download) => {
				$fetched = $fetched.append({ name: program.name, system: program.system, urls: program.urls, sha256: Integrity.digest(download.bytes), size: download.bytes.len(), obtained: Computed })
			}
			Err(_) => {}
		}
	}
	file = "${cwd}/Blueprint.lock"
	if CliHarness.present!(file) {
		CliHarness.tool!(["chmod", "0644", "--", file])?
	}
	Path.write_utf8!(Path.utf8(file), Lock.to_str(Lock.{ format: Lock.current_format, intent: Lock.intent_of(spec), sources: [], hints: [], fetched: $fetched }))?
	CliHarness.tool!(["chmod", "0444", "--", file])
}

## Nix did not run and nothing was generated for it.
without_nix! : Str => Try({}, _)
without_nix! = |cwd| {
	CliHarness.same_calls!(CliHarness.calls!("${cwd}/nix-calls")?, [], "Nix ran in ${cwd}")?
	CliHarness.check!(!CliHarness.present!("${cwd}/.blueprint/flake.nix"), "${cwd}/.blueprint/flake.nix was generated")
}

## No directory of links outlives the step it was made for.
no_run_left! : Str => Try({}, _)
no_run_left! = |cwd| CliHarness.check!(CliHarness.names!("${cwd}/.blueprint/run")? == [], "a run's links were left in ${cwd}/.blueprint/run: ${Str.inspect(CliHarness.names!("${cwd}/.blueprint/run")?)}")

## Empty the store, as on a machine that has fetched nothing.
empty_store! : Test => Try({}, _)
empty_store! = |test| {
	if CliHarness.present!(test.store) {
		CliHarness.tool!(["chmod", "-R", "u+w", "--", test.store])?
		Path.delete_all!(Path.utf8(test.store))?
	}
	Ok({})
}

## The names in the store's two directories, with nothing half-made beside them.
kept! : Test => Try({ artifacts : List(Str), trees : List(Str) }, _)
kept! = |test| {
	artifacts = Process.sorted(CliHarness.names!("${test.store}/v1/artifacts/sha256")?)
	trees = Process.sorted(CliHarness.names!("${test.store}/v1/trees/sha256")?)
	CliHarness.check!(!artifacts.concat(trees).any(|name| name.starts_with(".tmp-")), "the store holds something half-made: ${Str.inspect(artifacts.concat(trees))}")?
	Ok({ artifacts, trees })
}

cases! : CliHarness.Bench, Serve => Try({}, _)
cases! = |bench, idle| {
	search = Env.var_str!(OsStr.from_str("PATH")) ?? ""
	system = system_of(Env.platform!())
	cache = "${bench.work}/cache"
	test = {
		bench,
		store: "${cache}/blueprint",
		env: CliHarness.setting(
			bench.env,
			[
				("PATH", "${bench.bin}:${search}"),
				("ROC", "${bench.bin}/roc-record"),
				("STUB_REAL_ROC", bench.roc),
				("XDG_CACHE_HOME", cache),
				("STUB_NIX_FIXTURE", "${bench.root}/fixtures/consumer/inputs.lock"),
				("STUB_NIX_MODE", "declared"),
				("STUB_SHOW_EXE", "1"),
			],
		),
	}

	# What is served: the stub tool as one file, and in an archive beside a
	# data file, as `pkg/roc-stable`; an archive with a link out of its tree.
	stub = Path.read_bytes!(Path.utf8("${bench.work}/stub-tool"))?
	packed = "${bench.work}/packed"
	Path.create_all!(Path.utf8("${packed}/good/pkg"))?
	Path.copy!(Path.utf8("${bench.work}/stub-tool"), Path.utf8("${packed}/good/pkg/roc-stable"))?
	Path.write_utf8!(Path.utf8("${packed}/good/pkg/beside.txt"), "kept whole\n")?
	CliHarness.tool!(["tar", "-czf", "${packed}/roc.tar.gz", "-C", "${packed}/good", "pkg"])?
	Path.create_all!(Path.utf8("${packed}/evil/pkg"))?
	Path.copy!(Path.utf8("${bench.work}/stub-tool"), Path.utf8("${packed}/evil/pkg/roc-stable"))?
	CliHarness.tool!(["ln", "-s", "--", "../../outside", "${packed}/evil/pkg/escape"])?
	CliHarness.tool!(["tar", "-czf", "${packed}/evil.tar.gz", "-C", "${packed}/evil", "pkg"])?
	archive = Path.read_bytes!(Path.utf8("${packed}/roc.tar.gz"))?
	evil = Path.read_bytes!(Path.utf8("${packed}/evil.tar.gz"))?
	page = "<html>Not the release you asked for</html>\n".to_utf8()
	roc_url = idle.url("releases/1.0/roc.tar.gz")
	tool_url = idle.url("releases/1.0/tool")
	server = idle
		.with_route("releases/1.0/roc.tar.gz", archive)
		.with_route("releases/1.0/tool", stub)
		.with_route("mirror/roc.tar.gz", archive)
		.with_route("releases/1.0/evil.tar.gz", evil)
		.with_route("replaced/roc.tar.gz", page)
		.with_redirect("moved/roc.tar.gz", "/releases/1.0/roc.tar.gz")
		.with_redirect("away/roc.tar.gz", "http://example.invalid/roc.tar.gz")
		.with_status("busy/roc.tar.gz", "503 Service Unavailable")
	both = [{ url: roc_url, bytes: archive }, { url: tool_url, bytes: stub }]
	plain = CliProgramsTest.fetching({ roc: [roc_url], tool: tool_url, expects: ["tar", "ln"], extra: "" })
	roc_sha = Integrity.digest(archive)
	tool_sha = Integrity.digest(stub)
	roc_file = "${test.store}/v1/trees/sha256/${roc_sha}.tar.gz/pkg/roc-stable"
	tool_file = "${test.store}/v1/trees/sha256/${tool_sha}.file/program"

	# A project with no Nix tool: its programs are downloaded, verified and
	# started through links, and Nix is never started.
	first = project!(test, "first", plain)?
	lock!(test, server, first, both)?
	cold = run!(test, server, first, ["run", "say", "--", "extra"], 0, [])?
	CliHarness.check!(cold.stdout == "exe: ${roc_file}\nstub roc-stable: configured extra\n", "run say did not start the fetched roc-stable from the store:\n${cold.stdout}${cold.stderr}")?
	CliHarness.contains!(cold.stderr, "blueprint: fetching roc-stable from ${roc_url}", "the first run")?
	CliHarness.contains!(cold.stderr, "blueprint: fetching tool from ${tool_url}", "the first run")?
	CliHarness.check!(kept!(test)? == { artifacts: Process.sorted([roc_sha, tool_sha]), trees: Process.sorted(["${roc_sha}.tar.gz", "${tool_sha}.file"]) }, "the store does not hold the two downloads by their digests: ${Str.inspect(kept!(test)?)}")?
	CliHarness.check!(Path.read_utf8!(Path.utf8("${test.store}/v1/trees/sha256/${roc_sha}.tar.gz/pkg/beside.txt"))? == "kept whole\n", "the archive was not kept whole")?
	CliHarness.check!(CliHarness.stat!("%a", roc_file)? == "555" and CliHarness.stat!("%a", tool_file)? == "555", "a fetched program is writable or not executable")?
	without_nix!(first)?
	no_run_left!(first)?
	Script.pass!("a project with no Nix tool: programs are fetched into the store by digest, the archive kept whole and read-only, and Nix never starts")?

	# The second run downloads nothing: the server refuses every request.
	refusing = Serve.emptied(server)
	warm = run!(test, refusing, first, ["run", "say"], 0, [])?
	CliHarness.check!(warm.stdout == "exe: ${roc_file}\nstub roc-stable: configured\n" and warm.stderr == "", "a second run did not use the store alone:\n${warm.stdout}${warm.stderr}")?
	file = run!(test, refusing, first, ["run", "tool"], 0, [])?
	CliHarness.check!(file.stdout == "exe: ${tool_file}\nstub roc-stable: --flag\n", "a program that is one file was not started from the store:\n${file.stdout}${file.stderr}")?
	chain = run!(test, refusing, first, ["workflow", "both"], 0, [])?
	CliHarness.check!(chain.stdout == "exe: ${roc_file}\nstub roc-stable: configured first\nexe: ${tool_file}\nstub roc-stable: --flag\n", "a workflow did not run both tasks with their programs:\n${chain.stdout}${chain.stderr}")?
	without_nix!(first)?
	no_run_left!(first)?
	Script.pass!("a second run, a file program and a workflow use the store with no request at all")?

	# The links are removed when the task fails, too.
	failed = run!(test, refusing, first, ["run", "fail"], 1, [])?
	CliHarness.contains!(failed.stderr, "task fail exited with code 1", "run fail")?
	no_run_left!(first)?
	Script.pass!("a failing task leaves no links behind")?

	# A shell with no Nix tool is the caller's own shell, with the links first
	# on its PATH.
	shell = run!(test, refusing, first, ["shell"], 0, [("SHELL", "/usr/bin/env")])?
	CliHarness.contains!(shell.stdout, "PATH=${first}/.blueprint/run/run-", "blueprint shell with SHELL=/usr/bin/env")?
	CliHarness.contains!(shell.stdout, "/bin:${bench.bin}:", "blueprint shell with SHELL=/usr/bin/env")?
	without_nix!(first)?
	no_run_left!(first)?
	Script.pass!("blueprint shell with no Nix tool starts $SHELL with the fetched programs first on PATH")?

	# A stored artifact is hashed again on every use: other bytes under its
	# name are removed and the download is fetched and unpacked again.
	kept = "${test.store}/v1/artifacts/sha256/${roc_sha}"
	Path.write_bytes!(Path.utf8(kept), page)?
	started = CliHarness.calls!("${first}/roc-stable-calls")?.len()
	CliHarness.contains!(run!(test, refusing, first, ["run", "say"], 1, [])?.stderr, "could not download roc-stable from ${roc_url}: HTTP 404", "a run with a corrupted artifact and no server")?
	CliHarness.check!(!CliHarness.present!(kept) and !CliHarness.present!(roc_file), "a corrupted artifact or its tree was left in the store")?
	CliHarness.check!(CliHarness.calls!("${first}/roc-stable-calls")?.len() == started, "a task ran from a corrupted store")?
	again = run!(test, server, first, ["run", "say"], 0, [])?
	CliHarness.contains!(again.stderr, "blueprint: fetching roc-stable from ${roc_url}", "a run after the artifact was removed")?
	CliHarness.check!(again.stdout == "exe: ${roc_file}\nstub roc-stable: configured\n" and Integrity.digest(Path.read_bytes!(Path.utf8(kept))?) == roc_sha, "the artifact was not restored:\n${again.stdout}${again.stderr}")?
	Path.write_bytes!(Path.utf8(kept), page)?
	replaced = run!(test, server, first, ["run", "say"], 0, [])?
	CliHarness.contains!(replaced.stderr, "blueprint: the stored download of roc-stable is not what its name says; fetching it again", "a run with a corrupted artifact")?
	CliHarness.check!(replaced.stdout == "exe: ${roc_file}\nstub roc-stable: configured\n" and Integrity.digest(Path.read_bytes!(Path.utf8(kept))?) == roc_sha, "a corrupted artifact was not replaced:\n${replaced.stdout}${replaced.stderr}")?
	Script.pass!("a stored artifact that is not its digest is removed with its tree and fetched again; nothing runs from it")?

	# Two runs at once, from an empty store, both succeed and leave one of each.
	empty_store!(test)?
	together = server.drive!([job(test, first, ["run", "say", "--", "one"], []), job(test, first, ["run", "say", "--", "two"], [])])?
	CliHarness.check!(together.map(|outcome| (outcome.code, outcome.stdout)) == [(0, "exe: ${roc_file}\nstub roc-stable: configured one\n"), (0, "exe: ${roc_file}\nstub roc-stable: configured two\n")], "two runs at once did not both succeed: ${Str.inspect(together)}")?
	CliHarness.check!(kept!(test)? == { artifacts: Process.sorted([roc_sha, tool_sha]), trees: Process.sorted(["${roc_sha}.tar.gz", "${tool_sha}.file"]) }, "two runs at once left the store in another state: ${Str.inspect(kept!(test)?)}")?
	CliHarness.check!(Integrity.digest(Path.read_bytes!(Path.utf8(kept))?) == roc_sha and Integrity.digest(Path.read_bytes!(Path.utf8(roc_file))?) == Integrity.digest(stub), "two runs at once left other bytes in the store")?
	no_run_left!(first)?
	Script.pass!("two runs at once from an empty store both succeed; the store holds each download once, whole")?

	# What the machine lacks is said before anything is downloaded, all of it.
	empty_store!(test)?
	lacking = project!(test, "lacking", CliProgramsTest.fetching({ roc: [roc_url], tool: tool_url, expects: ["tar", "blueprint-absent-one", "blueprint-absent-two"], extra: "" }))?
	lock!(test, server, lacking, both)?
	absent = run!(test, server, lacking, ["run", "say"], 1, [])?
	for line in ["this machine lacks what the task needs, and blueprint installs none of it:", "  blueprint-absent-one: environment dev expects it on PATH (Expect)", "  blueprint-absent-two: environment dev expects it on PATH (Expect)"] {
		CliHarness.contains!(absent.stderr, line, "run say without what the environment expects")?
	}
	CliHarness.check!(!absent.stderr.contains("fetching") and !absent.stderr.contains("  tar:") and kept!(test)? == { artifacts: [], trees: [] }, "something was fetched before the machine was found lacking:\n${absent.stderr}")?
	CliHarness.same_calls!(CliHarness.calls!("${lacking}/roc-stable-calls")?, [], "a task ran without what its environment expects")?
	CliHarness.contains!(run!(test, server, lacking, ["shell"], 1, [("SHELL", "/usr/bin/env")])?.stderr, "this machine lacks what the shell needs", "blueprint shell without what the environment expects")?
	Script.pass!("an expected program that is missing: every one is named before any download, and nothing runs")?

	# A program the lock has not resolved, or resolved from other URLs, names
	# the command that resolves it. Nothing is fetched on the lock's behalf.
	unlocked = project!(test, "unlocked", plain)?
	lock!(test, server, unlocked, [])?
	missing = run!(test, server, unlocked, ["run", "say"], 1, [])?
	CliHarness.contains!(missing.stderr, "roc-stable for ${system} is not in Blueprint.lock; run blueprint update", "run say with an empty lock")?
	CliHarness.contains!(missing.stderr, "tool for ${system} is not in Blueprint.lock; run blueprint update", "run say with an empty lock")?
	moved = project!(test, "moved", CliProgramsTest.fetching({ roc: [idle.url("mirror/roc.tar.gz")], tool: tool_url, expects: ["tar", "ln"], extra: "" }))?
	lock!(test, server, moved, [{ url: idle.url("mirror/roc.tar.gz"), bytes: archive }, { url: tool_url, bytes: stub }])?
	# The same project, now naming another URL for the same program.
	Path.write_utf8!(Path.utf8("${moved}/Blueprint.roc"), Path.read_utf8!(Path.utf8("${first}/Blueprint.roc"))?)?
	changed = run!(test, server, moved, ["run", "say"], 1, [])?
	CliHarness.contains!(changed.stderr, "roc-stable for ${system}: Blueprint.roc now names ${roc_url}, the lock ${idle.url("mirror/roc.tar.gz")}; run blueprint update roc-stable", "run say after the URL changed")?
	CliHarness.check!(!missing.stderr.contains("fetching") and !changed.stderr.contains("fetching") and kept!(test)? == { artifacts: [], trees: [] }, "a program the lock does not hold was fetched")?
	Script.pass!("a program that is not in the lock, or is there under other URLs, is not fetched; the message names blueprint update")?

	# Bytes that are not the recorded ones are refused by their length, then by
	# their digest, and nothing of them is kept or unpacked.
	swapped = project!(test, "swapped", CliProgramsTest.fetching({ roc: [idle.url("replaced/roc.tar.gz")], tool: tool_url, expects: [], extra: "" }))?
	lock!(test, server, swapped, [{ url: idle.url("replaced/roc.tar.gz"), bytes: archive }, { url: tool_url, bytes: stub }])?
	short = run!(test, server, swapped, ["run", "say"], 1, [])?
	CliHarness.contains!(short.stderr, "roc-stable from ${idle.url("replaced/roc.tar.gz")} is ${page.len().to_str()} bytes, not the ${archive.len().to_str()} recorded in Blueprint.lock; nothing was unpacked", "run say with a page for an archive")?
	lock!(test, server, swapped, [{ url: idle.url("replaced/roc.tar.gz"), bytes: page.map(|byte| if byte == '<' '>' else byte) }, { url: tool_url, bytes: stub }])?
	other = run!(test, server, swapped, ["run", "say"], 1, [])?
	CliHarness.contains!(other.stderr, "roc-stable from ${idle.url("replaced/roc.tar.gz")} has SHA-256 ${Integrity.digest(page)}, not the ", "run say with other bytes of the same length")?
	CliHarness.contains!(other.stderr, " in Blueprint.lock; nothing was unpacked. If the publisher replaced the file, run blueprint update roc-stable and review the change", "run say with other bytes of the same length")?
	CliHarness.check!(kept!(test)? == { artifacts: [], trees: [] }, "refused bytes were kept: ${Str.inspect(kept!(test)?)}")?
	CliHarness.same_calls!(CliHarness.calls!("${swapped}/roc-stable-calls")?, [], "a task ran with refused bytes")?
	Script.pass!("a download of another length or another digest is refused by name; nothing is kept, unpacked or run")?

	# The URLs of a program are tried in order: the first that serves the
	# recorded bytes wins, and when none does each one's failure is said.
	mirrors = [idle.url("gone/roc.tar.gz"), idle.url("replaced/roc.tar.gz"), idle.url("mirror/roc.tar.gz")]
	mirror = project!(test, "mirror", CliProgramsTest.fetching({ roc: mirrors, tool: tool_url, expects: [], extra: "" }))?
	lock!(test, server, mirror, [{ url: idle.url("gone/roc.tar.gz"), bytes: archive }, { url: tool_url, bytes: stub }])?
	third = run!(test, server, mirror, ["run", "say"], 0, [])?
	CliHarness.check!(third.stdout == "exe: ${roc_file}\nstub roc-stable: configured\n", "the third URL did not serve the program:\n${third.stdout}${third.stderr}")?
	for url in mirrors {
		CliHarness.contains!(third.stderr, "blueprint: fetching roc-stable from ${url}", "a run whose first two URLs fail")?
	}
	empty_store!(test)?
	none = project!(test, "none", CliProgramsTest.fetching({ roc: [idle.url("gone/roc.tar.gz"), idle.url("busy/roc.tar.gz"), idle.url("away/roc.tar.gz")], tool: tool_url, expects: [], extra: "" }))?
	lock!(test, server, none, [{ url: idle.url("gone/roc.tar.gz"), bytes: archive }, { url: tool_url, bytes: stub }])?
	failing = run!(test, server, none, ["run", "say"], 1, [])?
	for line in [
		"no URL of roc-stable served it:",
		"  could not download roc-stable from ${idle.url("gone/roc.tar.gz")}: HTTP 404 from ${idle.url("gone/roc.tar.gz")} (1 attempt)",
		"  could not download roc-stable from ${idle.url("busy/roc.tar.gz")}: HTTP 503 from ${idle.url("busy/roc.tar.gz")} (3 attempts)",
		"  could not download roc-stable from ${idle.url("away/roc.tar.gz")}: a redirect to http://example.invalid/roc.tar.gz, which is not https (1 attempt)",
	] {
		CliHarness.contains!(failing.stderr, line, "a run none of whose URLs serves the program")?
	}
	redirected = project!(test, "redirected", CliProgramsTest.fetching({ roc: [idle.url("moved/roc.tar.gz")], tool: tool_url, expects: [], extra: "" }))?
	lock!(test, server, redirected, [{ url: idle.url("moved/roc.tar.gz"), bytes: archive }, { url: tool_url, bytes: stub }])?
	CliHarness.check!(run!(test, server, redirected, ["run", "say"], 0, [])?.stdout == "exe: ${roc_file}\nstub roc-stable: configured\n", "a redirect on the loopback address was not followed")?
	Script.pass!("URLs are tried in order and a redirect is followed; a refusal, a busy server and a redirect out of HTTPS are each reported")?

	# An archive is listed before it is unpacked: one with a link out of its
	# tree leaves no tree at all.
	empty_store!(test)?
	linked = project!(test, "linked", CliProgramsTest.fetching({ roc: [idle.url("releases/1.0/evil.tar.gz")], tool: tool_url, expects: [], extra: "" }))?
	lock!(test, server, linked, [{ url: idle.url("releases/1.0/evil.tar.gz"), bytes: evil }, { url: tool_url, bytes: stub }])?
	escaping = run!(test, server, linked, ["run", "say"], 1, [])?
	CliHarness.contains!(escaping.stderr, "the archive for roc-stable is not unpacked: it holds the link pkg/escape to ../../outside, outside the directory it is unpacked in", "run say with an archive that links out of its tree")?
	CliHarness.check!(kept!(test)?.trees.keep_if(|name| name.ends_with(".tar.gz")) == [] and !CliHarness.present!("${test.store}/v1/trees/outside") and !CliHarness.present!("${test.store}/v1/outside"), "an archive that links out of its tree was unpacked")?
	CliHarness.same_calls!(CliHarness.calls!("${linked}/roc-stable-calls")?, [], "a task ran from a refused archive")?
	Script.pass!("an archive with a link out of its tree is refused before anything is unpacked")?

	# Parity: the same task with one Nix tool added to its environment prints
	# the same, from the same file in the store. Only then does Nix start, with
	# the links ahead of what it adds to PATH; and a machine without Nix is
	# told so before anything is fetched.
	empty_store!(test)?
	mixed = project!(test, "mixed", CliProgramsTest.fetching({ roc: [roc_url], tool: tool_url, expects: ["tar", "ln"], extra: ", Tools([\"default#git\"])" }).append("Packages(\"default\", From(NixPackages(\"github:NixOS/nixpkgs/nixos-unstable\"))),"))?
	lock!(test, server, mixed, both)?
	CliHarness.tool!(["chmod", "0644", "--", "${mixed}/Blueprint.lock"])?
	updated = server.drive!([job(test, mixed, ["update"], [])])?
	CliHarness.check!(updated.map(|outcome| outcome.code) == [0], "blueprint update with the Nix stub failed: ${Str.inspect(updated)}")?
	CliHarness.contains!(Path.read_utf8!(Path.utf8("${mixed}/Blueprint.lock"))?, "(sha256 \"${roc_sha}\")", "the lock after an update kept what was recorded for the programs")?
	CliHarness.forget!("${mixed}/nix-calls")?
	no_nix = "${bench.work}/no-nix"
	Path.create_dir!(Path.utf8(no_nix))?
	Path.copy!(Path.utf8("${bench.work}/stub-tool"), Path.utf8("${no_nix}/roc-record"))?
	needing = run!(test, server, mixed, ["run", "say"], 1, [("PATH", no_nix), ("ROC", "${no_nix}/roc-record")])?
	# That PATH holds nothing else either, and one refusal says all of it.
	for line in ["this machine lacks what the task needs, and blueprint installs none of it:", "  tar: environment dev expects it on PATH (Expect)", "  nix: environment dev takes default#git from the Nix source default"] {
		CliHarness.contains!(needing.stderr, line, "run say with a Nix tool and no Nix")?
	}
	CliHarness.check!(!needing.stderr.contains("fetching") and kept!(test)? == { artifacts: [], trees: [] }, "something was fetched before Nix was found missing:\n${needing.stderr}")?
	with_nix = run!(test, server, mixed, ["run", "say", "--", "extra"], 0, [("STUB_NIX_RUN", "1")])?
	without = run!(test, server, first, ["run", "say", "--", "extra"], 0, [])?
	CliHarness.check!(with_nix.stdout == without.stdout and without.stdout == "exe: ${roc_file}\nstub roc-stable: configured extra\n", "the same task printed something else with a Nix tool in its environment:\n--- without\n${without.stdout}+++ with\n${with_nix.stdout}${with_nix.stderr}")?
	CliHarness.same_calls!(CliHarness.calls!("${mixed}/nix-calls")?, [["develop", "--no-update-lock-file", "--no-write-lock-file", "path:${mixed}/.blueprint#devShells.${system}.blueprint-env-dev", "--command", "roc-stable", "configured", "extra"]], "the task with a Nix tool did not enter Nix once, with the task's own argv")?
	without_nix!(first)?
	no_run_left!(mixed)?
	Script.pass!("parity: with one Nix tool added, the task prints the same from the same store file, and only then starts Nix; without Nix it is refused before any download")?
	updating!(test, idle, { archive, stub, page, system })?
	requiring!(test, idle, system)
}

## `blueprint requirements` answers from Blueprint.roc alone. Here it is asked
## on a machine with nothing: no `nix`, no lock, an empty store and no server.
## It says the same as it would anywhere, and leaves nothing behind.
requiring! : Test, Serve, Str => Try({}, _)
requiring! = |test, idle, system| {
	bench = test.bench
	nowhere = Serve.emptied(idle)
	bare_bin = "${bench.work}/bare-requirements"
	Path.create_dir!(Path.utf8(bare_bin))?
	Path.copy!(Path.utf8("${bench.work}/stub-tool"), Path.utf8("${bare_bin}/roc-record"))?
	bare = [("PATH", bare_bin), ("ROC", "${bare_bin}/roc-record")]
	source = "Packages(\"default\", From(NixPackages(\"github:NixOS/nixpkgs/nixos-unstable\"))),"
	fetching = |extra| CliProgramsTest.fetching({ roc: [idle.url("releases/1.0/roc.tar.gz")], tool: idle.url("releases/1.0/tool"), expects: ["blueprint-absent-one", "git"], extra })
	entry = |name, providers, tools| "{\"name\":\"${name}\",\"environment\":\"dev\",\"providers\":${providers},\"tools\":${tools},\"programs\":[\"roc-stable\",\"tool\"],\"unavailable\":[],\"expects\":[\"blueprint-absent-one\",\"git\"],\"roc_packages\":0}"
	report = |target, providers, tools, names| "{\"format\":1,\"system\":\"${target}\",\"providers\":${providers},\"expects\":[\"blueprint-absent-one\",\"git\"],\"tasks\":[\n ${Str.join_with(names.map(|name| entry(name, providers, tools)), ",\n ")}]}\n"
	untouched! = |cwd, what| {
		CliHarness.check!(!CliHarness.present!("${cwd}/Blueprint.lock") and !CliHarness.present!("${cwd}/.blueprint") and !CliHarness.present!(test.store), "${what} wrote a lock, generated files or a store")?
		CliHarness.same_calls!(CliHarness.calls!("${cwd}/nix-calls")?, [], "${what} started the provider")
	}
	empty_store!(test)?

	# A project that fetches and expects, and declares no source: no provider.
	# The machine lacks one expected program, which the report does not look
	# for: it says what is needed, not what is there.
	plain = project!(test, "requires-plain", fetching(""))?
	needed = command!(test, nowhere, plain, ["requirements", "--json"], bare)?
	CliHarness.check!(needed.code == 0 and needed.stdout == report(system, "[]", "[]", ["say", "tool", "fail"]) and needed.stderr == "", "requirements --json of a project with no source is not the report it should be (code ${needed.code.to_str()}):\n${needed.stdout}${needed.stderr}")?
	read = command!(test, nowhere, plain, ["requirements"], bare)?
	CliHarness.check!(
		read.code == 0 and read.stdout == "system ${system}\nproviders: none\n${Str.join_with(["say", "tool", "fail"].map(|name| "task ${name} [dev]: programs roc-stable, tool; expects blueprint-absent-one, git\n"), "")}",
		"requirements of a project with no source is not the report it should be (code ${read.code.to_str()}):\n${read.stdout}${read.stderr}",
	)?
	untouched!(plain, "requirements of a project with no source")?

	# A source that is declared and that no task uses requires no provider:
	# `providers` says what must be installed to run the tasks, and nothing
	# here is run by Nix.
	unused = project!(test, "requires-unused", fetching("").append(source))?
	declared = command!(test, nowhere, unused, ["requirements", "--json"], bare)?
	CliHarness.check!(declared.code == 0 and declared.stdout == report(system, "[]", "[]", ["say", "tool", "fail"]), "a declared and unused Nix source put a provider in the report (code ${declared.code.to_str()}):\n${declared.stdout}${declared.stderr}")?
	untouched!(unused, "requirements of a project with an unused source")?

	# One tool of that source in the tasks' environment requires its provider,
	# for each task and for the whole; the tool is written as Blueprint.roc
	# writes it. Named tasks are reported alone, in the order asked.
	using = project!(test, "requires-nix", fetching(", Tools([\"default#git\"])").append(source))?
	required = command!(test, nowhere, using, ["requirements", "--json"], bare)?
	CliHarness.check!(required.code == 0 and required.stdout == report(system, "[\"nix\"]", "[\"default#git\"]", ["say", "tool", "fail"]), "a Nix tool in the tasks' environment did not require nix (code ${required.code.to_str()}):\n${required.stdout}${required.stderr}")?
	chosen = command!(test, nowhere, using, ["requirements", "--json", "fail", "say"], bare)?
	CliHarness.check!(chosen.code == 0 and chosen.stdout == report(system, "[\"nix\"]", "[\"default#git\"]", ["fail", "say"]), "requirements of named tasks is not theirs alone, in order (code ${chosen.code.to_str()}):\n${chosen.stdout}${chosen.stderr}")?
	shown = command!(test, nowhere, using, ["requirements", "say"], bare)?
	CliHarness.check!(shown.code == 0 and shown.stdout == "system ${system}\nproviders: nix\ntask say [dev]: provider nix (default#git); programs roc-stable, tool; expects blueprint-absent-one, git\n", "requirements of one task with a Nix tool is not the report it should be:\n${shown.stdout}${shown.stderr}")?
	untouched!(using, "requirements of a project with a Nix tool")?

	# The System is the one asked for, and a task that is not declared is an
	# error, not an empty answer.
	other = if system == "aarch64-darwin" "x86_64-linux" else "aarch64-darwin"
	elsewhere = command!(test, nowhere, plain, ["requirements", "--json", "say"], bare.append(("BLUEPRINT_TARGET", other)))?
	CliHarness.check!(elsewhere.code == 0 and elsewhere.stdout == report(other, "[]", "[]", ["say"]), "requirements for another declared system is not that system's (code ${elsewhere.code.to_str()}):\n${elsewhere.stdout}${elsewhere.stderr}")?
	absent = command!(test, nowhere, plain, ["requirements", "--json", "say", "nope", "gone"], bare)?
	CliHarness.check!(absent.code == 1 and absent.stdout == "" and absent.stderr.contains("unknown task: nope") and absent.stderr.contains("unknown task: gone"), "requirements of undeclared tasks did not name them (code ${absent.code.to_str()}):\n${absent.stdout}${absent.stderr}")?
	untouched!(plain, "requirements for another system and for undeclared tasks")?
	Script.pass!("requirements: from Blueprint.roc alone, with no nix, lock, store or server; nix is required by a task that uses a Nix tool, not by a declared source; the JSON has one shape")
}

## `blueprint update` or another command while the server answers, with
## nothing required of the authority.
command! : Test, Serve, Str, List(Str), List((Str, Str)) => Try(Process.Outcome, _)
command! = |test, server, cwd, args, overrides|
	match server.drive!([job(test, cwd, args, overrides)])? {
		[only] => Ok(only)
		_ => Script.fail!("blueprint ${Str.join_with(args, " ")} did not report one result")
	}

## The fetched entries of a project's lock, and whether a provider pinned
## anything in it.
locked! : Str => Try({ fetched : List(Lock.Fetched), pinned : Bool, text : Str }, _)
locked! = |cwd| {
	text = Path.read_utf8!(Path.utf8("${cwd}/Blueprint.lock"))?
	match Lock.parse(text) {
		Ok(lock) => Ok({ fetched: lock.fetched, pinned: !(lock.sources.is_empty() and lock.hints.is_empty()), text })
		Err(_) => Script.fail!("${cwd}/Blueprint.lock is not a Lock:\n${text}")
	}
}

## What the entries of one program record, in the lock's order.
recorded : List(Lock.Fetched), Str -> List((Str, Str, U64, Lock.Obtained))
recorded = |fetched, name| fetched.keep_if(|entry| entry.name == name).map(|entry| (entry.system, entry.sha256, entry.size, entry.obtained))

## How often `part` occurs in `text`.
occurrences : Str, Str -> U64
occurrences = |text, part| text.split_on(part).len() - 1

## A release as its host describes it: these assets, each with its length
## and, when it has one, its SHA-256.
described : List({ name : Str, size : U64, sha256 : Str }) -> Str
described = |assets| {
	listed = assets.map(
		|asset| {
			digest = if asset.sha256.is_empty() "null" else "\"sha256:${asset.sha256}\""
			"{ \"name\": \"${asset.name}\", \"label\": null, \"size\": ${asset.size.to_str()}, \"digest\": ${digest} }"
		},
	)
	"{\n  \"tag_name\": \"1.0\",\n  \"body\": null,\n  \"assets\": [\n    ${Str.join_with(listed, ",\n    ")}\n  ]\n}\n"
}

## `blueprint update` writes the digests of fetched programs itself. Nothing
## of it needs Nix unless the project declares what Nix resolves, a digest
## that is unchanged asks nothing, and what a release publishes is compared
## with what was downloaded or recorded in its place.
updating! : Test, Serve, { archive : List(U8), stub : List(U8), page : List(U8), system : Str } => Try({}, _)
updating! = |test, idle, given| {
	bench = test.bench
	system = given.system
	systems = ["x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin"]
	roc_sha = Integrity.digest(given.archive)
	tool_sha = Integrity.digest(given.stub)
	page_sha = Integrity.digest(given.page)
	roc_url = idle.url("releases/1.0/roc.tar.gz")
	tool_url = idle.url("releases/1.0/tool")
	mirror_url = idle.url("mirror/roc.tar.gz")
	server = idle
		.with_route("releases/1.0/roc.tar.gz", given.archive)
		.with_route("releases/1.0/tool", given.stub)
		.with_route("mirror/roc.tar.gz", given.archive)
	refusing = Serve.emptied(server)
	roc_file = "${test.store}/v1/trees/sha256/${roc_sha}.tar.gz/pkg/roc-stable"
	heading = "Blueprint.lock now names download hosts it did not name before:\n"

	# A PATH with the stub compiler and nothing else: no `nix`, real or stub.
	bare_bin = "${bench.work}/bare-path"
	Path.create_dir!(Path.utf8(bare_bin))?
	Path.copy!(Path.utf8("${bench.work}/stub-tool"), Path.utf8("${bare_bin}/roc-record"))?
	bare = [("PATH", bare_bin), ("ROC", "${bare_bin}/roc-record")]
	every = |sha256, size, obtained| systems.map(|declared| (declared, sha256, size, obtained))

	# A project that only fetches: update needs no Nix, records every declared
	# system, says where downloads come from, and leaves this machine's
	# downloads in the store for the run that follows.
	empty_store!(test)?
	solo = project!(test, "solo", CliProgramsTest.fetching({ roc: [roc_url], tool: tool_url, expects: ["tar", "ln"], extra: "" }))?
	first = command!(test, server, solo, ["update"], bare)?
	CliHarness.check!(first.code == 0 and first.stdout == "${heading}  127.0.0.1\n", "update of a project that only fetches, with no nix on PATH, exited with code ${first.code.to_str()}:\n${first.stdout}${first.stderr}")?
	CliHarness.contains!(first.stderr, "blueprint: fetching roc-stable for ${system} from ${roc_url} to record its digest", "the first update")?
	solo_lock = locked!(solo)?
	CliHarness.check!(
		!solo_lock.pinned and solo_lock.fetched.len() == 8
			and recorded(solo_lock.fetched, "roc-stable") == every(roc_sha, given.archive.len(), Computed)
				and recorded(solo_lock.fetched, "tool") == every(tool_sha, given.stub.len(), Computed),
		"the lock of a project that only fetches does not hold each program's digest for every declared system:\n${solo_lock.text}",
	)?
	without_nix!(solo)?
	CliHarness.check!(kept!(test)? == { artifacts: Process.sorted([roc_sha, tool_sha]), trees: [] }, "update did not keep this machine's downloads in the store: ${Str.inspect(kept!(test)?)}")?
	ran = run!(test, refusing, solo, ["run", "say"], 0, [])?
	CliHarness.check!(ran.stdout == "exe: ${roc_file}\nstub roc-stable: configured\n" and !ran.stderr.contains("fetching"), "the run after an update fetched again or did not run:\n${ran.stdout}${ran.stderr}")?
	without_nix!(solo)?
	Script.pass!("update with no nix on PATH: a project that only fetches gets a digest for every declared system, a report of its download host, and its downloads in the store")?

	# Nothing changed: no request is made, the lock is written with the same
	# bytes, and there is no host to report.
	again = command!(test, refusing, solo, ["update"], bare)?
	CliHarness.check!(again.code == 0 and again.stdout == "" and !again.stderr.contains("fetching") and locked!(solo)?.text == solo_lock.text, "an update with nothing changed asked for something or changed the lock (code ${again.code.to_str()}):\n${again.stdout}${again.stderr}")?
	Script.pass!("update with nothing changed: no request, the same lock, nothing reported")?

	# A named program is fetched again whatever the lock holds, and only it.
	# With no server there is nothing to record, and the lock stays.
	unserved = command!(test, refusing, solo, ["update", "tool"], bare)?
	CliHarness.check!(unserved.code == 1 and unserved.stderr.contains("could not download tool for ") and unserved.stderr.contains(" from ${tool_url}: HTTP 404") and locked!(solo)?.text == solo_lock.text, "update tool with no server did not fail as that, or changed the lock (code ${unserved.code.to_str()}):\n${unserved.stderr}")?
	replaced = idle.with_route("releases/1.0/roc.tar.gz", given.archive).with_route("releases/1.0/tool", given.page).with_route("mirror/roc.tar.gz", given.archive)
	named = command!(test, replaced, solo, ["update", "tool"], bare)?
	named_lock = locked!(solo)?
	CliHarness.check!(
		named.code == 0 and named.stdout == "" and !named.stderr.contains("fetching roc-stable")
			and recorded(named_lock.fetched, "tool") == every(page_sha, given.page.len(), Computed)
				and recorded(named_lock.fetched, "roc-stable") == recorded(solo_lock.fetched, "roc-stable"),
		"update tool did not record what its URL serves now, and only that (code ${named.code.to_str()}):\n${named.stderr}${named_lock.text}",
	)?
	unknown = command!(test, refusing, solo, ["update", "tool", "nope"], bare)?
	CliHarness.check!(unknown.code == 1 and unknown.stderr.contains("no input or program named nope; Blueprint.roc declares no input and the programs roc-stable, tool") and locked!(solo)?.text == named_lock.text, "update of an undeclared name did not say what is declared, or changed the lock:\n${unknown.stderr}")?
	lockless = project!(test, "lockless", CliProgramsTest.fetching({ roc: [roc_url], tool: tool_url, expects: [], extra: "" }))?
	early = command!(test, server, lockless, ["update", "tool"], bare)?
	CliHarness.check!(early.code == 1 and early.stderr.contains("no lock to keep the other pins from; run `blueprint update` without input names first\n") and !CliHarness.present!("${lockless}/Blueprint.lock"), "a named update with no lock did not refuse (code ${early.code.to_str()}):\n${early.stderr}")?
	Script.pass!("update PROGRAM: that program is fetched again on every system and nothing else; an undeclared name, a missing server and a missing lock change nothing")?

	# A program declared with other URLs is the one an update resolves again.
	# A host that was not in the lock before is reported, though the first URL
	# served the bytes and the new one was never asked.
	Path.write_utf8!(Path.utf8("${solo}/Blueprint.roc"), Path.read_utf8!(Path.utf8("${solo}/Blueprint.roc"))?.replace_each("Archive(\"${roc_url}\", TarGz, \"pkg/roc-stable\")", "Mirrored(Archive(\"${mirror_url}\", TarGz, \"pkg/roc-stable\"), [\"https://mirror.example.invalid/roc.tar.gz\"])"))?
	stale = run!(test, refusing, solo, ["run", "say"], 1, [])?
	CliHarness.contains!(stale.stderr, "roc-stable for ${system}: Blueprint.roc now names ${mirror_url}, https://mirror.example.invalid/roc.tar.gz, the lock ${roc_url}; run blueprint update roc-stable", "run say after the URLs changed")?
	moved = command!(test, replaced, solo, ["update"], bare)?
	moved_lock = locked!(solo)?
	CliHarness.check!(
		moved.code == 0 and moved.stdout == "${heading}  mirror.example.invalid\n" and !moved.stderr.contains("fetching tool") and !moved.stderr.contains("mirror.example.invalid")
			and moved_lock.fetched.keep_if(|entry| entry.name == "roc-stable").all(|entry| entry.urls == [mirror_url, "https://mirror.example.invalid/roc.tar.gz"] and entry.sha256 == roc_sha)
				and recorded(moved_lock.fetched, "tool") == recorded(named_lock.fetched, "tool"),
		"an update after one program's URLs changed did not resolve that program alone and report its new host (code ${moved.code.to_str()}):\n${moved.stdout}${moved.stderr}",
	)?
	Script.pass!("update after a URL list changed: that program alone is resolved again, and a host the lock did not name is reported")?

	# A release asset: what its release publishes is asked once. This
	# machine's download is hashed and must agree; another system's is
	# recorded by the published digest and never fetched; one the release
	# gives no digest for is fetched and hashed.
	host_asset = "owner/tool/releases/download/1.0/tool-${system}"
	others = ["x86_64-linux", "aarch64-linux", "aarch64-darwin"].keep_if(|declared| declared != system)
	(far, bare_asset) = match others {
		[one, two] => (one, two)
		_ => return Script.fail!("this test runs on one of x86_64-linux, aarch64-linux and aarch64-darwin, not ${system}")
	}
	api = idle.url("repos/owner/tool/releases/tags/1.0")
	far_sha = "abababababababababababababababababababababababababababababababab"
	release = [
		"Name(\"released\"),",
		"Systems([\"x86_64-linux\", \"aarch64-linux\", \"aarch64-darwin\"]),",
		"Environment(\"dev\", [Programs([Fetch(\"tool\", |system| File(\"${idle.url("owner/tool/releases/download/1.0/tool")}-\${system.to_str()}\"))])]),",
		"Task(\"tool\", [Use(\"dev\"), Run([\"tool\"])]),",
	]
	listing = |host_sha| described([
		{ name: "tool-${system}", size: given.stub.len(), sha256: host_sha },
		{ name: "tool-${far}", size: 11, sha256: far_sha },
		{ name: "tool-${bare_asset}", size: given.page.len(), sha256: "" },
		{ name: "notes.txt", size: 3, sha256: "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd" },
	])
	assets = idle.with_route(host_asset, given.stub).with_route("owner/tool/releases/download/1.0/tool-${bare_asset}", given.page)
	empty_store!(test)?
	released = project!(test, "released", release)?
	published = command!(test, assets.with_route("repos/owner/tool/releases/tags/1.0", listing(tool_sha).to_utf8()), released, ["update"], bare)?
	CliHarness.check!(published.code == 0, "update of a release asset exited with code ${published.code.to_str()}:\n${published.stderr}")?
	released_lock = locked!(released)?
	CliHarness.check!(
		Process.sorted(recorded(released_lock.fetched, "tool").map(|(declared, sha256, size, obtained)| "${declared} ${sha256} ${size.to_str()} ${Str.inspect(obtained)}"))
			== Process.sorted(["${system} ${tool_sha} ${given.stub.len().to_str()} Both", "${far} ${far_sha} 11 Published", "${bare_asset} ${page_sha} ${given.page.len().to_str()} Computed"]),
		"the lock does not say how each digest of a release asset was obtained:\n${released_lock.text}",
	)?
	CliHarness.check!(occurrences(published.stderr, "blueprint: asking ${api} what owner/tool publishes for its release 1.0") == 1 and !published.stderr.contains("tool-${far}"), "the release was not asked once, or a system with a published digest was fetched:\n${published.stderr}")?
	CliHarness.check!(kept!(test)? == { artifacts: [tool_sha], trees: [] }, "update kept something other than this machine's download: ${Str.inspect(kept!(test)?)}")?
	Script.pass!("update of a release asset: the release is asked once; this machine's digest is computed and agrees, another system's is the published one, unfetched, and one with none is computed")?

	# A download that is not what its release publishes records nothing.
	empty_store!(test)?
	differing = project!(test, "differing", release)?
	differed = command!(test, assets.with_route("repos/owner/tool/releases/tags/1.0", listing(page_sha).to_utf8()), differing, ["update"], bare)?
	CliHarness.check!(
		differed.code == 1 and differed.stderr.contains("tool for ${system}: the download has SHA-256 ${tool_sha} and ${given.stub.len().to_str()} bytes, and its release publishes ${page_sha} and ${given.stub.len().to_str()} bytes; nothing was recorded")
			and !CliHarness.present!("${differing}/Blueprint.lock") and kept!(test)? == { artifacts: [], trees: [] },
		"a download that differs from what its release publishes was recorded or kept (code ${differed.code.to_str()}):\n${differed.stderr}",
	)?

	# A release that cannot be asked about does not stop the update: it is
	# said once, with what the limit is, and every download is hashed
	# instead. So is one whose answer describes no release, and one that is
	# not there at all, which is an answer and needs no notice.
	whole = assets.with_route("owner/tool/releases/download/1.0/tool-${far}", given.archive)
	computed = Process.sorted(["${system} ${tool_sha} Computed", "${far} ${roc_sha} Computed", "${bare_asset} ${page_sha} Computed"])
	how = |lock| Process.sorted(recorded(lock.fetched, "tool").map(|(declared, sha256, _, obtained)| "${declared} ${sha256} ${Str.inspect(obtained)}"))
	refused = project!(test, "refused", release)?
	limited = command!(test, whole.with_status("repos/owner/tool/releases/tags/1.0", "403 Forbidden"), refused, ["update"], bare)?
	limit_notice = "blueprint: could not ask for the digests owner/tool publishes for its release 1.0: HTTP 403 from ${api} (1 attempt). GitHub answers 60 such requests an hour from one address when no token is sent, and blueprint sends none. The digests of its downloads are computed by downloading each of them instead, and Blueprint.lock records them as computed"
	CliHarness.check!(
		limited.code == 0 and occurrences(limited.stderr, limit_notice) == 1 and occurrences(limited.stderr, "could not ask") == 1
			and how(locked!(refused)?) == computed,
		"a refused question about a release stopped the update, was not said once, or left a digest that was not computed (code ${limited.code.to_str()}):\n${limited.stderr}",
	)?
	empty_store!(test)?
	unread = project!(test, "unread", release)?
	garbled = command!(test, whole.with_route("repos/owner/tool/releases/tags/1.0", given.page), unread, ["update"], bare)?
	CliHarness.check!(
		garbled.code == 0 and occurrences(garbled.stderr, "blueprint: could not ask for the digests owner/tool publishes for its release 1.0: the answer from ${api} does not describe a release. The digests of its downloads are computed by downloading each of them instead") == 1
			and !garbled.stderr.contains("60 such requests") and how(locked!(unread)?) == computed,
		"an answer that is no release's description stopped the update or was taken for one (code ${garbled.code.to_str()}):\n${garbled.stderr}",
	)?
	# A digest the release does publish is not set aside by any of this: the
	# refused question's fallback is only for a question with no answer.
	empty_store!(test)?
	unlisted = command!(test, assets.with_route("owner/tool/releases/download/1.0/tool-${far}", given.archive), differing, ["update"], bare)?
	CliHarness.check!(
		unlisted.code == 0 and !unlisted.stderr.contains("could not ask") and how(locked!(differing)?) == computed,
		"with no release to ask about, the downloads were not all hashed (code ${unlisted.code.to_str()}):\n${unlisted.stderr}",
	)?
	# A system the publisher has no download for: the failure says how
	# Blueprint.roc states that, and nothing is written.
	empty_store!(test)?
	partial = project!(test, "partial", release)?
	absent = command!(test, assets, partial, ["update"], bare)?
	CliHarness.check!(
		absent.code == 1 and absent.stderr.contains("(1 attempt)\nIf tool is not published for ${far}, say so in Blueprint.roc: list the systems the project supports in Systems, or give tool a recipe that answers Unavailable for ${far}\n")
			and !CliHarness.present!("${partial}/Blueprint.lock"),
		"a download that is not there for one system did not stop the update with what to write (code ${absent.code.to_str()}):\n${absent.stderr}",
	)?
	Script.pass!("a published digest that differs stops the update with nothing written; a refused question and an unreadable answer are each said once and leave every digest computed, as a release that is not there does; a download missing for one system says how to declare that")?

	# A project that also declares a Nix source: update needs Nix, and says so
	# before anything is fetched. With it, one lock holds the pins and the
	# digests. A program of that project is still updated with no Nix.
	empty_store!(test)?
	both = project!(test, "both", CliProgramsTest.fetching({ roc: [roc_url], tool: tool_url, expects: [], extra: ", Tools([\"default#git\"])" }).append("Packages(\"default\", From(NixPackages(\"github:NixOS/nixpkgs/nixos-unstable\"))),"))?
	needing = command!(test, server, both, ["update"], bare)?
	CliHarness.check!(
		needing.code == 1 and needing.stderr.contains("this machine lacks what blueprint update needs, and blueprint installs none of it:\n  nix: Blueprint.roc declares the Nix source default, which Nix resolves")
			and !needing.stderr.contains("fetching") and !CliHarness.present!("${both}/Blueprint.lock") and !CliHarness.present!("${both}/.blueprint"),
		"update of a project with a Nix source and no nix did not refuse before any effect (code ${needing.code.to_str()}):\n${needing.stderr}",
	)?
	mixed = command!(test, server, both, ["update"], [])?
	mixed_lock = locked!(both)?
	CliHarness.check!(
		mixed.code == 0 and mixed.stdout == "${heading}  127.0.0.1\n" and mixed_lock.pinned
			and recorded(mixed_lock.fetched, "roc-stable") == every(roc_sha, given.archive.len(), Computed) and recorded(mixed_lock.fetched, "tool") == every(tool_sha, given.stub.len(), Computed),
		"update of a project with a Nix source and programs did not write both into one lock (code ${mixed.code.to_str()}):\n${mixed.stderr}${mixed_lock.text}",
	)?
	CliHarness.same_calls!(CliHarness.calls!("${both}/nix-calls")?.map(|call| call.take_first(2)), [["flake", "update"]], "the provider calls of an update with a Nix source")?
	program_only = command!(test, replaced, both, ["update", "tool"], bare)?
	after = locked!(both)?
	CliHarness.check!(
		program_only.code == 0 and after.pinned and recorded(after.fetched, "tool") == every(page_sha, given.page.len(), Computed)
			and after.text.replace_each(page_sha, tool_sha).replace_each("(size ${given.page.len().to_str()})", "(size ${given.stub.len().to_str()})") == mixed_lock.text,
		"update of a program in a project with a Nix source needed Nix or changed its pins (code ${program_only.code.to_str()}):\n${program_only.stderr}",
	)?
	input_named = command!(test, server, both, ["update", "default"], bare)?
	CliHarness.check!(input_named.code == 1 and input_named.stderr.contains("  nix: Blueprint.roc declares the Nix source default, which Nix resolves") and locked!(both)?.text == after.text, "update of an input with no nix did not refuse (code ${input_named.code.to_str()}):\n${input_named.stderr}")?
	CliHarness.same_calls!(CliHarness.calls!("${both}/nix-calls")?.map(|call| call.take_first(2)), [["flake", "update"]], "the provider calls after a program's update and a refused input's")?
	Script.pass!("update with a Nix source: refused with no nix before any effect; with it, pins and digests share one lock; a program alone is then updated with no nix")
}

## The System a machine is, as `blueprint` names the one it runs on.
system_of : { arch : [X86, X64, ARM, AARCH64, OTHER(Str)], os : [LINUX, MACOS, WINDOWS, OTHER(Str)] } -> Str
system_of = |machine|
	match machine {
		{ arch: AARCH64, os: LINUX } => "aarch64-linux"
		{ arch: AARCH64, os: MACOS } => "aarch64-darwin"
		_ => "x86_64-linux"
	}

expect CliProgramsTest.blueprint_roc("../pf/main.roc", ["Name(\"a\"),"]) == "app [config] { pf: platform \"../pf/main.roc\" }\nconfig = [\n\tName(\"a\"),\n]\n"
expect CliProgramsTest.mirrored("File(\"a\")", []) == "File(\"a\")" and CliProgramsTest.mirrored("File(\"a\")", ["b", "c"]) == "Mirrored(File(\"a\"), [\"b\", \"c\"])"
expect CliProgramsTest.fetching({ roc: ["http://127.0.0.1:1/a", "http://127.0.0.1:1/b"], tool: "http://127.0.0.1:1/t", expects: ["tar"], extra: ", Tools([\"default#git\"])" }).keep_if(|line| line.starts_with("Environment")) == [
	"Environment(\"dev\", [Programs([Fetch(\"roc-stable\", |_| Mirrored(Archive(\"http://127.0.0.1:1/a\", TarGz, \"pkg/roc-stable\"), [\"http://127.0.0.1:1/b\"])), Fetch(\"tool\", |_| File(\"http://127.0.0.1:1/t\"))]), Expect([\"tar\"]), Tools([\"default#git\"])]),",
]
expect system_of({ arch: X64, os: LINUX }) == "x86_64-linux" and system_of({ arch: AARCH64, os: MACOS }) == "aarch64-darwin"

expect occurrences("a, b, a", "a") == 2 and occurrences("b", "a") == 0
expect described([{ name: "tool", size: 3, sha256: "ab" }, { name: "old", size: 4, sha256: "" }]) == "{\n  \"tag_name\": \"1.0\",\n  \"body\": null,\n  \"assets\": [\n    { \"name\": \"tool\", \"label\": null, \"size\": 3, \"digest\": \"sha256:ab\" },\n    { \"name\": \"old\", \"label\": null, \"size\": 4, \"digest\": null }\n  ]\n}\n"
expect recorded([{ name: "tool", system: "x86_64-linux", urls: ["https://example.test/tool"], sha256: "ab", size: 3, obtained: Both }, { name: "other", system: "x86_64-linux", urls: ["https://example.test/other"], sha256: "cd", size: 4, obtained: Computed }], "tool") == [("x86_64-linux", "ab", 3, Both)]
