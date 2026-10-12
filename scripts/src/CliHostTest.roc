import cli.Env
import cli.OsStr
import cli.Path
import core.Lock
import core.Spec
import CliHarness
import Integrity
import RocPackagesTest
import Script

## The real `./blueprint` and the real compiler with the host provider, on a
## machine that is not Windows. `BLUEPRINT_PROVIDER=host` selects the provider;
## Nix is a stub that must not run after `blueprint update` has written the
## lock, which is done with the Nix provider as a project's Linux users would.
CliHostTest := [].{

	## Run every case from the repository root, in a temporary directory that is
	## removed afterwards.
	run! : Path => Try({}, _)
	run! = |repository| {
		bench = CliHarness.open!(repository, "blueprint-host-", ["roc-record", "nix", "curl", "tar"])?
		result = cases!(bench)
		CliHarness.close!(bench)
		result
	}

	## A Blueprint.roc with these settings, for the platform at this path.
	blueprint_roc : Str, List(Str) -> Str
	blueprint_roc = |platform_path, settings| "app [config] { pf: platform \"${platform_path}\" }\nconfig = [\n${Str.join_with(settings.map(|line| "\t${line}\n"), "")}]\n"

	## One environment that declares nothing, a shell, a task and a build.
	plain : List(Str)
	plain = [
		"Name(\"host-test\"),",
		"Environment(\"plain\", []),",
		"Shell(\"default\", [Use(\"plain\")]),",
		"Task(\"say\", [Use(\"plain\"), Run([\"printf\", \"%s\\n\", \"configured argument\"])]),",
		"Task(\"local\", [Use(\"plain\"), Run([\"tools/roc-stable\", \"from the project\"])]),",
		"Task(\"script\", [Use(\"plain\"), Run([\"check.roc\"])]),",
		"Build(\"app\", [Use(\"plain\"), Run([\"true\"]), Output(\"out\")]),",
	]

	## A nightly no compiler here is, so nothing but the stubs can supply it.
	tag : Str
	tag = "nightly-2026-01-02-abcdef0"

	## An environment whose `roc-stable` is that nightly, and a task that
	## starts it.
	stable : List(Str)
	stable = [
		"Name(\"host-test\"),",
		"Overlay(\"roc\", \"github:example/unused-overlay\"),",
		"Environment(\"dev\", [Overlays([\"roc\"]), Command(\"roc-stable\", \"rocpkgs.${tag}\")]),",
		"Task(\"version\", [Use(\"dev\"), Run([\"roc-stable\", \"version\"])]),",
		"Task(\"check\", [Use(\"dev\"), Run([\"scripts/check_all.roc\", \"--quick\"])]),",
		"Task(\"path\", [Use(\"dev\"), Run([\"printenv\", \"PATH\"])]),",
	]

	## How roc-lang/nightlies names the compiler archive for this machine.
	build : { arch : [X86, X64, ARM, AARCH64, OTHER(Str)], os : [LINUX, MACOS, WINDOWS, OTHER(Str)] } -> Try(Str, [NoBuild])
	build = |machine|
		match machine {
			{ arch: X64, os: LINUX } => Ok("linux_x86_64")
			{ arch: AARCH64, os: LINUX } => Ok("linux_arm64")
			{ arch: AARCH64, os: MACOS } => Ok("macos_apple_silicon")
			{ arch: X64, os: MACOS } => Ok("macos_x86_64")
			_ => Err(NoBuild)
		}

	## What every transfer is asked for, before its own arguments.
	transfer : List(Str)
	transfer = ["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--retry", "3"]

	## The request for a release's assets and their digests.
	ask : Str -> List(Str)
	ask = |release| transfer.concat(["--header", "Accept: application/vnd.github+json", "https://api.github.com/repos/roc-lang/nightlies/releases/tags/${release}"])

	## Whether a recorded `curl` call downloads `url` into a fresh directory
	## beside `directory`.
	downloads : List(Str), Str, Str -> Bool
	downloads = |call, directory, url|
		match call.drop_first(transfer.len()) {
			["--output", file, asked] => call.take_first(transfer.len()) == transfer and asked == url and fresh(file, directory, "archive")
			_ => False
		}

	## Whether a recorded `tar` call unpacks such a download beside itself.
	unpacks : List(Str), Str -> Bool
	unpacks = |call, directory|
		match call {
			["-xf", file, "-C", tree] => fresh(file, directory, "archive") and fresh(tree, directory, "tree") and file.drop_suffix("archive") == tree.drop_suffix("tree")
			_ => False
		}

	## `<parent of directory>/.blueprint-fetch-<random>/<name>`.
	fresh : Str, Str, Str -> Bool
	fresh = |file, directory, name| {
		parent = Str.join_with(directory.split_on("/").drop_last(1), "/")
		match file.drop_prefix("${parent}/").split_on("/") {
			[temporary, last] => file.starts_with("${parent}/") and temporary.starts_with(".blueprint-fetch-") and last == name
			_ => False
		}
	}
}

