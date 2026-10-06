import cli.Path
import cli.Stdout
import ConfigTest
import LinkInputs
import Process
import Script
import Serve

## Bundle roc-blueprint-core or the roc-blueprint platform into `dist/`, and
## record each archive in `dist/bundles.txt` for the release workflows.
##
## The two have independent releases (tags `core-X.Y.Z` and `X.Y.Z`). They
## must live under different tags: Roc identifies a package by its URL minus
## the version and hash, so two bundles under one tag look like one package
## with two hashes.
##
## `roc bundle` only packs files below the entry point's directory, so the
## platform's development dependency `core: "../blueprint-core/main.roc"`
## cannot be bundled as it is; a staged copy of the platform gets the core
## bundle's URL instead.
##
## Every platform bundle is smoke-tested. This process serves it from
## localhost under a release-like versioned path while the compiler checks
## valid and invalid configurations and runs the all-settings example against
## it, with a package cache of its own so the bundle is really downloaded.
Bundle := [].{
	core_dir = "blueprint-core"
	platform_dir = "blueprint-platform"

	## What a staged platform's `core` dependency replaces.
	development_core = "\"../blueprint-core/main.roc\""

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

	## Bundle the core package alone.
	core! : Str => Try({}, _)
	core! = |root| {
		paths = prepare!(root)?
		_ = bundle_core!(root, paths)?
		written!(paths)
	}

	## Bundle the platform against a published core bundle at `core_url`, or,
	## when that is empty, against the local core, bundled and served here.
	platform! : Str, Str => Try({}, _)
	platform! = |root, core_url| {
		paths = prepare!(root)?
		server = Serve.open!()?
		result = staged_platform!(root, paths, server, core_url)
		_ = server.shut!()
		_ = Path.delete_all!(Path.utf8(paths.stage))
		result?
		written!(paths)
	}
}

Paths : { dist : Str, stage : Str, list : Str }

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

## Run `roc bundle` on files of `directory` and return the archive's name.
## `drive!` runs the compiler; a caller serving a bundle serves it meanwhile.
bundle! : Str, List(Str), Paths, (List(Process.Job) => Try(List(Process.Outcome), _)) => Try(Str, _)
bundle! = |directory, files, paths, drive!| {
	job = Process.command(Process.roc!(), ["bundle"].concat(files).concat(["--output-dir", paths.dist]), directory)
	outcome = match drive!([job])? {
		[one] => one
		_ => return Script.fail!("roc bundle did not report a result")
	}
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
	name = bundle!(directory, Bundle.modules(file_names!(directory)?), paths, Process.together!)?
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

staged_platform! : Str, Paths, Serve, Str => Try({}, _)
staged_platform! = |root, paths, idle, given_core_url| {
	(server, core_url) = if given_core_url.is_empty() {
		core = bundle_core!(root, paths)?
		route = "0.0.1-smoke-core/${core}"
		(idle.with_route(route, Path.read_bytes!(Path.utf8("${paths.dist}/${core}"))?), idle.url(route))
	} else {
		(idle, given_core_url)
	}

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
	platform_bundle = bundle!(staged, files, paths, |jobs| server.drive!(jobs))?
	Script.info!("   ", platform_bundle)?
	record!(paths, "roc-blueprint", platform_bundle)?

	route = "0.0.1-smoke/${platform_bundle}"
	serving = server.with_route(route, Path.read_bytes!(Path.utf8("${paths.dist}/${platform_bundle}"))?)
	smoke!(root, paths, serving, serving.url(route), platform_bundle)
}

## Check and run configurations against the served bundle. The compiler gets
## an empty package cache, so it must download the bundle from this process.
smoke! : Str, Paths, Serve, Str, Str => Try({}, _)
smoke! = |root, paths, server, platform_url, platform_bundle| {
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
	ConfigTest.run!({ roc, platform_ref: platform_url, work: config, subset: Smoke, environment }, serve_batches!)?
	downloaded = "${cache}/roc/packages/${platform_bundle.drop_suffix(".tar.zst")}"
	if !(Path.is_dir!(Path.utf8(downloaded)) ?? False) {
		return Script.fail!("the compiler did not download the platform bundle into ${downloaded}")
	}

	Script.info!("==>", "Smoke test: running examples/all-settings/Blueprint.roc against the platform bundle")?
	example = Path.read_utf8!(Path.utf8("${root}/examples/all-settings/Blueprint.roc"))?
	local_platform = "platform \"../../blueprint-platform/main.roc\""
	if !example.contains(local_platform) {
		return Script.fail!("examples/all-settings/Blueprint.roc does not name the local platform")
	}
	Path.write_utf8!(Path.utf8("${example_dir}/Blueprint.roc"), example.replace_each(local_platform, "platform \"${platform_url}\""))?
	compiler = |args| Process.with_env(Process.command(roc, args, example_dir), environment)
	match server.drive!([compiler(["check", "Blueprint.roc"])])? {
		[checked] => Process.check!(checked.code == 0, "${checked.stdout}${checked.stderr}\nroc check of the all-settings example exited with code ${checked.code.to_str()}")?
		_ => return Script.fail!("roc check did not report a result")
	}
	match server.drive!([compiler(["Blueprint.roc"])])? {
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
