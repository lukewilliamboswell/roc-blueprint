import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import Script

## An end-to-end test of the `RocPackages` setting against the real
## `./blueprint` and real Nix.
##
## Every command runs with `XDG_CACHE_HOME` set to a directory this test
## creates, so the Roc package cache it publishes into, breaks and repairs is
## never the user's.
RocPackagesTest := [].{
	basic_cli = "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst"

	## basic-cli depends on this; a project must list it too.
	http = "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst"

	## An explicit nightly, so the compiler resolving these bundles is known.
	roc_tag = "nightly-2026-10-04-130536d"

	greeting = "Hello from locked packages"

	## The directory Roc looks for: the bundle's file name without `.tar.zst`.
	hash : Str -> Str
	hash = |url| (url.split_on("/").last() ?? "").drop_suffix(".tar.zst")

	## `to` as seen from the directory `from`; both absolute. Roc refuses an
	## absolute platform path.
	relative : Str, Str -> Str
	relative = |from, to| {
		parts = |text| text.split_on("/").keep_if(|part| !part.is_empty())
		start = parts(from)
		end = parts(to)
		var $shared = 0
		while $shared < start.len() and $shared < end.len() and start.get($shared) == end.get($shared) {
			$shared = $shared + 1
		}
		Str.join_with(start.drop_first($shared).map(|_| "..").concat(end.drop_first($shared)), "/")
	}

	## Whether `inner` is `outer` or lies beneath it; both absolute.
	within : Str, Str -> Bool
	within = |inner, outer| inner == outer or inner.starts_with("${outer.drop_suffix("/")}/")

	## A project whose `dev` environment inherits the listed bundles and runs
	## Roc as `roc-stable`; `plain` has no Roc packages at all.
	blueprint_roc : Str, List(Str) -> Str
	blueprint_roc = |platform_path, bundles| {
		urls = Str.join_with(bundles.map(|url| "\"${url}\""), ", ")
		Str.join_with(
			[
				"app [config] { pf: platform \"${platform_path}\" }",
				"",
				"config = [",
				"	Name(\"roc-packages\"),",
				"	Systems([\"x86_64-linux\"]),",
				"	Overlay(\"roc\", \"github:roc-lang/roc-overlay\"),",
				"	Environment(\"packages\", [RocPackages([${urls}])]),",
				"	Environment(\"dev\", [Extend(\"packages\"), Overlays([\"roc\"]), Command(\"roc-stable\", \"rocpkgs.${roc_tag}\")]),",
				"	Environment(\"plain\", [Tools([\"hello\"])]),",
				"	Shell(\"default\", [Use(\"dev\")]),",
				"	Task(\"version\", [Use(\"dev\"), Run([\"roc-stable\", \"version\"])]),",
				"	Task(\"hello\", [Use(\"dev\"), Run([\"roc-stable\", \"main.roc\"])]),",
				"	Task(\"plain\", [Use(\"plain\"), Run([\"hello\"])]),",
				"	Build(\"offline\", [Use(\"dev\"), Run([\"roc-stable\", \"main.roc\", \"greeting.txt\"]), Output(\"greeting.txt\")]),",
				"]",
				"",
			],
			"\n",
		)
	}

	## A basic-cli program: it prints the greeting, or writes it to the file it
	## is given. A build has no shell to redirect its output.
	app_roc : Str
	app_roc = Str.join_with(
		[
			"app [main!] { cli: platform \"${basic_cli}\" }",
			"",
			"import cli.Path",
			"import cli.Stdout",
			"",
			"main! = |args|",
			"	match args {",
			"		[file] => Path.from_os_str(file).write_utf8!(\"${greeting}\\n\").map_err(|_| Exit(1))",
			"		_ => Stdout.line!(\"${greeting}\").map_err(|_| Exit(1))",
			"	}",
			"",
		],
		"\n",
	)

	## Run every scenario from the repository root, in a temporary directory
	## that is removed afterwards.
	run! : Path => Try({}, _)
	run! = |root| {
		blueprint = Path.join(root, "blueprint")
		if !(Path.is_file!(blueprint) ?? False) {
			return Script.fail!("./blueprint is missing; build it with `roc build blueprint-cli/main.roc --output=./blueprint`")
		}
		work = Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-roc-packages-")?)?
		result = scenarios!({ root: Path.to_str(Path.canonicalize!(root)?)?, blueprint, work: Path.to_str(work)? })
		# A failed scenario may have left a directory read-only.
		_ = Cmd.new_str("chmod").args_str(["-R", "u+w", "--"]).arg(Path.to_os_str(work)).exec_cmd!()
		_ = Path.delete_all!(work)
		result
	}
}