Test : { bench : CliHarness.Bench, env : List((OsStr, OsStr)) }

## The variable that selects the host provider.
host : (Str, Str)
host = ("BLUEPRINT_PROVIDER", "host")

## Run `./blueprint` and return everything it printed. The authority must be
## the same file afterwards, with the same bytes, not written since.
run! : Test, Str, List(Str), I32, List((Str, Str)) => Try(Str, _)
run! = |test, cwd, args, status, overrides| {
	authority = "${cwd}/Blueprint.lock"
	before = CliHarness.identity!(authority)?
	outcome = CliHarness.blueprint!(test.bench, cwd, args, CliHarness.setting(test.env, overrides))?
	what = "blueprint ${Str.join_with(args, " ")}"
	CliHarness.exited!(outcome, status, what)?
	CliHarness.check!(CliHarness.identity!(authority)? == before, "${what} changed the authority ${authority}")?
	Ok("${outcome.stdout}${outcome.stderr}")
}

## A new project directory holding a Blueprint.roc with these settings.
project! : Test, Str, List(Str) => Try(Str, _)
project! = |test, name, settings| {
	cwd = "${test.bench.work}/${name}"
	Path.create_dir!(Path.utf8(cwd))?
	platform_path = RocPackagesTest.relative(cwd, "${test.bench.root}/blueprint-platform/main.roc")
	Path.write_utf8!(Path.utf8("${cwd}/Blueprint.roc"), CliHostTest.blueprint_roc(platform_path, settings))?
	Ok(cwd)
}

## Write the lock as a Linux user does, with the Nix provider, then forget
## that Nix ran: nothing after this may run it.
lock! : Test, Str => Try({}, _)
lock! = |test, cwd| {
	outcome = CliHarness.blueprint!(test.bench, cwd, ["update"], test.env)?
	CliHarness.exited!(outcome, 0, "blueprint update with the Nix provider")?
	CliHarness.tool!(["chmod", "0444", "--", "${cwd}/Blueprint.lock"])?
	Path.delete_all!(Path.utf8("${cwd}/.blueprint"))?
	CliHarness.forget!("${cwd}/nix-calls")
}

## Write the lock a project's Spec asks for without resolving anything. The
## stubbed Nix cannot pin a Roc bundle; the host provider reads no pin, only
## that the lock is the Spec's.
unresolved_lock! : Test, Str => Try({}, _)
unresolved_lock! = |test, cwd| {
	printed = CliHarness.blueprint!(test.bench, cwd, ["spec"], CliHarness.setting(test.env, [host]))?
	CliHarness.exited!(printed, 0, "blueprint spec")?
	match Spec.parse(printed.stdout) {
		Ok(spec) => Path.write_utf8!(Path.utf8("${cwd}/Blueprint.lock"), Lock.to_str(Lock.{ format: Lock.current_format, intent: Lock.intent_of(spec), sources: [], hints: [], fetched: [] }))
		Err(_) => Script.fail!("blueprint spec did not print a Spec:\n${printed.stdout}")
	}
}

## Nix did not run and nothing was generated.
without_nix! : Str => Try({}, _)
without_nix! = |cwd| {
	CliHarness.same_calls!(CliHarness.calls!("${cwd}/nix-calls")?, [], "Nix ran in ${cwd}")?
	CliHarness.check!(!CliHarness.present!("${cwd}/.blueprint/flake.nix"), "${cwd}/.blueprint/flake.nix was generated")
}

