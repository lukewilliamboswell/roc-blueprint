import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import ConfigTest
import LinkInputs
import Process
import Script
import Serve

## Bundle roc-blueprint-core and the roc-blueprint platform into `dist/`, and
## record each archive in `dist/bundles.txt` for the release workflow.
##
## One release holds both. Roc identifies a package by its URL minus the
## version and hash, so two archives named only by their hashes under one tag
## would be one package with two hashes. The core archive is therefore
## renamed with a prefix, which is part of that identity; the platform's keeps
## the name `roc bundle` gave it.
##
## `roc bundle` only packs files below the entry point's directory, so the
## platform's development dependency `core: "../blueprint-core/main.roc"`
## cannot be bundled as it is; a staged copy of the platform gets the URL the
## core bundle will have in the release of this version.
##
## Both bundles are smoke-tested before that release exists. This process
## serves them from localhost at the paths the release will give them, while
## the compiler, told to load the core bundle from here, checks valid and
## invalid configurations and runs the all-settings example. Its package
## cache is its own, so both bundles are really downloaded.
Bundle := [].{
	core_dir = "blueprint-core"
	platform_dir = "blueprint-platform"

	## What a staged platform's `core` dependency replaces.
	development_core = "\"../blueprint-core/main.roc\""

	## The version bundled when none is being released. Roc rejects 0.0.0.
	dry_run_version = "0.0.1-dry-run"

	## The repository whose releases hold the bundles, unless
	## `GITHUB_REPOSITORY` names another.
	default_repository = "lukewilliamboswell/roc-blueprint"

	## What marks the core archive among a release's assets.
	core_prefix = "roc-blueprint-core-"
	sbom_prefix = "roc-blueprint-sbom-"

	## Where a release serves one of its assets, below the host.
	release_path : Str, Str, Str -> Str
	release_path = |repository, version, asset| "${repository}/releases/download/${version}/${asset}"

	release_url : Str, Str, Str -> Str
	release_url = |repository, version, asset| "https://github.com/${release_path(repository, version, asset)}"

	## The compiler arguments that load `declared` from `served` instead.
	replacing : Str, Str -> List(Str)
	replacing = |declared, served| ["--replace-dep", declared, served]

	## The archive `dist/bundles.txt` lists for a package.
	archive : Str, Str -> Try(Str, [NotBundled(Str)])
	archive = |list, name|
		match list.split_on("\n").find_first(|line| line.starts_with("${name} ")) {
			Ok(line) => Ok(line.drop_prefix("${name} "))
			Err(_) => Err(NotBundled(name))
		}

	## The repository this run's bundles are released from.
	repository! : () => Str
	repository! = || {
		named = Env.var_str!(OsStr.from_str("GITHUB_REPOSITORY")) ?? ""
		if named.is_empty() default_repository else named
	}

	## The modules of a package directory: `main.roc`, then the rest by name.
	modules : List(Str) -> List(Str)
	modules = |names| {
		roc_files = names.keep_if(|name| name.ends_with(".roc") and name != "main.roc")
		["main.roc"].concat(Process.sorted(roc_files))
	}

	## The files each target of a platform links, as paths below the platform
	## directory, read from the `targets:` section of its `main.roc`. `app`
	## stands for the application and is not a file.
	target_inputs : Str -> Try(List(Str), [NoTargets])
	target_inputs = |main_roc| {
		section = match main_roc.split_on("\n\ttargets: {\n") {
			[_, after] => after.split_on("\n\t}").first() ?? ""
			_ => return Err(NoTargets)
		}
		lines = section.split_on("\n").map(|line| line.trim())
		directory = match lines.find_first(|line| line.starts_with("inputs_dir: \"")) {
			Ok(line) => line.drop_prefix("inputs_dir: \"").drop_suffix(",").drop_suffix("\"")
			Err(_) => return Err(NoTargets)
		}
		files = lines.fold(
			[],
			|found, line|
				match line.split_on(": { inputs: [") {
					[name, inputs] => found.concat(quoted(inputs).map(|file| "${directory}${name}/${file}"))
					_ => found
				},
		)
		if files.is_empty() Err(NoTargets) else Ok(files)
	}

	## The archive name `roc bundle` reports.
	created : Str -> Try(Str, [NotCreated])
	created = |output|
		match output.split_on("\n").find_first(|line| line.starts_with("Created: ")) {
			Ok(line) => Ok(line.split_on("/").last() ?? "")
			Err(_) => Err(NotCreated)
		}

	## The module files `flake.nix` copies from the core package into the
	## CLI's source, by name.
	flake_core_modules : Str -> List(Str)
	flake_core_modules = |flake|
		flake.split_on("\n").map(|line| line.trim()).keep_if(|line| line.starts_with("./${core_dir}/") and line.ends_with(".roc")).map(|line| line.drop_prefix("./${core_dir}/"))

	## Bundle the core package, then the platform against the URL that bundle
	## will have in the release of `version`, and smoke-test the pair.
	run! : Str, Str => Try({}, _)
	run! = |root, version| {
		paths = prepare!(root)?
		server = Serve.open!()?
		result = staged_platform!(root, paths, server, { repository: repository!(), version })
		_ = server.shut!()
		_ = Path.delete_all!(Path.utf8(paths.stage))
		result?
		written!(paths)
	}

	## Focused release-bundle consumer test, without building platform hosts.
	check_snapshot_bundle! : Str, Str => Try({}, _)
	check_snapshot_bundle! = |root, version| {
		paths = prepare!(root)?
		idle = Serve.open!()?
		result! = || {
			core = bundle_core!(root, paths)?
			route = release_path(repository!(), version, core)
			server = idle.with_route(route, Path.read_bytes!(Path.utf8("${paths.dist}/${core}"))?)
			snapshot_consumer!(root, paths, server, release_url(repository!(), version, core), route, core)
		}
		checked = result!()
		_ = idle.shut!()
		_ = Path.delete_all!(Path.utf8(paths.stage))
		checked
	}

}