Context : { root : Str, blueprint : Path, work : Str }

Outcome : { code : I32, stdout : Str, stderr : Str }

## Run `./blueprint` in a project with the given private cache. Its exit code
## and output are data: several scenarios expect a failure.
blueprint! : Context, Str, Str, List(Str) => Try(Outcome, _)
blueprint! = |context, cache, project, args| {
	Stdout.line!("RUN  blueprint ${Str.join_with(args, " ")}")?
	ran = Cmd.new(Path.to_os_str(context.blueprint)).args_str(args)
		.cwd(Path.utf8(project))
		.env_str("XDG_CACHE_HOME", cache)
		.run!()
	match ran {
		Ok({ status, stdout_bytes, stderr_bytes }) => {
			code = match status {
				Exited(exit_code) => exit_code
				Signaled(signal) => 128 + signal
			}
			Ok({ code, stdout: Str.from_utf8_lossy(stdout_bytes), stderr: Str.from_utf8_lossy(stderr_bytes) })
		}
		Err(_) => Script.fail!("could not run ./blueprint ${Str.join_with(args, " ")}")
	}
}

## The command must succeed; its captured stderr explains a failure.
succeed! : Context, Str, Str, List(Str) => Try(Outcome, _)
succeed! = |context, cache, project, args| {
	outcome = blueprint!(context, cache, project, args)?
	if outcome.code != 0 {
		return Script.fail!("blueprint ${Str.join_with(args, " ")} exited with code ${outcome.code.to_str()}:\n${outcome.stderr}")
	}
	Ok(outcome)
}

check! : Bool, Str => Try({}, _)
check! = |holds, message| if holds Ok({}) else Script.fail!(message)

## The entry names of a directory, or none when it does not exist.
names! : Str => Try(List(Str), _)
names! = |directory| {
	if !(Path.is_dir!(Path.utf8(directory)) ?? False) {
		return Ok([])
	}
	var $names = []
	for entry in Path.list!(Path.utf8(directory))? {
		$names = $names.append(Path.to_str(entry)?.split_on("/").last() ?? "")
	}
	Ok($names)
}

same_names : List(Str), List(Str) -> Bool
same_names = |left, right| left.len() == right.len() and left.all(|name| right.contains(name))

## A staging directory Blueprint or Roc left behind.
leftover : Str -> Bool
leftover = |name| name.starts_with("blueprint-") or name.ends_with(".tmp") or name.ends_with(".incomplete")

## A cache directory may hold only complete packages and the sidecars Roc
## writes beside them.
check_clean! : Str, List(Str), Str => Try({}, _)
check_clean! = |package_dir, hashes, when| {
	entries = names!(package_dir)?
	check!(
		entries.all(|name| hashes.contains(name) or hashes.contains(name.drop_suffix(".deps.json"))) and !entries.any(leftover),
		"${when}, the package cache holds something unexpected: ${Str.join_with(entries, " ")}",
	)
}

## A published package is a real directory holding `main.roc`.
check_published! : Str, Str => Try({}, _)
check_published! = |package_dir, name| {
	directory = Path.utf8("${package_dir}/${name}")
	check!(Path.type!(directory)? == IsDir, "${name} is not a real directory in ${package_dir}")?
	check!(Path.type!(Path.join(directory, "main.roc"))? == IsFile, "${name} has no main.roc in ${package_dir}")
}