cases! : CliHarness.Bench => Try({}, _)
cases! = |bench| {
	search = Env.var_str!(OsStr.from_str("PATH")) ?? ""
	test = {
		bench,
		env: CliHarness.setting(
			bench.env,
			[
				("PATH", "${bench.bin}:${search}"),
				("ROC", "${bench.bin}/roc-record"),
				("STUB_REAL_ROC", bench.roc),
				("STUB_NIX_FIXTURE", "${bench.root}/fixtures/consumer/inputs.lock"),
				("STUB_NIX_MODE", "declared"),
			],
		),
	}

	# Only `host` selects a provider; anything else is refused by name.
	unknown = project!(test, "unknown-provider", CliHostTest.plain)?
	CliHarness.contains!(run!(test, unknown, ["tasks"], 1, [("BLUEPRINT_PROVIDER", "guix")])?, "BLUEPRINT_PROVIDER selects the host provider with `host` and takes no other value, not \"guix\"", "tasks with an unknown provider")?
	CliHarness.check!(CliHarness.is_version(run!(test, unknown, ["--version"], 0, [("BLUEPRINT_PROVIDER", "guix")])?), "--version with an unknown provider did not print a version")?
	Script.pass!("BLUEPRINT_PROVIDER: an unknown provider is refused by name; --version still works")?

	# Reading the configuration needs no lock and no provider program.
	reading = project!(test, "reading", CliHostTest.plain)?
	CliHarness.contains!(run!(test, reading, ["tasks"], 0, [host])?, "say\t(plain)", "tasks")?
	CliHarness.contains!(run!(test, reading, ["spec"], 0, [host])?, "(name \"host-test\")", "spec")?
	CliHarness.contains!(run!(test, reading, ["check"], 0, [host])?, "Blueprint.roc is valid", "check")?
	CliHarness.check!(run!(test, reading, ["flake"], 0, [host])? == "", "flake printed a file the host provider does not generate")?
	without_nix!(reading)?
	Script.pass!("host provider: tasks, spec and check work; there is no generated file to print")?

	# What only Nix can do is refused before any effect, and says what to do.
	CliHarness.contains!(run!(test, reading, ["update"], 1, [host])?, "run `blueprint update` on Linux or macOS and commit Blueprint.lock", "update")?
	CliHarness.check!(!CliHarness.present!("${reading}/Blueprint.lock"), "a refused update wrote Blueprint.lock")?
	CliHarness.contains!(run!(test, reading, ["shell"], 1, [host])?, "a shell needs Nix, which this host does not have; run the task with `blueprint run`", "shell")?
	CliHarness.contains!(run!(test, reading, ["build", "app"], 1, [host])?, "a sandboxed build needs Nix on Linux, which this host does not have", "build")?
	CliHarness.contains!(run!(test, reading, ["run", "say"], 1, [host])?, "missing authoritative lock", "run without a lock")?
	without_nix!(reading)?
	Script.pass!("host provider: update, shell and build are refused, and a task still needs the lock")?

	# The lock the Nix provider wrote is the lock a task runs from here.
	running = project!(test, "running", CliHostTest.plain)?
	lock!(test, running)?
	CliHarness.check!(run!(test, running, ["run", "say"], 0, [host])? == "configured argument\n", "run say did not run the task's argv")?
	CliHarness.check!(run!(test, running, ["run", "say", "--", "extra one", "two"], 0, [host])? == "configured argument\nextra one\ntwo\n", "run say did not pass the extra arguments")?
	_ = run!(test, running, ["gen"], 0, [host])?
	without_nix!(running)?
	Script.pass!("host provider: a task runs from the lock the Nix provider wrote, without Nix; gen generates nothing")?

	# A roc-stable command is the nightly's compiler, fetched once into the
	# workspace and checked against the digest its release reports.
	build = match CliHostTest.build(Env.platform!()) {
		Ok(name) => name
		Err(NoBuild) => return Script.fail!("roc-lang/nightlies has no compiler for this machine")
	}
	top = "roc_nightly-${build}-${CliHostTest.tag.drop_prefix("nightly-")}"
	asset = "${top}.tar.gz"
	url = "https://github.com/roc-lang/nightlies/releases/download/${CliHostTest.tag}/${asset}"
	archive = "${bench.work}/archive"
	Path.write_utf8!(Path.utf8(archive), "the bytes of a release archive\n")?
	digest = Integrity.digest(Path.read_bytes!(Path.utf8(archive))?)
	tree = "${bench.work}/unpacked"
	Path.create_all!(Path.utf8("${tree}/${top}"))?
	Path.copy!(Path.utf8("${bench.work}/stub-tool"), Path.utf8("${tree}/${top}/roc"))?
	Path.write_utf8!(Path.utf8("${tree}/${top}/LICENSE"), "")?
	release = "${bench.work}/release.json"
	Path.write_utf8!(Path.utf8(release), "{\"assets\":[{\"name\":\"other\",\"digest\":\"sha256:${Integrity.digest([])}\"},{\"name\":\"${asset}\",\"digest\":\"sha256:${digest}\"}]}")?
	fetching = { ..test, env: CliHarness.unsetting(CliHarness.setting(test.env, [("STUB_CURL_ARCHIVE", archive), ("STUB_CURL_RELEASE", release), ("STUB_TAR_TREE", tree)]), ["GH_TOKEN", "GITHUB_TOKEN"]) }

	stable = project!(fetching, "stable", CliHostTest.stable)?
	lock!(fetching, stable)?
	store = "${stable}/.blueprint/host/commands/roc-stable/${CliHostTest.tag}"
	CliHarness.contains!(run!(fetching, stable, ["run", "version"], 0, [host])?, "stub roc-stable: version\n", "run version")?
	transfers = CliHarness.calls!("${stable}/curl-calls")?
	CliHarness.check!(
		match transfers {
			[asked, downloaded] => asked == CliHostTest.ask(CliHostTest.tag) and CliHostTest.downloads(downloaded, store, url)
			_ => False
		},
		"run version did not ask for the release's digests and then download ${url}: ${Str.inspect(transfers)}",
	)?
	unpacked = CliHarness.calls!("${stable}/tar-calls")?
	CliHarness.check!(unpacked.len() == 1 and unpacked.all(|call| CliHostTest.unpacks(call, store)), "run version did not unpack the download once: ${Str.inspect(unpacked)}")?
	CliHarness.same_calls!(CliHarness.calls!("${stable}/roc-stable-calls")?, [["version"]], "run version did not start the fetched roc-stable")?
	CliHarness.check!(CliHarness.names!("${store}/bin")? == ["roc-stable"], "the command's directory holds more than roc-stable: ${Str.inspect(CliHarness.names!("${store}/bin")?)}")?
	CliHarness.check!(CliHarness.names!("${stable}/.blueprint/host/commands/roc-stable")? == [CliHostTest.tag], "the fetch left something beside the command: ${Str.inspect(CliHarness.names!("${stable}/.blueprint/host/commands/roc-stable")?)}")?
	without_nix!(stable)?

	# What was fetched is generated state: the generated root ignores itself,
	# though this provider generates no file there.
	ignore = "${stable}/.blueprint/.gitignore"
	CliHarness.check!(Path.read_utf8!(Path.utf8(ignore)).map_ok(|text| text == "*\n") ?? False, "fetching into ${stable}/.blueprint did not write ${ignore}")?
	ignored = CliHarness.identity!(ignore)?

	# A command that is there is not fetched, and nothing is asked of anyone.
	for directory in ["curl-calls", "tar-calls", "roc-stable-calls"] {
		CliHarness.forget!("${stable}/${directory}")?
	}
	CliHarness.contains!(run!(fetching, stable, ["run", "version", "--", "again"], 0, [host, ("STUB_CURL_STATUS", "22")])?, "stub roc-stable: version again\n", "a second run version")?
	CliHarness.same_calls!(CliHarness.calls!("${stable}/curl-calls")?.concat(CliHarness.calls!("${stable}/tar-calls")?), [], "a second run fetched again")?
	CliHarness.check!(CliHarness.identity!(ignore)? == ignored, "a second run wrote ${ignore} again")?
	Script.pass!("host provider: roc-stable is fetched once, by the digest its release reports, and started by its own path")?

	# A token, when the caller has one, goes with the question on its standard
	# input: it is not an argument, where the host's other processes could read
	# it, and it is not printed.
	for case in [
		{ name: "gh", variables: [("GH_TOKEN", "first-secret"), ("GITHUB_TOKEN", "second-secret")], secret: "first-secret" },
		{ name: "github", variables: [("GITHUB_TOKEN", "second-secret")], secret: "second-secret" },
		{ name: "empty", variables: [("GH_TOKEN", ""), ("GITHUB_TOKEN", "second-secret")], secret: "second-secret" },
	] {
		cwd = project!(fetching, "token-${case.name}", CliHostTest.stable)?
		lock!(fetching, cwd)?
		output = run!(fetching, cwd, ["run", "version"], 0, [host].concat(case.variables))?
		CliHarness.check!(!output.contains("secret"), "run version printed the token:\n${output}")?
		CliHarness.check!(CliHarness.calls!("${cwd}/curl-calls")?.first() == Ok(CliHostTest.ask(CliHostTest.tag).concat(["--config", "-", "stdin:header = \"Authorization: Bearer ${case.secret}\"\n"])), "the question did not carry the token of ${case.name}")?
		refused = project!(fetching, "token-${case.name}-refused", CliHostTest.stable)?
		lock!(fetching, refused)?
		failure = run!(fetching, refused, ["run", "version"], 1, [host, ("STUB_CURL_STATUS", "22")].concat(case.variables))?
		CliHarness.contains!(failure, "could not learn the digest of ${asset}", "a failed question")?
		CliHarness.check!(!failure.contains("secret"), "a failed question printed the token:\n${failure}")?
	}
	quoted = project!(fetching, "token-quoted", CliHostTest.stable)?
	lock!(fetching, quoted)?
	unusable = run!(fetching, quoted, ["run", "version"], 1, [host, ("GH_TOKEN", "first\"secret")])?
	CliHarness.contains!(unusable, "the token in GH_TOKEN or GITHUB_TOKEN holds a character a request cannot carry", "a token with a quote")?
	CliHarness.check!(!unusable.contains("secret"), "a refused token was printed:\n${unusable}")?
	CliHarness.same_calls!(CliHarness.calls!("${quoted}/curl-calls")?, [], "a request was made with a token it could not carry")?
	Script.pass!("host provider: GH_TOKEN, else GITHUB_TOKEN, authorizes the question on standard input, never as an argument, and is never printed")?

	# Nothing is unpacked or run unless the download has the reported digest.
	mismatched = "${bench.work}/mismatched.json"
	Path.write_utf8!(Path.utf8(mismatched), "{\"assets\":[{\"name\":\"${asset}\",\"digest\":\"sha256:${Integrity.digest([])}\"}]}")?
	unlisted = "${bench.work}/unlisted.json"
	Path.write_utf8!(Path.utf8(unlisted), "{\"assets\":[{\"name\":\"other\",\"digest\":\"sha256:${digest}\"}]}")?
	limited = "${bench.work}/limited.json"
	Path.write_utf8!(Path.utf8(limited), "{\"message\":\"API rate limit exceeded\"}")?
	for case in [
		{ name: "mismatched", release: mismatched, diagnostic: "has SHA-256 ${digest}, not ${Integrity.digest([])}; nothing was unpacked", transfers: 2 },
		{ name: "unlisted", release: unlisted, diagnostic: "the release has no asset of that name", transfers: 1 },
		{ name: "limited", release: limited, diagnostic: "the release does not list its assets with digests", transfers: 1 },
	] {
		cwd = project!(fetching, "digest-${case.name}", CliHostTest.stable)?
		lock!(fetching, cwd)?
		CliHarness.contains!(run!(fetching, cwd, ["run", "version"], 1, [host, ("STUB_CURL_RELEASE", case.release)])?, case.diagnostic, "run version with a ${case.name} digest")?
		CliHarness.check!(CliHarness.calls!("${cwd}/curl-calls")?.len() == case.transfers, "a ${case.name} digest did not stop the fetch where it should")?
		CliHarness.same_calls!(CliHarness.calls!("${cwd}/tar-calls")?.concat(CliHarness.calls!("${cwd}/roc-stable-calls")?), [], "a ${case.name} digest was unpacked or run")?
		CliHarness.check!(CliHarness.names!("${cwd}/.blueprint/host/commands/roc-stable")? == [], "a ${case.name} digest left something in the workspace")?
	}
	Script.pass!("host provider: a download whose digest is wrong, unlisted or unreported is neither unpacked nor run")?

	# Windows does not read `#!/usr/bin/env roc-stable`, so a Roc script is
	# started the way that line asks: by roc-stable, with the script's path as
	# the task wrote it and then the arguments. Whatever the task starts finds
	# the command too, ahead of everything the caller had on PATH.
	Path.create_dir!(Path.utf8("${stable}/scripts"))?
	Path.write_utf8!(Path.utf8("${stable}/scripts/check_all.roc"), "#!/usr/bin/env roc-stable\n")?
	CliHarness.forget!("${stable}/roc-stable-calls")?
	CliHarness.contains!(run!(fetching, stable, ["run", "check", "--", "one", "two words"], 0, [host])?, "stub roc-stable: scripts/check_all.roc --quick one two words\n", "run check")?
	CliHarness.same_calls!(CliHarness.calls!("${stable}/roc-stable-calls")?, [["scripts/check_all.roc", "--quick", "one", "two words"]], "run check did not start the script through roc-stable")?
	searched = run!(fetching, stable, ["run", "path"], 0, [host])?
	CliHarness.check!(searched.starts_with("${store}/bin:${bench.bin}:"), "the command's directory is not ahead of the caller's PATH: ${searched}")?
	CliHarness.contains!(run!(fetching, running, ["run", "script"], 1, [host])?, "task script runs the Roc script check.roc, which roc-stable starts; give environment plain a Command(\"roc-stable\", ...) that names a Roc nightly", "a Roc script without roc-stable")?
	Script.pass!("host provider: a Roc script is started through roc-stable with its arguments; the command leads PATH")?

	# A program named by a relative path is the project's, wherever the caller is.
	Path.create_dir!(Path.utf8("${running}/tools"))?
	Path.copy!(Path.utf8("${bench.work}/stub-tool"), Path.utf8("${running}/tools/roc-stable"))?
	elsewhere = CliHarness.blueprint!(bench, bench.work, ["run", "local"], CliHarness.setting(test.env, [host, ("BLUEPRINT_ROOT", running)]))?
	CliHarness.exited!(elsewhere, 0, "run local from another directory")?
	CliHarness.same_calls!(CliHarness.calls!("${running}/roc-stable-calls")?, [["from the project"]], "run local did not start the project's program in the project")?
	Script.pass!("host provider: a relative program is started from the project root, not the caller's directory")?

	# A Roc package is downloaded under its own name and unpacked by the
	# compiler into Roc's package cache, once. The bundle is a real one, made
	# here, so the compiler's check of its name against its bytes is real too.
	library = "${bench.work}/package"
	Path.create_dir!(Path.utf8(library))?
	Path.write_utf8!(Path.utf8("${library}/main.roc"), "package [Hello] {}\n")?
	Path.write_utf8!(Path.utf8("${library}/Hello.roc"), "Hello := [].{\n\tgreeting : Str\n\tgreeting = \"hello\"\n}\n")?
	bundles = "${bench.work}/bundles"
	Path.create_dir!(Path.utf8(bundles))?
	bundled = CliHarness.invoke!({ program: bench.roc, args: ["bundle", "main.roc", "Hello.roc", "--output-dir", bundles], cwd: library, env: bench.env })?
	CliHarness.exited!(bundled, 0, "roc bundle")?
	file = match CliHarness.names!(bundles)? {
		[only] if only.ends_with(".tar.zst") => only
		other => return Script.fail!("roc bundle did not write one bundle: ${Str.inspect(other)}")
	}
	hash = file.drop_suffix(".tar.zst")
	bundle_url = "https://example.invalid/releases/download/1.0.0/${file}"
	packaged = project!(
		test,
		"packages",
		[
			"Name(\"host-test\"),",
			"Environment(\"packages\", [RocPackages([\"${bundle_url}\"])]),",
			"Task(\"use\", [Use(\"packages\"), Run([\"printf\", \"%s\\n\", \"ran with packages\"])]),",
		],
	)?
	unresolved_lock!(test, packaged)?
	cache = "${bench.work}/xdg-packages"
	published = "${cache}/roc/packages"
	bundling = [host, ("XDG_CACHE_HOME", cache), ("STUB_CURL_ARCHIVE", "${bundles}/${file}"), ("STUB_CURL_LOG", "${packaged}/curl-calls")]
	CliHarness.contains!(run!(test, packaged, ["run", "use"], 0, bundling)?, "ran with packages\n", "run use")?
	CliHarness.same_calls!(CliHarness.calls!("${packaged}/curl-calls")?, [CliHostTest.transfer.concat(["--output", file, bundle_url])], "run use did not download the bundle under its own name")?
	CliHarness.check!(CliHarness.names!(published)? == [hash], "Roc's package cache holds more or less than the bundle: ${Str.inspect(CliHarness.names!(published)?)}")?
	CliHarness.check!(Path.read_utf8!(Path.utf8("${published}/${hash}/main.roc"))? == "package [Hello] {}\n" and CliHarness.present!("${published}/${hash}/Hello.roc"), "the published package is not the bundle's tree")?
	CliHarness.forget!("${packaged}/curl-calls")?
	CliHarness.contains!(run!(test, packaged, ["run", "use"], 0, bundling.append(("STUB_CURL_STATUS", "22")))?, "ran with packages\n", "a second run use")?
	CliHarness.same_calls!(CliHarness.calls!("${packaged}/curl-calls")?, [], "a package that is there was downloaded again")?
	without_nix!(packaged)?

	# Bytes that are not the bundle its name is the hash of are not published,
	# and the task does not run.
	other_cache = "${bench.work}/xdg-refused"
	refused = run!(test, packaged, ["run", "use"], 1, [host, ("XDG_CACHE_HOME", other_cache), ("STUB_CURL_ARCHIVE", archive), ("STUB_CURL_LOG", "${packaged}/curl-calls")])?
	CliHarness.contains!(refused, "cannot fetch Roc package ${hash}", "run use with other bytes")?
	CliHarness.contains!(refused, "nothing was published", "run use with other bytes")?
	CliHarness.check!(!refused.contains("ran with packages"), "the task ran without its package:\n${refused}")?
	CliHarness.check!(CliHarness.names!("${other_cache}/roc/packages")? == [], "a refused bundle left something in Roc's package cache: ${Str.inspect(CliHarness.names!("${other_cache}/roc/packages")?)}")?
	Script.pass!("host provider: a Roc package is downloaded and unbundled into Roc's cache once; other bytes are not published")?

	# A tool is a program this host must already have. The only programs on
	# PATH here are the stubs, so `zig` is there and `git` and `cargo` are not.
	tooled = project!(
		test,
		"tooled",
		CliHostTest.plain.concat([
			"Environment(\"zig\", [Extend(\"plain\"), Tools([\"zig\"])]),",
			"Environment(\"pinned\", [Extend(\"plain\"), Tools([\"zigpkgs.\\\"0.16.0\\\"\"])]),",
			"Environment(\"host\", [Extend(\"pinned\"), Tools([\"git\", \"cargo\"])]),",
			"Environment(\"other\", [Extend(\"zig\"), Tools([\"python3\", \"ripgrep\"])]),",
			"Task(\"any\", [Use(\"zig\"), Run([\"zig\", \"build\"])]),",
			"Task(\"exact\", [Use(\"pinned\"), Run([\"zig\", \"build\"])]),",
			"Task(\"lacking\", [Use(\"host\"), Run([\"zig\", \"build\"])]),",
			"Task(\"unknown\", [Use(\"other\"), Run([\"zig\", \"build\"])]),",
		]),
	)?
	lock!(test, tooled)?
	Path.create_dir!(Path.utf8("${bench.work}/only"))?
	for name in ["zig", "nix"] {
		Path.copy!(Path.utf8("${bench.work}/stub-tool"), Path.utf8("${bench.work}/only/${name}"))?
	}
	present = [host, ("PATH", "${bench.work}/only"), ("STUB_ZIG_VERSION", "0.15.2")]
	_ = run!(test, tooled, ["run", "any"], 0, present)?
	CliHarness.same_calls!(CliHarness.calls!("${tooled}/zig-calls")?, [["version"], ["build"]], "run any did not check for zig and then run the task")?
	CliHarness.forget!("${tooled}/zig-calls")?
	CliHarness.contains!(run!(test, tooled, ["run", "exact"], 1, present)?, "  zigpkgs.\"0.16.0\": `zig version` printed 0.15.2, not 0.16.0", "run exact with another zig")?
	CliHarness.same_calls!(CliHarness.calls!("${tooled}/zig-calls")?, [["version"]], "a task ran with the wrong zig")?
	CliHarness.forget!("${tooled}/zig-calls")?
	_ = run!(test, tooled, ["run", "exact"], 0, [host, ("PATH", "${bench.work}/only"), ("STUB_ZIG_VERSION", "0.16.0")])?
	CliHarness.same_calls!(CliHarness.calls!("${tooled}/zig-calls")?, [["version"], ["build"]], "run exact did not run the task with the zig it names")?
	CliHarness.forget!("${tooled}/zig-calls")?
	lacking = run!(test, tooled, ["run", "lacking"], 1, present)?
	for line in ["this host does not have what the task's environment declares, and nothing is installed here:", "  zigpkgs.\"0.16.0\": `zig version` printed 0.15.2, not 0.16.0", "  git: `git --version` could not be run", "  cargo: `cargo --version` could not be run"] {
		CliHarness.contains!(lacking, line, "run lacking")?
	}
	CliHarness.same_calls!(CliHarness.calls!("${tooled}/zig-calls")?, [["version"]], "a task ran without its tools")?
	CliHarness.contains!(run!(test, tooled, ["run", "unknown"], 1, present)?, "environment other declares tools this host cannot check for: python3, ripgrep; it knows git, gh, gnutar, zip, unzip, go, zig, zigpkgs.\"<version>\", cargo, rustc and rust-bin.stable.\"<version>\".default", "run unknown")?
	without_nix!(tooled)?
	Script.pass!("host provider: a tool is checked for, by version when its name carries one; every missing or unknown tool is named at once")
}

