import cli.Path
import Bundle
import Examples
import Integrity
import Process
import Release
import Script

## The files a release publishes, gathered into one directory so the job that
## publishes them needs no script and no knowledge of where each was built.
##
## The names of the binaries and of their checksum file are a contract.
## roc-automation's `setup-blueprint` action downloads `blueprint-<system>`
## from the release a caller names, exactly as published, and callers copy the
## SHA-256 values from `blueprint.sha256`. Renaming one, archiving the
## binaries or changing the checksum file breaks every caller.
Assets := [].{

	## The binaries, in the order `blueprint.sha256` lists them.
	binaries = ["blueprint-x86_64-linux", "blueprint-aarch64-linux", "blueprint-aarch64-darwin", "blueprint-x86_64-windows.exe"]

	checksums = "blueprint.sha256"

	## Where the assets are gathered, and the list of their names beside it.
	directory = "dist/release"
	list_file = "dist/release-assets.txt"

	docs_archive : Str -> Str
	docs_archive = |version| "roc-blueprint-docs-${version}.zip"

	manual : Str -> Str
	manual = |version| "roc-blueprint-${version}.pdf"

	## Every asset of a release, by name, in byte order.
	inventory : { version : Str, platform_bundle : Str, core_bundle : Str, tool_bundle : Str } -> List(Str)
	inventory = |release|
		Process.sorted(
			binaries.concat(sidecars_of(binaries)).concat(sidecars_of([release.platform_bundle, release.core_bundle, release.tool_bundle])).concat([
				checksums,
				release.platform_bundle,
				release.core_bundle,
				release.tool_bundle,
				"${Examples.archive_name(release.version)}.zip",
				docs_archive(release.version),
				manual(release.version),
			]),
		)

	## What breaks the contract in a list of asset names and the text of the
	## checksum file, or "" when nothing does.
	contract_problem : List(Str), Str -> Str
	contract_problem = |names, sums| {
		missing = binaries.concat([checksums]).keep_if(|name| !names.contains(name))
		others = names.keep_if(|name| name.starts_with("blueprint") and !binaries.contains(name) and name != checksums and !sidecars_of(binaries).contains(name))
		summed = Process.lines(sums).map(|line| line.split_on("  ").last() ?? "")
		malformed = Process.lines(sums).keep_if(|line| !checksum_line(line))
		if !missing.is_empty() {
			"the release must hold ${Str.join_with(missing, ", ")}"
		} else if !others.is_empty() {
			"the release must hold no other blueprint binary or checksum file: ${Str.join_with(others, ", ")}"
		} else if summed != binaries or !malformed.is_empty() {
			"${checksums} must hold one `<sha256>  <name>` line for each of ${Str.join_with(binaries, ", ")}, in that order"
		} else {
			""
		}
	}

	## Archive the rendered site, the manual and API reference a release was
	## built with, as `dist/roc-blueprint-docs-<version>.zip`.
	package_docs! : Str, Str, Str => Try({}, _)
	package_docs! = |root, version, site| {
		Process.check!(Path.is_file!(Path.utf8("${site}/index.html")) ?? False, "${site} holds no index.html: render the manual first")?
		archive = "${root}/dist/${docs_archive(version)}"
		Path.create_all!(Path.utf8("${root}/dist"))?
		if Path.exists!(Path.utf8(archive))? {
			Path.delete!(Path.utf8(archive))?
		}
		_ = Process.succeed!(Process.command("zip", ["-q", "-r", "-X", archive, "."], site))?
		Script.pass!("wrote dist/${docs_archive(version)}")
	}

	## Gather the assets of the release of `version` into `dist/release/`,
	## with the manual `pdf` under its released name, and list them.
	collect! : Str, Str, Str => Try({}, _)
	collect! = |root, version, pdf| {
		list = Path.read_utf8!(Path.utf8("${root}/dist/bundles.txt"))?
		(platform_bundle, core_bundle) = match (Bundle.archive(list, "roc-blueprint"), Bundle.archive(list, "roc-blueprint-core")) {
			(Ok(first), Ok(second)) => (first, second)
			_ => return Script.fail!("dist/bundles.txt does not list both bundles: run scripts/bundle.roc ${version}")
		}
		tool_bundle = Bundle.archive(list, "roc-blueprint-sbom").map_err(|_| ScriptFailed)?
		names = inventory({ version, platform_bundle, core_bundle, tool_bundle })
		gathered = "${root}/${directory}"
		if Path.exists!(Path.utf8(gathered))? {
			Path.delete_all!(Path.utf8(gathered))?
		}
		Path.create_all!(Path.utf8(gathered))?
		for name in names {
			source = if name == manual(version) pdf else "${root}/dist/${name}"
			if !(Path.is_file!(Path.utf8(source)) ?? False) {
				return Script.fail!("${source} does not exist, so the release would lack ${name}")
			}
			Path.copy!(Path.utf8(source), Path.utf8("${gathered}/${name}"))?
		}

		sums = Path.read_utf8!(Path.utf8("${gathered}/${checksums}"))?
		reason = contract_problem(names, sums)
		Process.check!(reason.is_empty(), reason)?
		for name in binaries {
			line = Release.checksum_line(name, Path.read_bytes!(Path.utf8("${gathered}/${name}"))?)
			Process.check!(sums.contains(line), "${checksums} does not hold the SHA-256 of the ${name} being released")?
		}

		Path.write_utf8!(Path.utf8("${root}/${list_file}"), "${Str.join_with(names, "\n")}\n")?
		Script.pass!("gathered ${names.len().to_str()} assets in ${directory}:\n${Str.join_with(names, "\n")}")
	}
}