## When a package directory and its entry point were last changed. Publishing
## again would replace the directory, so equal stamps mean nothing was written.
stamp! : Str, Str => Try((U128, U128), _)
stamp! = |package_dir, name| {
	directory = Path.utf8("${package_dir}/${name}")
	Ok((Path.time_modified!(directory)?, Path.time_modified!(Path.join(directory, "main.roc"))?))
}

chmod! : Str, Str => Try({}, _)
chmod! = |mode, target|
	Cmd.new_str("chmod").args_str([mode, "--", target]).exec_cmd!().map_err(|_| ChmodFailed(target))

## Whether Blueprint published this package: it copies read-only files from
## the store, where Roc's own download leaves them writable.
blueprint_published! : Str, Str => Bool
blueprint_published! = |package_dir, name| {
	entry = Path.utf8("${package_dir}/${name}/main.roc")
	(Path.is_file!(entry) ?? False) and !(Path.is_writable!(entry) ?? True)
}

published_among! : Str, List(Str) => List(Str)
published_among! = |package_dir, names| {
	var $found = []
	for name in names {
		if blueprint_published!(package_dir, name) {
			$found = $found.append(name)
		}
	}
	$found
}

## Run `blueprint __build-runner` directly, as a build's derivation would,
## with nothing in its environment but `PATH`. The build command records the
## `XDG_CACHE_HOME` it was given. `extra` is appended to the specification.
## The namespaces named are not this process's, so the runner accepts them.
runner! : Context, Str, Str => Try({ outcome : Outcome, top : Str, recorded : Str }, _)
runner! = |context, directory, extra| {
	top = "${directory}/top"
	Path.create_all!(Path.utf8(top))?
	Path.create_all!(Path.utf8("${directory}/project"))?
	Path.create_all!(Path.utf8("${directory}/empty"))?
	Path.write_utf8!(Path.utf8("${directory}/project/file"), "file")?
	search = Env.var_str!(OsStr.from_str("PATH")) ?? ""
	record = "printf %s \\\"\${XDG_CACHE_HOME-unset}\\\" > recorded.txt"
	spec = Str.join_with(
		[
			"{\"project\":\"${directory}/project\"",
			"\"isolation\":{\"mnt\":\"mnt:[1]\",\"net\":\"net:[1]\"}",
			"\"argv\":[\"sh\",\"-c\",\"${record}\"]",
			"\"output\":\"recorded.txt\"",
			"\"path\":\"${search}\"",
			"\"inputs\":\"${directory}/empty\"",
			"\"artifacts\":\"${directory}/empty\"",
			"\"readlink\":\"readlink\"",
			"\"chmod\":\"chmod\"${extra}}",
		],
		",",
	)
	Path.write_utf8!(Path.utf8("${directory}/spec.json"), spec)?
	Stdout.line!("RUN  blueprint __build-runner ${directory}/spec.json")?
	ran = Cmd.new(Path.to_os_str(context.blueprint)).args_str(["__build-runner", "${directory}/spec.json"])
		.cwd(Path.utf8(top))
		.clear_envs()
		.env_str("PATH", search)
		.env_str("out", "${directory}/out")
		.run!()
	match ran {
		Ok({ status, stdout_bytes, stderr_bytes }) => {
			code = match status {
				Exited(exit_code) => exit_code
				Signaled(signal) => 128 + signal
			}
			recorded = Path.read_utf8!(Path.utf8("${directory}/out")) ?? ""
			Ok({ outcome: { code, stdout: Str.from_utf8_lossy(stdout_bytes), stderr: Str.from_utf8_lossy(stderr_bytes) }, top, recorded })
		}
		Err(_) => Script.fail!("could not run ./blueprint __build-runner")
	}
}