Paths : { dist : Str, stage : Str, list : Str }

## The release the bundles are made for.
Release : { repository : Str, version : Str }

## The bundles as this process serves them: the platform's URL here, both
## archive names, and the compiler arguments that load the core bundle from
## here too.
Served : { platform_url : Str, platform_bundle : Str, core_bundle : Str, arguments : List(Str) }

## The double-quoted strings in a list literal's text.
quoted : Str -> List(Str)
quoted = |text| {
	parts = text.split_on("\"")
	var $strings = []
	var $index = 1
	while $index < parts.len() {
		$strings = $strings.append(parts.get($index) ?? "")
		$index = $index + 2
	}
	$strings
}

## `dist/` and the staging directory share a filesystem with the working
## directory: the bundler renames its temporary file into the output directory.
prepare! : Str => Try(Paths, _)
prepare! = |root| {
	paths = { dist: "${root}/dist", stage: "${root}/.bundle-stage", list: "${root}/dist/bundles.txt" }
	if Path.exists!(Path.utf8(paths.stage))? {
		Path.delete_all!(Path.utf8(paths.stage))?
	}
	Path.create_all!(Path.utf8(paths.dist))?
	if Path.exists!(Path.utf8(paths.list))? {
		Path.delete!(Path.utf8(paths.list))?
	}
	Ok(paths)
}

written! : Paths => Try({}, _)
written! = |paths| {
	Script.info!("==>", "Wrote ${paths.list}")?
	Stdout.write!(Path.read_utf8!(Path.utf8(paths.list))?)
}

record! : Paths, Str, Str => Try({}, _)
record! = |paths, bundled, archive| {
	earlier = if Path.exists!(Path.utf8(paths.list))? Path.read_utf8!(Path.utf8(paths.list))? else ""
	Path.write_utf8!(Path.utf8(paths.list), "${earlier}${bundled} ${archive}\n")
}

## The names of the regular files directly inside a directory.
file_names! : Str => Try(List(Str), _)
file_names! = |directory| {
	var $names = []
	for entry in Path.list!(Path.utf8(directory))? {
		if Path.is_file!(entry)? {
			$names = $names.append(Path.to_str(entry)?.split_on("/").last() ?? "")
		}
	}
	Ok(Process.sorted($names))
}

