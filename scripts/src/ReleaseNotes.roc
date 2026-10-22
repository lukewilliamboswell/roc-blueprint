import cli.Path
import Bundle
import FlakeLock
import Integrity
import LinkInputs
import Notes
import Process
import Release
import Script

## The notes and names of a GitHub release. One release holds the platform
## bundle, the core bundle it depends on and the CLI binaries.
##
## The notes are written by hand in `docs/releases/<version>.adoc`. A release
## renders them with its bundle URLs and adds what it was built from.
ReleaseNotes := [].{

	## The notes a version is released with. A release candidate uses the
	## notes of the version it is a candidate for; a dry run, which releases
	## nothing, renders the newest the chapter includes.
	noted : Str, Str -> Try(Str, [NoNotes])
	noted = |version, chapter|
		if version == Bundle.dry_run_version {
			Notes.included(chapter).first().map_err(|_| NoNotes)
		} else {
			Ok(version.split_on("-").first() ?? version)
		}

	notes_file : Str -> Str
	notes_file = |version| "docs/releases/${version}.adoc"

	## What stands for each bundle's URL in the notes.
	platform_placeholder = "{platform-url}"
	core_placeholder = "{core-url}"

	## A version with a `-` in it, such as `1.2.3-rc1`, is a pre-release.
	prerelease : Str -> Bool
	prerelease = |tag| tag.contains("-")

	title : Str -> Str
	title = |tag| "roc-blueprint ${tag}"

	## What a release was built from, beside the repository itself.
	Built : {
		roc_tag : Str,
		roc_stable : Str,
		zig : Str,
		overlay_rev : Str,
		archives : List({ system : Str, hash : Str }),
		nixpkgs_rev : Str,
		core_url : Str,
		sbom_url : Str,
		bundles : List(Str),
		link_inputs : Str,
		lock_sha256 : Str,
	}

	## The released Roc packages a program is compiled from, in the order
	## `roc deps` first prints them, each once. The compiler resolves that
	## tree, dependencies of dependencies included, so it is what the binary
	## holds whatever any list kept by hand says.
	bundles : Str -> List(Str)
	bundles = |deps|
		deps.split_on("\n").fold(
			[],
			|found, line|
				match line.split_on(" ").find_first(|word| word.starts_with("https://")) {
					Ok(url) => if found.contains(bundle_name(url)) found else found.append(bundle_name(url))
					Err(_) => found
				},
		)

	## `repository version` and the bundle's hash, for a GitHub release URL;
	## any other URL as it is.
	bundle_name : Str -> Str
	bundle_name = |url|
		match url.split_on("/") {
			["https:", "", "github.com", _, repository, "releases", "download", release, file] => "${repository} ${release} `${file.drop_suffix(".tar.zst")}`"
			_ => "`${url}`"
		}

	## The record a release appends to its notes.
	built_from : Built -> Str
	built_from = |built| {
		archives = built.archives.map(|fetched| "${fetched.system} `${fetched.hash}`")
		Str.join_with(
			[
				"## Built from",
				"",
				"- Roc `${built.roc_tag}` and Zig `${built.zig}`; release scripts run with `roc-stable` ${built.roc_stable}",
				"- Compiler archives from roc-overlay `${built.overlay_rev}`: ${Str.join_with(archives, ", ")}",
				"- nixpkgs `${built.nixpkgs_rev}`",
				"- roc-blueprint-core `${built.core_url}`",
				"- Standalone SBOM tool: `blueprint-sbom-<system>` beside the CLI binaries, listed in `blueprint.sha256`; recommended for CI, which then needs no Roc and compiles nothing. The same tool as a [pinned Roc app bundle](${built.sbom_url}) runs with the compiler (same compiler pin; no Blueprint project required)",
				"- SBOMs: every binary and source bundle has `<asset>.spdx.json` (SPDX 3.0.1), `<asset>.cdx.json` (CycloneDX 1.7) and `<asset>.spdx-2.3.json` (SPDX 2.3) beside it, checked against the asset's bytes and covered by the release attestation",
				"- Roc packages in the CLI: ${Str.join_with(built.bundles, ", ")}",
				"- Linker inputs: roc-platform-template-zig release `${built.link_inputs}` (`link-inputs.lock.json` sha256 `${built.lock_sha256}`)",
				"",
			],
			"\n",
		)
	}

	## The program whose packages a release records.
	cli_source = "blueprint-cli/main.roc"

	## Write the notes of the release of `tag` to `output`, from the
	## repository root, after the bundles were built into `dist/` for it.
	write! : Str, Str, Str => Try({}, _)
	write! = |root, tag, output| {
		repository = Bundle.repository!()
		chapter = Path.read_utf8!(Path.utf8("${root}/docs/releases.adoc"))?
		version = match noted(tag, chapter) {
			Ok(found) => found
			Err(NoNotes) => return Script.fail!("docs/releases.adoc includes no release notes")
		}
		authored = notes_file(version)
		if !(Path.is_file!(Path.utf8("${root}/${authored}")) ?? False) {
			return Script.fail!("${authored} does not exist: write the notes of ${version} before releasing it")
		}
		list = Path.read_utf8!(Path.utf8("${root}/dist/bundles.txt"))?
		archive = bundled!(list, "roc-blueprint")?
		core_archive = bundled!(list, "roc-blueprint-core")?
		sbom_archive = bundled!(list, "roc-blueprint-sbom")?
		lock_bytes = Path.read_bytes!(Path.utf8("${root}/${LinkInputs.lock_file}"))?
		link_inputs = match LinkInputs.parse_lock(Str.from_utf8_lossy(lock_bytes)) {
			Ok(lock) => lock.release
			Err(LockInvalid(reason)) => return Script.fail!("${LinkInputs.lock_file}: ${reason}")
		}
		flake_lock = Path.read_utf8!(Path.utf8("${root}/flake.lock"))?
		deps = Process.succeed!(Process.command(Process.roc!(), ["deps", cli_source], root))?.stdout
		built = {
			roc_tag: first_line!("${root}/blueprint-cli/compiler-version")?,
			roc_stable: Process.succeed!(Process.command("roc-stable", ["version"], root))?.stdout.trim(),
			zig: Process.succeed!(Process.command("zig", ["version"], root))?.stdout.trim(),
			overlay_rev: revision!(flake_lock, "roc-overlay")?,
			archives: [
				{ system: Release.compiler_system, hash: Release.archive!(root, Release.compiler_system)?.hash },
				{ system: Release.sysroot_system, hash: Release.archive!(root, Release.sysroot_system)?.hash },
			],
			nixpkgs_rev: revision!(flake_lock, "nixpkgs")?,
			core_url: Bundle.release_url(repository, tag, core_archive),
			sbom_url: Bundle.release_url(repository, tag, sbom_archive),
			bundles: bundles(deps),
			link_inputs,
			lock_sha256: Integrity.digest(lock_bytes),
		}
		Process.check!(!built.bundles.is_empty() and !built.zig.is_empty(), "`roc deps ${cli_source}` listed no package, or `zig version` printed nothing")?
		urls = [
			{ placeholder: platform_placeholder, url: Bundle.release_url(repository, tag, archive) },
			{ placeholder: core_placeholder, url: built.core_url },
		]
		rendered = match Notes.render(Path.read_utf8!(Path.utf8("${root}/${authored}"))?, { title: "= ${title(version)}", urls }) {
			Ok(markdown) => markdown
			Err(WrongTitle(found)) => return Script.fail!("${authored} must open with `= ${title(version)}`, not `${found}`")
			Err(UnusedPlaceholder(name)) => return Script.fail!("${authored} never uses ${name}")
			Err(UnresolvedPlaceholder(name)) => return Script.fail!("${authored} uses ${name}, which this release does not fill in")
			Err(UnclosedBlock) => return Script.fail!("${authored} has a source block that is never closed")
		}
		Path.write_utf8!(Path.utf8(output), "${rendered}\n${built_from(built)}")?
		Script.pass!("wrote the notes of ${title(tag)} to ${output}")
	}
}

