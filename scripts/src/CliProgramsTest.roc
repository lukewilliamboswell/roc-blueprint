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
## the loopback address, the store is a directory of the test's own, and the
## lock entries are written here, as `blueprint update` does not write them.
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
	cmd: Cmd.new_str(test.bench.blueprint).args_str(args).cwd(Path.utf8(cwd)).clear_envs().envs(CliHarness.setting(test.env, overrides)),
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
				$fetched = $fetched.append({ name: program.name, system: program.system, urls: program.urls, sha256: Integrity.digest(download.bytes), size: download.bytes.len() })
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
	Script.pass!("parity: with one Nix tool added, the task prints the same from the same store file, and only then starts Nix; without Nix it is refused before any download")
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