scenarios! : Context => Try({}, _)
scenarios! = |context| {
	cache = "${context.work}/cache"
	package_dir = "${cache}/roc/packages"
	# The cache sits beside the projects: a build refuses a project holding links.
	project = "${context.work}/project"
	cli = RocPackagesTest.hash(RocPackagesTest.basic_cli)
	http = RocPackagesTest.hash(RocPackagesTest.http)
	hashes = [cli, http]

	# 7. Refuse to run if the private cache could be the user's own.
	home = Env.var_str!(OsStr.from_str("HOME")).map_err(|_| NoHome)?
	real_cache = "${home}/.cache"
	resolved_real = match Path.canonicalize!(Path.utf8(real_cache)) {
		Ok(resolved) => Path.to_str(resolved)?
		Err(_) => real_cache
	}
	if RocPackagesTest.within(cache, real_cache) or RocPackagesTest.within(cache, resolved_real) {
		return Script.fail!("refusing to run: the test cache ${cache} is inside ${real_cache}")
	}
	real_packages = "${real_cache}/roc/packages"
	ours_before = published_among!(real_packages, hashes)
	Script.info!("INFO", "private XDG_CACHE_HOME ${cache}; ${real_cache} must stay untouched")?

	Path.create_all!(Path.utf8(project))?
	platform_path = RocPackagesTest.relative(project, "${context.root}/blueprint-platform/main.roc")
	Path.write_utf8!(Path.utf8("${project}/Blueprint.roc"), RocPackagesTest.blueprint_roc(platform_path, [RocPackagesTest.basic_cli, RocPackagesTest.http]))?
	Path.write_utf8!(Path.utf8("${project}/main.roc"), RocPackagesTest.app_roc)?
	_ = succeed!(context, cache, project, ["update"])?
	lock = Path.read_utf8!(Path.utf8("${project}/Blueprint.lock"))?
	check!(
		lock.contains("tarball+${RocPackagesTest.basic_cli}") and lock.contains("tarball+${RocPackagesTest.http}"),
		"Blueprint.lock does not pin both bundles",
	)?
	check!(names!(package_dir)?.is_empty(), "`blueprint update` wrote into the package cache")?

	# 1. With an empty cache, entering the environment publishes every listed
	# bundle. This task resolves no package, so Roc itself downloads nothing.
	version = succeed!(context, cache, project, ["run", "version"])?
	check!(version.stdout.contains(RocPackagesTest.roc_tag), "roc-stable is not ${RocPackagesTest.roc_tag}: ${version.stdout}")?
	first = names!(package_dir)?
	check!(same_names(first, hashes), "expected exactly the two packages, found: ${Str.join_with(first, " ")}")?
	check_published!(package_dir, cli)?
	check_published!(package_dir, http)?
	check!(blueprint_published!(package_dir, cli) and blueprint_published!(package_dir, http), "the published files are not read-only copies")?
	hello = succeed!(context, cache, project, ["run", "hello"])?
	check!(hello.stdout.trim() == RocPackagesTest.greeting, "the basic-cli app printed: ${hello.stdout}")?
	Script.pass!("1. empty cache: published ${Str.join_with(first, " ")} as real directories; the app printed \"${hello.stdout.trim()}\"")?

	# 2. A second run finds them and publishes nothing.
	cli_stamp = stamp!(package_dir, cli)?
	http_stamp = stamp!(package_dir, http)?
	again = succeed!(context, cache, project, ["run", "hello"])?
	check!(again.stdout.trim() == RocPackagesTest.greeting, "the second run printed: ${again.stdout}")?
	check!(stamp!(package_dir, cli)? == cli_stamp and stamp!(package_dir, http)? == http_stamp, "the second run rewrote a published package")?
	check_clean!(package_dir, hashes, "after the second run")?
	Script.pass!("2. second run: modification times unchanged (${Str.inspect(cli_stamp)}, ${Str.inspect(http_stamp)}); the app printed \"${again.stdout.trim()}\"")?

	# 3. A directory that already has a `main.roc` is left exactly as it is,
	# whatever it holds.
	placed = "# placed by the test; not the http package\n"
	Path.delete_all!(Path.utf8("${package_dir}/${http}"))?
	Path.create_dir!(Path.utf8("${package_dir}/${http}"))?
	Path.write_utf8!(Path.utf8("${package_dir}/${http}/main.roc"), placed)?
	Path.write_utf8!(Path.utf8("${package_dir}/${http}/other.txt"), "other")?
	placed_stamp = stamp!(package_dir, http)?
	_ = succeed!(context, cache, project, ["run", "version"])?
	kept = Path.read_utf8!(Path.utf8("${package_dir}/${http}/main.roc"))?
	kept_names = names!("${package_dir}/${http}")?
	check!(
		kept == placed and same_names(kept_names, ["main.roc", "other.txt"]) and stamp!(package_dir, http)? == placed_stamp
			and Path.read_utf8!(Path.utf8("${package_dir}/${http}/other.txt"))? == "other",
		"a directory that already had a main.roc was changed",
	)?
	check_clean!(package_dir, hashes, "after leaving an existing package alone")?
	Script.pass!("3. existing directory with a main.roc: bytes, entries (${Str.join_with(kept_names, " ")}) and modification times unchanged")?

	# Roc's whole cache can vanish between runs; the next run publishes again.
	Path.delete_all!(Path.utf8("${cache}/roc"))?
	restored = succeed!(context, cache, project, ["run", "hello"])?
	check!(restored.stdout.trim() == RocPackagesTest.greeting, "after losing the cache the app printed: ${restored.stdout}")?
	check!(blueprint_published!(package_dir, cli) and blueprint_published!(package_dir, http), "a lost cache was not published again")?
	Script.pass!("   deleted cache: both packages published again; the app printed \"${restored.stdout.trim()}\"")?

	# 4. A directory without a `main.roc` is incomplete: it is replaced.
	Path.delete_all!(Path.utf8("${package_dir}/${http}"))?
	Path.create_dir!(Path.utf8("${package_dir}/${http}"))?
	Path.write_utf8!(Path.utf8("${package_dir}/${http}/partial.roc"), "partial")?
	_ = succeed!(context, cache, project, ["run", "version"])?
	check_published!(package_dir, http)?
	replaced_names = names!("${package_dir}/${http}")?
	check!(blueprint_published!(package_dir, http) and !replaced_names.contains("partial.roc"), "an incomplete directory was not replaced: ${Str.join_with(replaced_names, " ")}")?
	check_clean!(package_dir, hashes, "after replacing an incomplete directory")?
	repaired = succeed!(context, cache, project, ["run", "hello"])?
	check!(repaired.stdout.trim() == RocPackagesTest.greeting, "after the replacement the app printed: ${repaired.stdout}")?
	Script.pass!("4. directory without a main.roc: replaced by the package, nothing left over; the app printed \"${repaired.stdout.trim()}\"")?

	# 5. A failure leaves neither a staging directory nor a partial package.
	# An incomplete directory that cannot be moved fails after the copy was
	# staged, so this exercises the cleanup.
	Path.delete_all!(Path.utf8("${package_dir}/${http}"))?
	Path.create_dir!(Path.utf8("${package_dir}/${http}"))?
	Path.write_utf8!(Path.utf8("${package_dir}/${http}/partial.roc"), "partial")?
	chmod!("a-w", "${package_dir}/${http}")?
	stuck = blueprint!(context, cache, project, ["run", "version"])?
	stuck_names = names!("${package_dir}/${http}")?
	chmod!("u+w", "${package_dir}/${http}")?
	check!(stuck.code != 0 and stuck.stderr.contains("has no main.roc and cannot be replaced"), "an unreplaceable directory did not fail clearly (code ${stuck.code.to_str()}):\n${stuck.stderr}")?
	check!(same_names(stuck_names, ["partial.roc"]), "the failed publication changed the directory: ${Str.join_with(stuck_names, " ")}")?
	check_clean!(package_dir, hashes, "after a failed replacement")?
	stuck_line = stuck.stderr.split_on("\n").keep_if(|line| line.starts_with("blueprint: ")).first() ?? ""
	Script.pass!("5. read-only incomplete directory: exit ${stuck.code.to_str()}, nothing staged left; ${stuck_line.replace_each(context.work, "<work>")}")?

	# An unwritable cache directory fails before anything is staged.
	Path.delete_all!(Path.utf8("${package_dir}/${http}"))?
	before_refusal = names!(package_dir)?
	chmod!("a-w", package_dir)?
	refused = blueprint!(context, cache, project, ["run", "version"])?
	chmod!("u+w", package_dir)?
	after_refusal = names!(package_dir)?
	check!(refused.code != 0 and refused.stderr.contains("cannot stage Roc package ${http}"), "an unwritable cache did not fail clearly (code ${refused.code.to_str()}):\n${refused.stderr}")?
	check!(same_names(after_refusal, before_refusal) and !after_refusal.contains(http), "the failed publication wrote into the cache: ${Str.join_with(after_refusal, " ")}")?
	refused_line = refused.stderr.split_on("\n").keep_if(|line| line.starts_with("blueprint: ")).first() ?? ""
	Script.pass!("   unwritable cache directory: exit ${refused.code.to_str()}, cache unchanged; ${refused_line.replace_each(context.work, "<work>")}")?
	recovered = succeed!(context, cache, project, ["run", "hello"])?
	check!(recovered.stdout.trim() == RocPackagesTest.greeting, "after the failures the app printed: ${recovered.stdout}")?
	check_clean!(package_dir, hashes, "after recovering")?

	# An environment without Roc packages writes nothing, in a cache of its own.
	plain_cache = "${context.work}/plain-cache"
	plain = succeed!(context, plain_cache, project, ["run", "plain"])?
	plain_names = names!("${plain_cache}/roc/packages")?
	check!(plain.stdout.trim() == "Hello, world!" and plain_names.is_empty(), "an environment without Roc packages published: ${Str.join_with(plain_names, " ")}")?
	Script.pass!("   environment without Roc packages: no package cache created")?

	# The build runner sets XDG_CACHE_HOME for a build with Roc packages, to a
	# cache inside the build directory holding exactly those, and leaves it
	# unset for any other build.
	bare = runner!(context, "${context.work}/runner-without", "")?
	check!(
		bare.outcome.code == 0 and bare.recorded == "unset" and !(Path.exists!(Path.utf8("${bare.top}/blueprint-cache")) ?? True),
		"a build without Roc packages was given a cache (code ${bare.outcome.code.to_str()}, XDG_CACHE_HOME ${bare.recorded}):\n${bare.outcome.stderr}",
	)?
	bundle = "{\"name\":\"${cli}\",\"path\":\"${package_dir}/${cli}\"}"
	given = runner!(context, "${context.work}/runner-with", ",\"roc_packages\":[${bundle}],\"ln\":\"ln\"")?
	linked = "${given.top}/blueprint-cache/roc/packages"
	check!(
		given.outcome.code == 0 and given.recorded == "${given.top}/blueprint-cache" and same_names(names!(linked)?, [cli])
			and Path.type!(Path.utf8("${linked}/${cli}"))? == IsSymLink
				and (Path.is_file!(Path.utf8("${linked}/${cli}/main.roc")) ?? False),
		"a build with Roc packages did not get its own cache (code ${given.outcome.code.to_str()}, XDG_CACHE_HOME ${given.recorded}):\n${given.outcome.stderr}",
	)?
	escaping = runner!(context, "${context.work}/runner-escaping", ",\"roc_packages\":[{\"name\":\"../escape\",\"path\":\"${package_dir}/${cli}\"}],\"ln\":\"ln\"")?
	check!(
		escaping.outcome.code != 0 and escaping.outcome.stderr.contains("invalid Roc package name") and escaping.recorded == "",
		"the runner accepted a Roc package name that is not a plain name:\n${escaping.outcome.stderr}",
	)?
	Script.pass!("   build runner: XDG_CACHE_HOME ${bare.recorded} without Roc packages; <build>/blueprint-cache with them, holding a link to ${cli}")?

	# 6. A sandboxed build has no network, yet the app resolves both bundles
	# from the build's own cache and writes the artifact.
	host_before = (stamp!(package_dir, cli)?, stamp!(package_dir, http)?)
	built = succeed!(context, cache, project, ["build", "offline"])?
	artifact = Path.read_utf8!(Path.utf8(built.stdout.trim()))?
	check!(artifact == "${RocPackagesTest.greeting}\n", "the build produced: ${artifact}")?
	check!((stamp!(package_dir, cli)?, stamp!(package_dir, http)?) == host_before, "a build wrote into the host package cache")?
	Script.pass!("6. sandboxed build: ${built.stdout.trim()} holds \"${artifact.trim()}\"")?

	# The same build without the http bundle cannot resolve it: the list is
	# what makes the build work.
	partial = "${context.work}/without-http"
	Path.create_all!(Path.utf8(partial))?
	Path.write_utf8!(
		Path.utf8("${partial}/Blueprint.roc"),
		RocPackagesTest.blueprint_roc(RocPackagesTest.relative(partial, "${context.root}/blueprint-platform/main.roc"), [RocPackagesTest.basic_cli]),
	)?
	Path.write_utf8!(Path.utf8("${partial}/main.roc"), RocPackagesTest.app_roc)?
	_ = succeed!(context, cache, partial, ["update"])?
	unresolved = blueprint!(context, cache, partial, ["build", "offline"])?
	check!(
		unresolved.code != 0 and unresolved.stderr.contains("package download failed"),
		"a build missing the http bundle did not fail to resolve it (code ${unresolved.code.to_str()}):\n${unresolved.stderr}",
	)?
	Script.pass!("   the same build without the http bundle: exit ${unresolved.code.to_str()}, \"package download failed\"")?

	# 7. Nothing was published into the user's own cache.
	ours_after = published_among!(real_packages, hashes)
	strays = names!(real_packages)?.keep_if(|name| name.starts_with("blueprint-"))
	check!(
		same_names(ours_after, ours_before) and strays.is_empty(),
		"the test wrote into ${real_packages}: ${Str.join_with(ours_after.concat(strays), " ")}",
	)?
	Script.pass!("7. ${real_packages}: nothing published or staged there")
}