## Each subject's SBOM sidecars: SPDX 3.0.1, and SPDX 2.3 of the same inventory.
sidecars_of : List(Str) -> List(Str)
sidecars_of = |subjects| subjects.fold([], |all, name| all.concat(["${name}.spdx.json", "${name}.spdx-2.3.json"]))

## `<64 lowercase hex digits>  <name>`, as `sha256sum -c` reads it.
checksum_line : Str -> Bool
checksum_line = |line|
	match line.split_on("  ") {
		[digest, name] => !name.is_empty() and digest.to_utf8().len() == 64 and digest.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))
		_ => False
	}

sums_sample = Str.join_with(Assets.binaries.map(|name| Release.checksum_line(name, name.to_utf8())), "")

names_sample = Assets.inventory({ version: "0.5.0", platform_bundle: "Abc.tar.zst", core_bundle: "roc-blueprint-core-Def.tar.zst", tool_bundle: "roc-blueprint-sbom-Tool.tar.zst" })

expect names_sample == ["Abc.tar.zst", "Abc.tar.zst.spdx-2.3.json", "Abc.tar.zst.spdx.json", "blueprint-aarch64-darwin", "blueprint-aarch64-darwin.spdx-2.3.json", "blueprint-aarch64-darwin.spdx.json", "blueprint-aarch64-linux", "blueprint-aarch64-linux.spdx-2.3.json", "blueprint-aarch64-linux.spdx.json", "blueprint-x86_64-linux", "blueprint-x86_64-linux.spdx-2.3.json", "blueprint-x86_64-linux.spdx.json", "blueprint-x86_64-windows.exe", "blueprint-x86_64-windows.exe.spdx-2.3.json", "blueprint-x86_64-windows.exe.spdx.json", "blueprint.sha256", "roc-blueprint-0.5.0.pdf", "roc-blueprint-core-Def.tar.zst", "roc-blueprint-core-Def.tar.zst.spdx-2.3.json", "roc-blueprint-core-Def.tar.zst.spdx.json", "roc-blueprint-docs-0.5.0.zip", "roc-blueprint-examples-0.5.0.zip", "roc-blueprint-sbom-Tool.tar.zst", "roc-blueprint-sbom-Tool.tar.zst.spdx-2.3.json", "roc-blueprint-sbom-Tool.tar.zst.spdx.json"]

# The contract is these names, whatever systems the build script lists.
expect Assets.binaries == Release.systems.map(|released| Release.binary_name("blueprint", released.system))
expect Assets.binaries == ["blueprint-x86_64-linux", "blueprint-aarch64-linux", "blueprint-aarch64-darwin", "blueprint-x86_64-windows.exe"] and Assets.checksums == "blueprint.sha256"

expect Assets.contract_problem(names_sample, sums_sample) == ""
expect Assets.contract_problem(names_sample.keep_if(|name| name != "blueprint-aarch64-linux"), sums_sample) == "the release must hold blueprint-aarch64-linux"
expect Assets.contract_problem(names_sample.keep_if(|name| name != "blueprint.sha256"), sums_sample) == "the release must hold blueprint.sha256"
expect Assets.contract_problem(names_sample.concat(["blueprint-x86_64-linux.tar.gz"]), sums_sample) == "the release must hold no other blueprint binary or checksum file: blueprint-x86_64-linux.tar.gz"
expect Assets.contract_problem(names_sample.concat(["blueprint.sha512"]), sums_sample) != ""

# A checksum file that lists other names, another order or another format is refused.
expect Assets.contract_problem(names_sample, "${sums_sample}${Release.checksum_line("blueprint-x86_64-darwin", [])}") != ""
expect Assets.contract_problem(names_sample, sums_sample.replace_each("  blueprint-x86_64-linux", " *blueprint-x86_64-linux")) != ""
expect Assets.contract_problem(names_sample, "") != ""
