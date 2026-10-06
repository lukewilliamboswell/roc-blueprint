import cli.Env
import cli.OsStr
import cli.Path
import Integrity
import LinkInputs
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

	platform_notes : { repository : Str, tag : Str, archive : Str, roc_tag : Str, core_url : Str, link_inputs : Str, lock_sha256 : Str } -> Str
	platform_notes = |release|
		Str.join_with(
			[
				"Platform (use in `Blueprint.roc`):",
				"",
				"```roc",
				"app [config] { pf: platform \"${download(release.repository, release.tag, release.archive)}\" }",
				"```",
				"",
				"The `blueprint` CLI is attached for x86_64 Linux, arm64 Linux and Apple Silicon macOS, with sha256 sums in `blueprint.sha256`. It needs Nix, and fetches its own Roc compiler through Nix.",
				"",
				"Uses roc-blueprint-core `${release.core_url}`. Built with Roc `${release.roc_tag}`. The platform supports x64musl, arm64musl, arm64mac and x64mac.",
				"",
				"Linker inputs: roc-platform-template-zig release `${release.link_inputs}` (`link-inputs.lock.json` sha256 `${release.lock_sha256}`).",
				"",
			],
			"\n",
		)

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
				notes = platform_notes({
					repository,
					tag,
					archive,
					roc_tag,
					core_url: first_line!("${root}/blueprint-platform/core-release")?,
					link_inputs,
					lock_sha256: Integrity.digest(lock_bytes),
				})
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

expect ReleaseNotes.platform_notes({ repository: "me/roc-blueprint", tag: "0.4.0", archive: "def.tar.zst", roc_tag: "nightly-1", core_url: "https://example.test/core.tar.zst", link_inputs: "link-inputs-sha256-2d", lock_sha256: "ff00" }) ==
	\\Platform (use in `Blueprint.roc`):
	\\
	\\```roc
	\\app [config] { pf: platform "https://github.com/me/roc-blueprint/releases/download/0.4.0/def.tar.zst" }
	\\```
	\\
	\\The `blueprint` CLI is attached for x86_64 Linux, arm64 Linux and Apple Silicon macOS, with sha256 sums in `blueprint.sha256`. It needs Nix, and fetches its own Roc compiler through Nix.
	\\
	\\Uses roc-blueprint-core `https://example.test/core.tar.zst`. Built with Roc `nightly-1`. The platform supports x64musl, arm64musl, arm64mac and x64mac.
	\\
	\\Linker inputs: roc-platform-template-zig release `link-inputs-sha256-2d` (`link-inputs.lock.json` sha256 `ff00`).
	\\