expect CliHostTest.blueprint_roc("../pf/main.roc", ["Name(\"a\"),"]) == "app [config] { pf: platform \"../pf/main.roc\" }\nconfig = [\n\tName(\"a\"),\n]\n"

expect CliHostTest.build({ arch: X64, os: LINUX }) == Ok("linux_x86_64") and CliHostTest.build({ arch: X64, os: WINDOWS }) == Err(NoBuild)

expect CliHostTest.fresh("/p/.blueprint/host/commands/roc-stable/.blueprint-fetch-a1B2/archive", "/p/.blueprint/host/commands/roc-stable/nightly-2026-01-02-abcdef0", "archive")
expect
	["/p/.blueprint/host/commands/roc-stable/archive", "/p/.blueprint/host/commands/roc-stable/nightly-2026-01-02-abcdef0/archive", "/tmp/.blueprint-fetch-a1B2/archive", "/p/.blueprint/host/commands/roc-stable/.blueprint-fetch-a1B2/tree"].all(
		|file| !CliHostTest.fresh(file, "/p/.blueprint/host/commands/roc-stable/nightly-2026-01-02-abcdef0", "archive"),
	)

expect CliHostTest.downloads(CliHostTest.transfer.concat(["--output", "/p/w/.blueprint-fetch-x/archive", "https://example.invalid/a"]), "/p/w/tag", "https://example.invalid/a")
expect !CliHostTest.downloads(CliHostTest.transfer.concat(["--output", "/p/w/.blueprint-fetch-x/archive", "https://example.invalid/b"]), "/p/w/tag", "https://example.invalid/a")
expect CliHostTest.unpacks(["-xf", "/p/w/.blueprint-fetch-x/archive", "-C", "/p/w/.blueprint-fetch-x/tree"], "/p/w/tag")
expect !CliHostTest.unpacks(["-xf", "/p/w/.blueprint-fetch-x/archive", "-C", "/p/w/.blueprint-fetch-y/tree"], "/p/w/tag")