## Run `roc bundle` on files of `directory`, with these environment
## variables added, and return the archive's name.
bundle! : Str, List(Str), Paths, List((Str, Str)) => Try(Str, _)
bundle! = |directory, files, paths, environment| {
	job = Process.with_env(Process.command(Process.roc!(), ["bundle"].concat(files).concat(["--output-dir", paths.dist]), directory), environment)
	outcome = Process.capture!(job)?
	if outcome.code != 0 {
		return Script.fail!("${outcome.stdout}${outcome.stderr}\nroc bundle exited with code ${outcome.code.to_str()} in ${directory}")
	}
	match Bundle.created(outcome.stdout) {
		Ok(name) => Ok(name)
		Err(NotCreated) => Script.fail!("${outcome.stdout}\nroc bundle did not name the archive it created")
	}
}

bundle_core! : Str, Paths => Try(Str, _)
bundle_core! = |root, paths| {
	Script.info!("==>", "Bundling roc-blueprint-core")?
	directory = "${root}/${Bundle.core_dir}"
	hashed = bundle!(directory, Bundle.modules(file_names!(directory)?).concat(["lock-snapshot-v2.schema.json"]), paths, [])?
	name = "${Bundle.core_prefix}${hashed}"
	Path.rename!(Path.utf8("${paths.dist}/${hashed}"), Path.utf8("${paths.dist}/${name}"))?
	Script.info!("   ", name)?
	record!(paths, "roc-blueprint-core", name)?
	Ok(name)
}

copy! : Str, Str, List(Str) => Try({}, _)
copy! = |from, to, files| {
	for file in files {
		target = "${to}/${file}"
		Path.create_all!(Path.utf8(Str.join_with(target.split_on("/").drop_last(1), "/")))?
		Path.copy!(Path.utf8("${from}/${file}"), Path.utf8(target))?
	}
	Ok({})
}

## A package cache of its own holding the core bundle and nothing else, under
## the hash Roc looks a package up by. The caller's cache is neither read nor
## written.
seeded_cache! : Paths, Str => Try(Str, _)
seeded_cache! = |paths, core| {
	# `roc unbundle` checks an archive against the hash that is its whole name.
	hashed = core.drop_prefix(Bundle.core_prefix)
	unpacked = "${paths.stage}/core"
	cache = "${paths.stage}/bundling-cache"
	package_cache = "${cache}/roc/packages"
	Path.create_all!(Path.utf8(unpacked))?
	Path.create_all!(Path.utf8(package_cache))?
	Path.copy!(Path.utf8("${paths.dist}/${core}"), Path.utf8("${unpacked}/${hashed}"))?
	unbundled = Process.capture!(Process.command(Process.roc!(), ["unbundle", hashed], unpacked))?
	Process.check!(unbundled.code == 0, "${unbundled.stdout}${unbundled.stderr}\nroc unbundle of the core bundle exited with code ${unbundled.code.to_str()}")?
	Path.rename!(Path.utf8("${unpacked}/${hashed.drop_suffix(".tar.zst")}"), Path.utf8("${package_cache}/${hashed.drop_suffix(".tar.zst")}"))?
	Ok(cache)
}

staged_platform! : Str, Paths, Serve, Release => Try({}, _)
staged_platform! = |root, paths, idle, release| {
	core = bundle_core!(root, paths)?
	core_url = Bundle.release_url(release.repository, release.version, core)
	core_route = Bundle.release_path(release.repository, release.version, core)
	server = idle.with_route(core_route, Path.read_bytes!(Path.utf8("${paths.dist}/${core}"))?)
	_ = snapshot_consumer!(root, paths, server, core_url, core_route, core)?
	core_cache = seeded_cache!(paths, core)?
	_ = bundle_sbom!(root, paths, server, release, core, core_cache)?

	Script.info!("==>", "Building libhost.a")?
	Process.passthrough!(Process.command("zig", ["build"], "${root}/${Bundle.platform_dir}"))?

	Script.info!("==>", "Checking the linker inputs against link-inputs.lock.json")?
	LinkInputs.check!(Path.utf8(root))?

	Script.info!("==>", "Bundling roc-blueprint (core: ${core_url})")?
	source = "${root}/${Bundle.platform_dir}"
	staged = "${paths.stage}/platform"
	roc_files = Bundle.modules(file_names!(source)?)
	linked = match Bundle.target_inputs(Path.read_utf8!(Path.utf8("${source}/main.roc"))?) {
		Ok(files) => files
		Err(NoTargets) => return Script.fail!("${Bundle.platform_dir}/main.roc names no target inputs")
	}
	# The check above proved this directory holds exactly the locked files.
	licences = file_names!("${source}/linker-inputs/licenses")?.map(|name| "linker-inputs/licenses/${name}")
	files = roc_files.concat(linked).concat(["linker-inputs/dependency.json"]).concat(licences)
	copy!(source, staged, files)?
	entry = Path.utf8("${staged}/main.roc")
	Path.replace_utf8!(entry, Bundle.development_core, "\"${core_url}\"")?
	if !Path.read_utf8!(entry)?.contains("core: \"${core_url}\"") {
		return Script.fail!("failed to rewrite the core dependency")
	}
	# `roc bundle` resolves the platform's dependencies, and the core URL does
	# not exist yet. The compiler looks in its package cache before it
	# downloads, so it gets a cache that already holds the core bundle.
	platform_bundle = bundle!(staged, files, paths, [("XDG_CACHE_HOME", core_cache)])?
	Script.info!("   ", platform_bundle)?
	record!(paths, "roc-blueprint", platform_bundle)?

	route = Bundle.release_path(release.repository, release.version, platform_bundle)
	serving = server.with_route(route, Path.read_bytes!(Path.utf8("${paths.dist}/${platform_bundle}"))?)
	smoke!(
		root,
		paths,
		serving,
		{ platform_url: serving.url(route), platform_bundle, core_bundle: core, arguments: Bundle.replacing(core_url, serving.url(core_route)) },
	)
}