## The revision `flake.lock` pins an input to.
revision! : Str, Str => Try(Str, _)
revision! = |flake_lock, node|
	match FlakeLock.locked(flake_lock, node) {
		Ok(pin) => Ok(pin.rev)
		Err(NoPin(_)) => Script.fail!("flake.lock has no GitHub pin for ${node}")
	}

first_line! : Str => Try(Str, _)
first_line! = |file| Ok(Path.read_utf8!(Path.utf8(file))?.split_on("\n").first() ?? "")

bundled! : Str, Str => Try(Str, _)
bundled! = |list, name|
	match Bundle.archive(list, name) {
		Ok(archive) => Ok(archive)
		Err(NotBundled(_)) => Script.fail!("dist/bundles.txt does not list ${name}")
	}

expect ReleaseNotes.prerelease("0.4.0-rc2") and !ReleaseNotes.prerelease("0.4.0")
expect ReleaseNotes.title("0.4.0-rc2") == "roc-blueprint 0.4.0-rc2"

deps_sample =
	\\blueprint-cli/main.roc (/repo/blueprint-cli/main.roc) [app]
	\\├── https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMF.tar.zst [platform]
	\\│   └── https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhC.tar.zst
	\\├── ../blueprint-core/main.roc (/repo/blueprint-core/main.roc)
	\\├── ../blueprint-nix/main.roc (/repo/blueprint-nix/main.roc)
	\\│   └── ../blueprint-core/main.roc (/repo/blueprint-core/main.roc) [shared]
	\\└── https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBE.tar.zst
	\\    ├── https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6.tar.zst
	\\    ├── https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhC.tar.zst [shared]
	\\    └── https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPw.tar.zst
	\\
	\\[shared]           this package was already shown above, where its dependencies are listed
	\\

