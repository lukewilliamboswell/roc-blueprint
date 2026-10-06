import cli.Env
import cli.OsStr
import cli.Path
import FlakeLock
import Integrity
import LinkInputs
import Process
import Release
import Script

## The notes and names of a GitHub release, for the two release workflows.
## A tag `core-X.Y.Z` releases roc-blueprint-core; any other tag releases the
## platform and the CLI.
ReleaseNotes := [].{
	Kind : [Core, Platform]

	kind : Str -> Kind
	kind = |tag| if tag.starts_with("core-") Core else Platform

	## The version a tag names: the tag, without `core-` for a core release.
	version : Str -> Str
	version = |tag| tag.drop_prefix("core-")

	## A version with a `-` in it, such as `1.2.3-rc1`, is a pre-release.
	prerelease : Str -> Bool
	prerelease = |tag| version(tag).contains("-")

	title : Str -> Str
	title = |tag|
		match kind(tag) {
			Core => "roc-blueprint-core ${version(tag)}"
			Platform => "roc-blueprint ${version(tag)}"
		}

	## The archive `dist/bundles.txt` lists for a package.
	bundle : Str, Str -> Try(Str, [NotBundled(Str)])
	bundle = |list, name|
		match list.split_on("\n").map(|line| line.split_on(" ")).find_first(|words| words.first() == Ok(name)) {
			Ok([_, archive]) => Ok(archive)
			_ => Err(NotBundled(name))
		}

	download : Str, Str, Str -> Str
	download = |repository, tag, archive| "https://github.com/${repository}/releases/download/${tag}/${archive}"

	core_notes : { repository : Str, tag : Str, archive : Str, roc_tag : Str } -> Str
	core_notes = |release|
		Str.join_with(
			[
				"The blueprint Spec and its S-expression format.",
				"",
				"```roc",
				"core: \"${download(release.repository, release.tag, release.archive)}\"",
				"```",
				"",
				"Built with Roc `${release.roc_tag}`.",
				"",
			],
			"\n",
		)

	## What a platform release was built from, beside the repository itself.
	Built : {
		roc_tag : Str,
		zig : Str,
		overlay_rev : Str,
		archives : List({ system : Str, hash : Str }),
		nixpkgs_rev : Str,
		core_url : Str,
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

	platform_notes : { repository : Str, tag : Str, archive : Str, built : Built } -> Str
	platform_notes = |release| {
		built = release.built
		archives = built.archives.map(|fetched| "${fetched.system} `${fetched.hash}`")
		Str.join_with(
			[
				"Platform (use in `Blueprint.roc`):",
				"",
				"```roc",
				"app [config] { pf: platform \"${download(release.repository, release.tag, release.archive)}\" }",
				"```",
				"",
				"The `blueprint` CLI is attached for x86_64 Linux, arm64 Linux and Apple Silicon macOS, with sha256 sums in `blueprint.sha256`. It needs Nix, and fetches its own Roc compiler through Nix. The platform supports x64musl, arm64musl, arm64mac and x64mac.",
				"",
				"Built from:",
				"",
				"- Roc `${built.roc_tag}` and Zig `${built.zig}`",
				"- Compiler archives from roc-overlay `${built.overlay_rev}`: ${Str.join_with(archives, ", ")}",
				"- nixpkgs `${built.nixpkgs_rev}`",
				"- roc-blueprint-core `${built.core_url}`",
				"- Roc packages in the CLI: ${Str.join_with(built.bundles, ", ")}",
				"- Linker inputs: roc-platform-template-zig release `${built.link_inputs}` (`link-inputs.lock.json` sha256 `${built.lock_sha256}`)",
				"",
			],
			"\n",
		)
	}

	## The program whose packages a platform release records.
	cli_source = "blueprint-cli/main.roc"

	## What a workflow step reads back through `$GITHUB_OUTPUT`.
	outputs : Str, Str -> Str
	outputs = |tag, archive| "bundle=${archive}\ntitle=${title(tag)}\nprerelease=${if prerelease(tag) "true" else "false"}\n"

	## Write the notes of the release `GITHUB_REF_NAME` names to `output`, from
	## the repository root, after the bundle was built into `dist/`.
	write! : Str, Str => Try({}, _)
	write! = |root, output| {
		repository = variable!("GITHUB_REPOSITORY")?
		tag = variable!("GITHUB_REF_NAME")?
		roc_tag = first_line!("${root}/.roc-version")?
		list = Path.read_utf8!(Path.utf8("${root}/dist/bundles.txt"))?
		released = match kind(tag) {
			Core => {
				archive = bundled!(list, "roc-blueprint-core")?
				Path.write_utf8!(Path.utf8(output), core_notes({ repository, tag, archive, roc_tag }))?
				archive
			}
			Platform => {
				archive = bundled!(list, "roc-blueprint")?
				lock_bytes = Path.read_bytes!(Path.utf8("${root}/${LinkInputs.lock_file}"))?
				link_inputs = match LinkInputs.parse_lock(Str.from_utf8_lossy(lock_bytes)) {
					Ok(lock) => lock.release
					Err(LockInvalid(reason)) => return Script.fail!("${LinkInputs.lock_file}: ${reason}")
				}
				flake_lock = Path.read_utf8!(Path.utf8("${root}/flake.lock"))?
				deps = Process.succeed!(Process.command(Process.roc!(), ["deps", cli_source], root))?.stdout
				built = {
					roc_tag,
					zig: Process.succeed!(Process.command("zig", ["version"], root))?.stdout.trim(),
					overlay_rev: revision!(flake_lock, "roc-overlay")?,
					archives: [
						{ system: Release.compiler_system, hash: Release.archive!(root, Release.compiler_system)?.hash },
						{ system: Release.sysroot_system, hash: Release.archive!(root, Release.sysroot_system)?.hash },
					],
					nixpkgs_rev: revision!(flake_lock, "nixpkgs")?,
					core_url: first_line!("${root}/blueprint-platform/core-release")?,
					bundles: bundles(deps),
					link_inputs,
					lock_sha256: Integrity.digest(lock_bytes),
				}
				Process.check!(!built.bundles.is_empty() and !built.zig.is_empty(), "`roc deps ${cli_source}` listed no package, or `zig version` printed nothing")?
				notes = platform_notes({ repository, tag, archive, built })
				Path.write_utf8!(Path.utf8(output), notes)?
				archive
			}
		}
		Script.pass!("wrote the notes of ${title(tag)} to ${output}")?
		match Env.var_str!(OsStr.from_str("GITHUB_OUTPUT")) {
			Ok(file) => {
				earlier = if Path.exists!(Path.utf8(file))? Path.read_utf8!(Path.utf8(file))? else ""
				Path.write_utf8!(Path.utf8(file), "${earlier}${outputs(tag, released)}")
			}
			Err(_) => Ok({})
		}
	}
}

variable! : Str => Try(Str, _)
variable! = |name|
	match Env.var_str!(OsStr.from_str(name)) {
		Ok(value) => if value.is_empty() Script.fail!("${name} is empty") else Ok(value)
		Err(_) => Script.fail!("${name} is not set")
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
	match ReleaseNotes.bundle(list, name) {
		Ok(archive) => Ok(archive)
		Err(NotBundled(_)) => Script.fail!("dist/bundles.txt does not list ${name}")
	}

expect ReleaseNotes.kind("core-0.4.0") == Core and ReleaseNotes.kind("0.4.0") == Platform
expect ReleaseNotes.version("core-0.4.0-rc1") == "0.4.0-rc1" and ReleaseNotes.version("0.4.0") == "0.4.0"
expect ReleaseNotes.prerelease("0.4.0-rc2") and ReleaseNotes.prerelease("core-0.4.0-rc1")

# The `-` of the `core-` prefix does not make a pre-release.
expect !ReleaseNotes.prerelease("core-0.4.0") and !ReleaseNotes.prerelease("0.4.0")
expect ReleaseNotes.title("core-0.4.0") == "roc-blueprint-core 0.4.0" and ReleaseNotes.title("0.4.0-rc2") == "roc-blueprint 0.4.0-rc2"

expect ReleaseNotes.bundle("roc-blueprint-core abc.tar.zst\nroc-blueprint def.tar.zst\n", "roc-blueprint") == Ok("def.tar.zst")
expect ReleaseNotes.bundle("roc-blueprint-core abc.tar.zst\nroc-blueprint def.tar.zst\n", "roc-blueprint-core") == Ok("abc.tar.zst")
expect ReleaseNotes.bundle("roc-blueprint-core abc.tar.zst\n", "roc-blueprint") == Err(NotBundled("roc-blueprint"))

expect ReleaseNotes.outputs("0.4.0-rc2", "def.tar.zst") == "bundle=def.tar.zst\ntitle=roc-blueprint 0.4.0-rc2\nprerelease=true\n"
expect ReleaseNotes.outputs("core-0.4.0", "abc.tar.zst") == "bundle=abc.tar.zst\ntitle=roc-blueprint-core 0.4.0\nprerelease=false\n"

expect ReleaseNotes.core_notes({ repository: "me/roc-blueprint", tag: "core-0.4.0", archive: "abc.tar.zst", roc_tag: "nightly-1" }) ==
	\\The blueprint Spec and its S-expression format.
	\\
	\\```roc
	\\core: "https://github.com/me/roc-blueprint/releases/download/core-0.4.0/abc.tar.zst"
	\\```
	\\
	\\Built with Roc `nightly-1`.
	\\

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
	zig: "0.16.0",
	overlay_rev: "fb02fef7",
	archives: [{ system: "x86_64-linux", hash: "sha256-iTyG=" }, { system: "aarch64-darwin", hash: "sha256-4BR/=" }],
	nixpkgs_rev: "4975466d",
	core_url: "https://example.test/core.tar.zst",
	bundles: ["basic-cli 0.24.0 `AEjfyaMF`", "http 1.0.0 `6ZUwqYhC`"],
	link_inputs: "link-inputs-sha256-2d",
	lock_sha256: "ff00",
}

expect ReleaseNotes.platform_notes({ repository: "me/roc-blueprint", tag: "0.4.0", archive: "def.tar.zst", built: built_sample }) ==
	\\Platform (use in `Blueprint.roc`):
	\\
	\\```roc
	\\app [config] { pf: platform "https://github.com/me/roc-blueprint/releases/download/0.4.0/def.tar.zst" }
	\\```
	\\
	\\The `blueprint` CLI is attached for x86_64 Linux, arm64 Linux and Apple Silicon macOS, with sha256 sums in `blueprint.sha256`. It needs Nix, and fetches its own Roc compiler through Nix. The platform supports x64musl, arm64musl, arm64mac and x64mac.
	\\
	\\Built from:
	\\
	\\- Roc `nightly-1` and Zig `0.16.0`
	\\- Compiler archives from roc-overlay `fb02fef7`: x86_64-linux `sha256-iTyG=`, aarch64-darwin `sha256-4BR/=`
	\\- nixpkgs `4975466d`
	\\- roc-blueprint-core `https://example.test/core.tar.zst`
	\\- Roc packages in the CLI: basic-cli 0.24.0 `AEjfyaMF`, http 1.0.0 `6ZUwqYhC`
	\\- Linker inputs: roc-platform-template-zig release `link-inputs-sha256-2d` (`link-inputs.lock.json` sha256 `ff00`)
	\\

# The archives recorded are the two the release compiler is assembled from.
expect [Release.compiler_system, Release.sysroot_system] == ["x86_64-linux", "aarch64-darwin"]