## Check and run configurations against the served bundles. The compiler gets
## an empty package cache, so it must download both from this process.
smoke! : Str, Paths, Serve, Served => Try({}, _)
smoke! = |root, paths, server, served| {
	platform_url = served.platform_url
	roc = Process.roc!()
	cache = "${paths.stage}/cache"
	environment = [("XDG_CACHE_HOME", cache)]
	example_dir = "${paths.stage}/app"
	config = "${paths.stage}/config"
	Path.create_all!(Path.utf8(example_dir))?
	Path.create_all!(Path.utf8(config))?

	Script.info!("==>", "Compile-time validation against the platform bundle at ${platform_url}")?
	# The first compiler downloads the bundle; the rest then run together.
	serve_batches! = |jobs| {
		first = server.drive!(jobs.take_first(1))?
		Ok(first.concat(server.drive!(jobs.drop_first(1))?))
	}
	ConfigTest.run!({ roc, platform_ref: platform_url, work: config, subset: Smoke, environment, arguments: served.arguments }, serve_batches!)?
	# The cache names a package by its hash alone.
	for bundle in [served.platform_bundle, served.core_bundle.drop_prefix(Bundle.core_prefix)] {
		downloaded = "${cache}/roc/packages/${bundle.drop_suffix(".tar.zst")}"
		if !(Path.is_dir!(Path.utf8(downloaded)) ?? False) {
			return Script.fail!("the compiler did not download ${bundle} into ${downloaded}")
		}
	}

	Script.info!("==>", "Smoke test: running examples/all-settings/Blueprint.roc against the platform bundle")?
	example = Path.read_utf8!(Path.utf8("${root}/examples/all-settings/Blueprint.roc"))?
	local_platform = "platform \"../../blueprint-platform/main.roc\""
	if !example.contains(local_platform) {
		return Script.fail!("examples/all-settings/Blueprint.roc does not name the local platform")
	}
	Path.write_utf8!(Path.utf8("${example_dir}/Blueprint.roc"), example.replace_each(local_platform, "platform \"${platform_url}\""))?
	compiler = |args| Process.with_env(Process.command(roc, args.concat(served.arguments).concat(["Blueprint.roc"]), example_dir), environment)
	match server.drive!([compiler(["check"])])? {
		[checked] => Process.check!(checked.code == 0, "${checked.stdout}${checked.stderr}\nroc check of the all-settings example exited with code ${checked.code.to_str()}")?
		_ => return Script.fail!("roc check did not report a result")
	}
	match server.drive!([compiler([])])? {
		[ran] => Process.check!(ran.code == 0 and ran.stdout.contains("(format ("), "${ran.stdout}${ran.stderr}\nthe all-settings example did not print a Spec (exit ${ran.code.to_str()})")?
		_ => return Script.fail!("the all-settings example did not report a result")
	}
	Script.info!("   ", "ok")
}

platform_sample =
	\\platform ""
	\\	provides { "roc_main": main_for_host! }
	\\	targets: {
	\\		inputs_dir: "targets/",
	\\		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
	\\		arm64mac: { inputs: ["libhost.a", app] },
	\\	}
	\\
	\\import Config