# Every released package of the tree once, transitive ones included; local
# packages and the legend are not bundles.
expect ReleaseNotes.bundles(deps_sample) == ["basic-cli 0.24.0 `AEjfyaMF`", "http 1.0.0 `6ZUwqYhC`", "weaver 0.9.0 `7j6KBFBE`", "roc-ansi 0.13.0 `JXLM47L6`", "path 4.0.0 `7YfABZPw`"]
expect ReleaseNotes.bundles("main.roc (/repo/main.roc) [app]\n").is_empty() and ReleaseNotes.bundles("").is_empty()

# A package served from anywhere else is named by its whole URL.
expect ReleaseNotes.bundle_name("https://example.test/packages/abc.tar.zst") == "`https://example.test/packages/abc.tar.zst`"
expect ReleaseNotes.bundle_name("https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPw.tar.zst") == "path 4.0.0 `7YfABZPw`"

built_sample : ReleaseNotes.Built
built_sample = {
	roc_tag: "nightly-1",
	roc_stable: "Roc compiler version nightly-0",
	zig: "0.16.0",
	overlay_rev: "fb02fef7",
	archives: [{ system: "x86_64-linux", hash: "sha256-iTyG=" }, { system: "aarch64-darwin", hash: "sha256-4BR/=" }],
	nixpkgs_rev: "4975466d",
	core_url: "https://example.test/core.tar.zst",
	sbom_url: "https://example.test/roc-blueprint-sbom-tool.tar.zst",
	bundles: ["basic-cli 0.24.0 `AEjfyaMF`", "http 1.0.0 `6ZUwqYhC`"],
	link_inputs: "link-inputs-sha256-2d",
	lock_sha256: "ff00",
}

expect ReleaseNotes.built_from(built_sample) ==
	\\## Built from
	\\
	\\- Roc `nightly-1` and Zig `0.16.0`; release scripts run with `roc-stable` Roc compiler version nightly-0
	\\- Compiler archives from roc-overlay `fb02fef7`: x86_64-linux `sha256-iTyG=`, aarch64-darwin `sha256-4BR/=`
	\\- nixpkgs `4975466d`
	\\- roc-blueprint-core `https://example.test/core.tar.zst`
	\\- Standalone SBOM tool: `blueprint-sbom-<system>` beside the CLI binaries, listed in `blueprint.sha256`; recommended for CI, which then needs no Roc and compiles nothing. The same tool as a [pinned Roc app bundle](https://example.test/roc-blueprint-sbom-tool.tar.zst) runs with the compiler (same compiler pin; no Blueprint project required)
	\\- SBOMs: every binary and source bundle has `<asset>.spdx.json` (SPDX 3.0.1), `<asset>.cdx.json` (CycloneDX 1.7) and `<asset>.spdx-2.3.json` (SPDX 2.3) beside it, checked against the asset's bytes and covered by the release attestation
	\\- Roc packages in the CLI: basic-cli 0.24.0 `AEjfyaMF`, http 1.0.0 `6ZUwqYhC`
	\\- Linker inputs: roc-platform-template-zig release `link-inputs-sha256-2d` (`link-inputs.lock.json` sha256 `ff00`)
	\\

# A candidate is released with the notes of its version, a dry run with the newest.
expect ReleaseNotes.noted("0.5.0-rc1", "") == Ok("0.5.0") and ReleaseNotes.noted("0.5.0", "") == Ok("0.5.0")
expect ReleaseNotes.noted("0.0.1-dry-run", "include::releases/0.6.0.adoc[leveloffset=+1]\ninclude::releases/0.5.0.adoc[leveloffset=+1]\n") == Ok("0.6.0")
expect ReleaseNotes.noted("0.0.1-dry-run", "= Release notes\n") == Err(NoNotes)
expect ReleaseNotes.notes_file("0.5.0") == "docs/releases/0.5.0.adoc"

# The archives recorded are the two the release compiler is assembled from.
expect [Release.compiler_system, Release.sysroot_system] == ["x86_64-linux", "aarch64-darwin"]
