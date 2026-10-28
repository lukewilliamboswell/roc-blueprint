import cli.Env
import cli.Path
import Bundle
import Process
import Script
import Serve

## The examples as a release ships them: an archive of the projects under
## `examples/` whose platform is that release's bundle, with the Spec each one
## prints.
##
## An archived example differs from the repository's in its platform line
## alone, and the archive is tested as it will be downloaded: unpacked, with
## an empty package cache, against the bundles served from localhost at the
## paths the release will give them.
Examples := [].{

	Case : { name : Str, args : List(Str), stdin : Str, stdout : Str, stderr : Str, exit_code : I32 }
	App : { path : Str, cases : List(Case) }
	Suite : { schema_version : U64, release : Str, dependencies : List(Str), apps : List(App) }

	manifest : Suite, Str, List(Str) -> Str
	manifest = |suite, version, dependencies| Json.to_str({ ..suite, release: version, dependencies })

	valid_suite : Suite, List(Str) -> Bool
	valid_suite = |suite, projects|
		suite.schema_version == 1 and suite.release == "working-tree" and suite.dependencies.is_empty()
			and Process.sorted(suite.apps.map(|example| example.path)) == Process.sorted(projects.map(|project| "examples/${project}/Blueprint.roc"))
				and !projects.is_empty()
					and suite.apps.all(
						|example| match example.cases {
							[case] => case.name == "spec" and case.args.is_empty() and case.stdin == "" and case.stderr == "" and case.exit_code == 0
							_ => Bool.False
						},
					)

	## What an example in this repository names as its platform.
	local_platform = "platform \"../../blueprint-platform/main.roc\""

	## The projects `blueprint` refuses to load, each with what it says. The
	## compiler still checks them and prints their Spec.
	refused = [("extensions", "needs features: extensions")]

	## The archive's name without `.zip`, which is also its one top directory.
	archive_name : Str -> Str
	archive_name = |version| "roc-blueprint-examples-${version}"

	## The files of the example projects among those git tracks under
	## `examples/`, as paths below it. A file directly in `examples/` belongs
	## to no project.
	project_files : Str -> List(Str)
	project_files = |tracked|
		Process.lines(tracked).map(|file| file.drop_prefix("examples/")).keep_if(|file| file.split_on("/").len() > 1)

	## The projects: each directory with a `Blueprint.roc`.
	projects : List(Str) -> List(Str)
	projects = |files| files.keep_if(|file| file.split_on("/").drop_first(1) == ["Blueprint.roc"]).map(|file| file.drop_suffix("/Blueprint.roc"))

	## An example's `Blueprint.roc` with the release's platform.
	released : Str, Str -> Try(Str, [NoLocalPlatform])
	released = |source, platform_url|
		if source.contains(local_platform) {
			Ok(source.replace_each(local_platform, "platform \"${platform_url}\""))
		} else {
			Err(NoLocalPlatform)
		}

	## Every file the archive holds, below its top directory.
	contents : List(Str) -> List(Str)
	contents = |files| Process.sorted(["README.md", "spec.json"].concat(files.map(|file| "examples/${file}")))

	readme : { version : Str, platform_url : Str, projects : List(Str) } -> Str
	readme = |release|
		Str.join_with(
			[
				"# roc-blueprint ${release.version} examples",
				"",
				"The example projects of roc-blueprint, as they were tested for release",
				"${release.version}. Each `Blueprint.roc` names that release's platform:",
				"",
				"```roc",
				"app [config] { pf: platform \"${release.platform_url}\" }",
				"```",
				"",
				"Projects: ${Str.join_with(release.projects, ", ")}.",
				"",
				"To use one, install the `blueprint` binary of the same release, then in the",
				"project's directory:",
				"",
				"```sh",
				"blueprint check     # validate Blueprint.roc",
				"blueprint update    # resolve inputs and write Blueprint.lock",
				"blueprint tasks     # list what the project can run",
				"```",
				"",
				"`spec.json` records the reviewed expected Spec output for each project.",
				"Projects are under `examples/`; `blueprint spec` prints their Spec. The `extensions`",
				"project declares extensions no provider implements, so `blueprint check`",
				"refuses it with `needs features: extensions`: that is what it shows.",
				"",
			],
			"\n",
		)

	## Write `dist/roc-blueprint-examples-<version>.zip` for the bundles
	## `scripts/bundle.roc` made for `version`.
	package! : Str, Str => Try({}, _)
	package! = |root, version| {
		work = Process.portable(Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-examples-")?)?)?)
		result = staged!(root, version, work)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}

	## Unpack the archive of `version` and test it against the bundles in
	## `dist/`; with a `binary`, run that `blueprint` on each project too.
	test! : Str, Str, Str => Try({}, _)
	test! = |root, version, binary| {
		work = Process.portable(Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-release-")?)?)?)
		server = Serve.open!()?
		result = unpacked!(root, version, binary, work, server)
		_ = server.shut!()
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

## What `scripts/bundle.roc` made, and where the release will serve it.
Bundles : { platform_archive : Str, core_archive : Str, platform_url : Str, core_url : Str }

bundles! : Str, Str => Try(Bundles, _)
bundles! = |root, version| {
	list = Path.read_utf8!(Path.utf8("${root}/dist/bundles.txt"))?
	repository = Bundle.repository!()
	match (Bundle.archive(list, "roc-blueprint"), Bundle.archive(list, "roc-blueprint-core")) {
		(Ok(platform_archive), Ok(core_archive)) =>
			Ok({
				platform_archive,
				core_archive,
				platform_url: Bundle.release_url(repository, version, platform_archive),
				core_url: Bundle.release_url(repository, version, core_archive),
			})
		_ => Script.fail!("dist/bundles.txt does not list both bundles: run scripts/bundle.roc ${version}")
	}
}

tracked! : Str => Try(List(Str), _)
tracked! = |root| {
	listed = Process.succeed!(Process.command("git", ["ls-files", "--", "examples"], root))?
	files = Examples.project_files(listed.stdout)
	if Examples.projects(files).is_empty() Script.fail!("git tracks no example project under examples/") else Ok(files)
}

parent : Str -> Str
parent = |file| Str.join_with(file.split_on("/").drop_last(1), "/")

staged! : Str, Str, Str => Try({}, _)
staged! = |root, version, work| {
	bundled = bundles!(root, version)?
	files = tracked!(root)?
	name = Examples.archive_name(version)
	top = "${work}/${name}"

	Script.info!("==>", "Staging the examples for ${bundled.platform_url}")?
	for file in files {
		target = "${top}/examples/${file}"
		Path.create_all!(Path.utf8(parent(target)))?
		if file.ends_with("/Blueprint.roc") {
			source = Path.read_utf8!(Path.utf8("${root}/examples/${file}"))?
			match Examples.released(source, bundled.platform_url) {
				Ok(text) => Path.write_utf8!(Path.utf8(target), text)?
				Err(NoLocalPlatform) => return Script.fail!("examples/${file} does not name the local platform")
			}
		} else {
			Path.copy!(Path.utf8("${root}/examples/${file}"), Path.utf8(target))?
		}
	}

	projects = Examples.projects(files)
	suite = suite!(root, projects)?
	Path.write_utf8!(Path.utf8("${top}/spec.json"), Examples.manifest(suite, version, [bundled.platform_url, bundled.core_url]))?
	Path.write_utf8!(Path.utf8("${top}/README.md"), Examples.readme({ version, platform_url: bundled.platform_url, projects }))?

	archive = "${root}/dist/${name}.zip"
	if Path.exists!(Path.utf8(archive))? {
		Path.delete!(Path.utf8(archive))?
	}
	_ = Process.succeed!(Process.command("zip", ["-q", "-r", "-X", archive, name], work))?
	Script.pass!("wrote dist/${name}.zip with ${projects.len().to_str()} projects")
}

unpacked! : Str, Str, Str, Str, Serve => Try({}, _)
unpacked! = |root, version, binary, work, idle| {
	bundled = bundles!(root, version)?
	files = tracked!(root)?
	name = Examples.archive_name(version)
	archive = "${root}/dist/${name}.zip"
	top = "${work}/${name}"

	Script.info!("==>", "The archive holds the examples with only the platform changed")?
	windows = (Env.platform!()).os == WINDOWS
	listed = Process.succeed!(Process.command(if windows "tar" else "unzip", if windows ["-tf", archive] else ["-Z1", archive], root))?
	held = Process.sorted(Process.lines(listed.stdout).keep_if(|entry| !entry.ends_with("/")))
	wanted = Examples.contents(files).map(|file| "${name}/${file}")
	Process.check!(held == wanted, "dist/${name}.zip holds:\n${Str.join_with(held, "\n")}\nexpected:\n${Str.join_with(wanted, "\n")}")?
	_ = Process.succeed!(Process.command(if windows "tar" else "unzip", if windows ["-xf", archive, "-C", work] else ["-q", archive, "-d", work], root))?
	suite = suite!(root, Examples.projects(files))?
	manifest = Path.read_utf8!(Path.utf8("${top}/spec.json"))?
	Process.check!(manifest == Examples.manifest(suite, version, [bundled.platform_url, bundled.core_url]), "archived suite differs from reviewed expectations")?
	for file in files {
		ours = Path.read_bytes!(Path.utf8("${root}/examples/${file}"))?
		theirs = Path.read_bytes!(Path.utf8("${top}/examples/${file}"))?
		same = if file.ends_with("/Blueprint.roc") {
			Examples.released(Str.from_utf8_lossy(ours), bundled.platform_url) == Ok(Str.from_utf8_lossy(theirs))
		} else {
			ours == theirs
		}
		Process.check!(same, "the archived ${file} differs from examples/${file} in more than its platform")?
	}

	repository = Bundle.repository!()
	route = |asset| Bundle.release_path(repository, version, asset)
	server = idle.with_route(route(bundled.platform_archive), Path.read_bytes!(Path.utf8("${root}/dist/${bundled.platform_archive}"))?).with_route(route(bundled.core_archive), Path.read_bytes!(Path.utf8("${root}/dist/${bundled.core_archive}"))?)
	arguments = Bundle.replacing(bundled.platform_url, server.url(route(bundled.platform_archive))).concat(Bundle.replacing(bundled.core_url, server.url(route(bundled.core_archive))))
	# Its own package cache, empty: the bundles must come from this process.
	environment = [("XDG_CACHE_HOME", if windows "${work}/cache".replace_each("/", "\\") else "${work}/cache")]
	roc = Process.roc!()

	Script.info!("==>", "Each archived example checks and prints its recorded Spec against the served bundles")?
	projects = Examples.projects(files)
	for project in projects {
		directory = "${top}/examples/${project}"
		compiler = |args| Process.with_env(Process.command(roc, args.concat(["--no-cache"]).concat(arguments).concat(["Blueprint.roc"]), directory), environment)
		recorded = expected!(suite, project)?
		match server.drive!([compiler(["check"])])? {
			[checked] => Process.check!(checked.code == 0, "${checked.stdout}${checked.stderr}\nroc check of the archived ${project} example exited with code ${checked.code.to_str()}")?
			_ => return Script.fail!("roc check did not report a result")
		}
		executable = "${work}/example${if windows ".exe" else ""}"
		native_executable = if windows executable.replace_each("/", "\\") else executable
		match server.drive!([compiler(["build", "--output=${native_executable}"])])? {
			[built] => Process.check!(built.code == 0, "${built.stdout}${built.stderr}")?
			_ => return Script.fail!("build did not report a result")
		}
		match server.drive!([Process.with_env(Process.command(executable, [], directory), environment)])? {
			[ran] => Process.check!(ran.code == 0 and ran.stdout == recorded and ran.stderr == "", "${ran.stdout}${ran.stderr}\nthe archived ${project} example did not print its recorded Spec (exit ${ran.code.to_str()})")?
			_ => return Script.fail!("the archived ${project} example did not report a result")
		}
		Script.info!("   ", project)?
	}

	if binary.is_empty() {
		return Script.pass!("${projects.len().to_str()} archived examples match the repository and their recorded Specs")
	}

	# The binary runs the compiler itself and cannot be told where a bundle
	# is. The cache now holds both, by hash, so it needs no server.
	Script.info!("==>", "${binary} loads each archived example from the downloaded bundles")?
	for project in projects {
		directory = "${top}/examples/${project}"
		recorded = expected!(suite, project)?
		printed = Process.traced!(Process.with_env(Process.command(binary, ["spec"], directory), environment))?
		match Examples.refused.find_first(|(refused_project, _)| refused_project == project) {
			Ok((_, reason)) => Process.check!(printed.code != 0 and printed.stderr.contains(reason), "${printed.stdout}${printed.stderr}\nblueprint was expected to refuse the archived ${project} example with: ${reason} (exit ${printed.code.to_str()})")?
			Err(_) => Process.check!(printed.code == 0 and printed.stdout == recorded, "${printed.stdout}${printed.stderr}\nblueprint spec of the archived ${project} example did not print its recorded Spec (exit ${printed.code.to_str()})")?
		}
	}
	Script.pass!("${projects.len().to_str()} archived examples match the repository and their recorded Specs, through the compiler and through ${binary}")
}

tracked_sample = "examples/README.md\nexamples/all-settings/Blueprint.roc\nexamples/artifacts/Blueprint.roc\nexamples/artifacts/scripts/check.roc\nexamples/composition/Blueprint.roc\nexamples/composition/ProjectTasks.roc\n"

expect Examples.archive_name("0.5.0-rc1") == "roc-blueprint-examples-0.5.0-rc1"

# The README beside the projects describes the repository's copy, not the archive's.
expect Examples.project_files(tracked_sample) == ["all-settings/Blueprint.roc", "artifacts/Blueprint.roc", "artifacts/scripts/check.roc", "composition/Blueprint.roc", "composition/ProjectTasks.roc"]
expect Examples.projects(Examples.project_files(tracked_sample)) == ["all-settings", "artifacts", "composition"]
expect Examples.projects(["artifacts/scripts/Blueprint.roc"]).is_empty()

expect Examples.released("app [config] { pf: platform \"../../blueprint-platform/main.roc\" }\n", "https://example.test/a.tar.zst") == Ok("app [config] { pf: platform \"https://example.test/a.tar.zst\" }\n")
expect Examples.released("app [config] { pf: platform \"../platform/main.roc\" }\n", "https://example.test/a.tar.zst") == Err(NoLocalPlatform)

expect Examples.contents(["composition/Blueprint.roc", "composition/ProjectTasks.roc"]) == ["README.md", "examples/composition/Blueprint.roc", "examples/composition/ProjectTasks.roc", "spec.json"]

expect Examples.readme({ version: "0.5.0", platform_url: "https://example.test/a.tar.zst", projects: ["one", "two"] }).contains("app [config] { pf: platform \"https://example.test/a.tar.zst\" }\n")
expect Examples.readme({ version: "0.5.0", platform_url: "u", projects: ["one", "two"] }).contains("Projects: one, two.\n")

## Expectations are reviewed source, never inferred while packaging a release.
suite! : Str, List(Str) => Try(Examples.Suite, _)
suite! = |root, projects| {
	text = Path.read_utf8!(Path.utf8("${root}/tests/spec.json"))?
	parsed : Try(Examples.Suite, _)
	parsed = Json.parse(text)
	suite = parsed.map_err(|_| ScriptFailed)?
	Process.check!(Examples.valid_suite(suite, projects), "suite must declare one runnable Spec case per Blueprint and use working-tree release with no dependencies")?
	Ok(suite)
}

expected! : Examples.Suite, Str => Try(Str, _)
expected! = |suite, project| {
	selected = suite.apps.find_first(|example| example.path == "examples/${project}/Blueprint.roc").map_err(|_| ScriptFailed)?
	case = selected.cases.first().map_err(|_| ScriptFailed)?
	Ok(case.stdout)
}

suite_case = { name: "spec", args: [], stdin: "", stdout: "(spec \"quoted\")\n", stderr: "", exit_code: 0 }

suite_sample = { schema_version: 1, release: "working-tree", dependencies: [], apps: [{ path: "examples/one/Blueprint.roc", cases: [suite_case] }] }
expect Examples.valid_suite(suite_sample, ["one"])
expect !Examples.valid_suite(suite_sample, ["one", "two"])
expect !Examples.valid_suite({ ..suite_sample, apps: suite_sample.apps.concat(suite_sample.apps) }, ["one"])
expect !Examples.valid_suite({ ..suite_sample, release: "1.0.0" }, ["one"])
expect !Examples.valid_suite({ ..suite_sample, apps: [{ path: "examples/one/Blueprint.roc", cases: [] }] }, ["one"])
expect !Examples.valid_suite({ ..suite_sample, apps: [{ path: "examples/one/Blueprint.roc", cases: [{ ..suite_case, exit_code: 1 }] }] }, ["one"])
expect {
	parsed : Try(Examples.Suite, _)
	parsed = Json.parse(Examples.manifest(suite_sample, "0.9.0", ["https://example.test/core.tar.zst"]))
	parsed == Ok({ ..suite_sample, release: "0.9.0", dependencies: ["https://example.test/core.tar.zst"] })
}