expect Bundle.target_inputs(platform_sample) == Ok(["targets/x64musl/crt1.o", "targets/x64musl/libhost.a", "targets/x64musl/libc.a", "targets/arm64mac/libhost.a"])
expect Bundle.target_inputs("platform \"\"\n\tprovides {}\n") == Err(NoTargets)
expect Bundle.target_inputs("platform \"\"\n\ttargets: {\n\t\tinputs_dir: \"targets/\",\n\t}\n") == Err(NoTargets)

expect quoted("\"crt1.o\", \"libhost.a\", app, \"libc.a\"] },") == ["crt1.o", "libhost.a", "libc.a"]
expect quoted("app] },") == []

# `main.roc` leads, other files are not modules, and the order is by name.
expect Bundle.modules(["Spec.roc", "main.roc", "fuzz", "Lock.roc", "notes.md"]) == ["main.roc", "Lock.roc", "Spec.roc"]

expect Bundle.created("Created: /repo/dist/7ghFBPv8.tar.zst\nCompressed size: 28042 bytes\n") == Ok("7ghFBPv8.tar.zst")
expect Bundle.created("error: something\n") == Err(NotCreated)

expect Bundle.flake_core_modules("    ./blueprint-cli\n    ./blueprint-core/main.roc\n    ./blueprint-core/Spec.roc\n  ];\n") == ["main.roc", "Spec.roc"]

expect Bundle.release_url("owner/repo", "0.5.0", "abc.tar.zst") == "https://github.com/owner/repo/releases/download/0.5.0/abc.tar.zst"
expect Bundle.release_path("owner/repo", "0.5.0-rc1", "roc-blueprint-core-abc.tar.zst") == "owner/repo/releases/download/0.5.0-rc1/roc-blueprint-core-abc.tar.zst"
expect Bundle.replacing("https://a", "http://127.0.0.1:1/a") == ["--replace-dep", "https://a", "http://127.0.0.1:1/a"]

expect Bundle.archive("roc-blueprint-core roc-blueprint-core-AAA.tar.zst\nroc-blueprint BBB.tar.zst\n", "roc-blueprint") == Ok("BBB.tar.zst")
expect Bundle.archive("roc-blueprint-core roc-blueprint-core-AAA.tar.zst\n", "roc-blueprint-core") == Ok("roc-blueprint-core-AAA.tar.zst")
expect Bundle.archive("roc-blueprint-core AAA.tar.zst\n", "roc-blueprint") == Err(NotBundled("roc-blueprint"))