expect RocPackagesTest.hash(RocPackagesTest.basic_cli) == "AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH"
expect RocPackagesTest.relative("/tmp/work/project", "/home/me/repo/blueprint-platform/main.roc") == "../../../home/me/repo/blueprint-platform/main.roc"
expect RocPackagesTest.relative("/repo/tests/project", "/repo/blueprint-platform/main.roc") == "../../blueprint-platform/main.roc"
expect RocPackagesTest.relative("/repo", "/repo/blueprint-platform/main.roc") == "blueprint-platform/main.roc"

# The guard against the user's own cache is lexical containment of whole names.
expect RocPackagesTest.within("/home/me/.cache/tmp/work/cache", "/home/me/.cache")
expect RocPackagesTest.within("/home/me/.cache", "/home/me/.cache")
expect !RocPackagesTest.within("/home/me/.cache-other/cache", "/home/me/.cache")
expect !RocPackagesTest.within("/tmp/work/cache", "/home/me/.cache")

expect leftover("blueprint-abc.x1y2z3.tmp") and leftover("abc.0123456789abcdef.tmp") and !leftover("abc") and !leftover("abc.deps.json")
expect same_names(["a", "b"], ["b", "a"]) and !same_names(["a"], ["a", "b"])
expect RocPackagesTest.blueprint_roc("../p/main.roc", ["https://e.test/a.tar.zst", "https://e.test/b.tar.zst"]).contains("RocPackages([\"https://e.test/a.tar.zst\", \"https://e.test/b.tar.zst\"])")