# Publish exactly the repository wrapper and I/O module, with its core URL
# and compiler pin staged for the selected release. No second implementation.
bundle_sbom! : Str, Paths, Serve, Release, Str, Str => Try(Str, _)
bundle_sbom! = |root, paths, core_server, release, core, cache| {
	Script.info!("==>", "Bundling the standalone SBOM app")?
	staged = "${paths.stage}/sbom-tool"
	copy!("${root}/scripts", staged, ["sbom.roc", "src/SbomFiles.roc"])?
	Path.rename!(Path.utf8("${staged}/sbom.roc"), Path.utf8("${staged}/main.roc"))?
	core_url = Bundle.release_url(release.repository, release.version, core)
	entry_path = Path.utf8("${staged}/main.roc")
	entry = Path.read_utf8!(entry_path)?
	old_tag = entry.split_on("roc: \"").get(1).map_ok(|tail| tail.split_on("\"").first() ?? "") ?? ""
	product_tag = Path.read_utf8!(Path.utf8("${root}/blueprint-cli/compiler-version"))?.trim()
	Process.check!(!old_tag.is_empty() and !product_tag.is_empty(), "SBOM app needs explicit development/release compiler pins")?
	staged_entry = entry.replace_each("\"../blueprint-core/main.roc\"", "\"${core_url}\"").replace_each("roc: \"${old_tag}\"", "roc: \"${product_tag}\"")
	Path.write_utf8!(entry_path, staged_entry)?
	hashed = bundle!(staged, ["main.roc", "src/SbomFiles.roc"], paths, [("XDG_CACHE_HOME", cache)])?
	name = "${Bundle.sbom_prefix}${hashed}"
	Path.rename!(Path.utf8("${paths.dist}/${hashed}"), Path.utf8("${paths.dist}/${name}"))?
	record!(paths, "roc-blueprint-sbom", name)?

	# Compile/run the actual app archive through localhost, not a checkout.
	# It receives evaluated inputs in a directory with a poisoned Blueprint.roc.
	route = Bundle.release_path(release.repository, release.version, name)
	server = core_server.with_route(route, Path.read_bytes!(Path.utf8("${paths.dist}/${name}"))?)
	workspace = "${paths.stage}/sbom-workspace"
	copy!("${root}/tests/sbom/fixtures/input", workspace, ["Spec", "Lock", "composition.json", "subject.json", "context.json", "sample-artifact"])?
	Path.write_utf8!(Path.utf8("${workspace}/Blueprint.roc"), "INVALID PROJECT MUST NOT BE EVALUATED\n")?
	base = ["run"].concat(Bundle.replacing(core_url, server.url(Bundle.release_path(release.repository, release.version, core)))).concat([server.url(route), "--"])
	roc = Process.roc!()
	invoke = |args| Process.with_env(Process.command(roc, base.concat(args), workspace), [("XDG_CACHE_HOME", cache)])
	for args in [["inspect", "Spec", "Lock", "composition.json", "x86_64-linux", "inventory.json"], ["bind", "inventory.json", "subject.json", "context.json", "sample-artifact"], ["bind", "inventory.json", "subject.json", "context.json", "sample-artifact", "sample-artifact.spdx-2.3.json", "--spdx-2.3"]] {
		outcomes = server.drive!([invoke(args)])?
		match outcomes {
			[outcome] => Process.check!(outcome.code == 0, "SBOM app bundle smoke failed: ${outcome.stdout}${outcome.stderr}")?
			_ => return Script.fail!("SBOM app bundle did not report an outcome")
		}
	}
	# The released app checks its own sidecars, with nothing from this checkout.
	checked = server.drive!([invoke(["check", "--inventory", "inventory.json", "--artifacts", ".", "sample-artifact.spdx.json", "sample-artifact.spdx-2.3.json", "sample-artifact.cdx.json"])])?
	match checked {
		[outcome] => Process.check!(outcome.code == 0, "SBOM app check failed: ${outcome.stdout}${outcome.stderr}")?
		_ => return Script.fail!("SBOM app check did not report an outcome")
	}
	Script.pass!("released SBOM app inspected/bound inputs without project evaluation; SPDX 3.0.1, SPDX 2.3 and CycloneDX sidecars and exact artifact verified")?
	Ok(name)
}

## Both compilers fetch the exact candidate core bundle in isolated empty caches.
snapshot_consumer! = |root, paths, server, core_url, route, core| {
	workspace = "${paths.stage}/snapshot-consumer"
	copy!("${root}/fixtures/lock-snapshot", workspace, ["pure.roc", "Checks.roc"])?
	Path.rename!(Path.utf8("${workspace}/pure.roc"), Path.utf8("${workspace}/main.roc"))?
	Path.replace_utf8!(Path.utf8("${workspace}/main.roc"), "\"../../blueprint-core/main.roc\"", "\"${core_url}\"")?
	var $index = 0.U64
	for compiler in [Process.roc!(), "roc-stable"] {
		$index = $index + 1
		cache = "${paths.stage}/snapshot-cache-${$index.to_str()}"
		job = Process.with_env(Process.command(compiler, ["test"].concat(Bundle.replacing(core_url, server.url(route))).concat(["main.roc"]), workspace), [("XDG_CACHE_HOME", cache)])
		match server.drive!([job])? {
			[outcome] => Process.check!(outcome.code == 0, "official core bundle consumer failed with ${compiler}: ${outcome.stdout}${outcome.stderr}")?
			_ => return Script.fail!("core bundle consumer returned no result")
		}
		resource = "${cache}/roc/packages/${core.drop_prefix(Bundle.core_prefix).drop_suffix(".tar.zst")}/lock-snapshot-v2.schema.json"
		Process.check!(Path.read_bytes!(Path.utf8(resource))? == Path.read_bytes!(Path.utf8("${root}/blueprint-core/lock-snapshot-v2.schema.json"))?, "core bundle schema differs or was not downloaded")?
	}
	Script.pass!("official core bundle consumed purely by product and script compilers from independent empty caches; packaged schema verified")
}
