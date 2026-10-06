import cli.Env
import cli.Path
import Integrity
import Script
import Tar
import "../../link-inputs.lock.json" as committed_lock : Str

## The platform's prebuilt linker inputs: the musl runtime files Roc links
## into every `Blueprint.roc`, taken from an independently released archive
## that the committed `link-inputs.lock.json` selects by content.
##
## The lock is the only authority. Every run recomputes the size and SHA-256
## of the archive, cached or downloaded, before reading a single member, and
## checks every member against the archive's own inventory before anything is
## installed. A difference stops the run: there is no other release, source
## build or signing service to fall back to.
LinkInputs := [].{
	Asset : { asset : Str, sha256 : Str, size : U64 }
	Source : { repository : Str, sha : Str, ref : Str, workflow : Str, input_fingerprint : Str }

	## `link-inputs.lock.json`. Its `targets` key is a Roc keyword, so it is
	## read as `artifacts`; see `parse_lock`.
	Lock : { schema_version : U64, kind : Str, repository : Str, release : Str, manifest : { asset : Str, sha256 : Str }, source : Source, artifacts : { all : Asset } }

	## `build-input-release.json`, the release's own description of its assets.
	Manifest : { schema_version : U64, kind : Str, source : Source, assets : { all : Asset } }

	## `dependency.json`, the archive's inventory of every other member.
	Inventory : { schema : U64, version : Str, source_commit : Str, input_fingerprint : Str, files : Dict(Str, { sha256 : Str, size : U64 }) }

	## A verified archive member and where it is installed.
	Installed : { path : Str, data : List(U8) }

	lock_file = "link-inputs.lock.json"
	platform_dir = "blueprint-platform"

	## Licences and the inventory go here so `scripts/bundle.sh` can ship them.
	notices_dir = "blueprint-platform/linker-inputs"

	## The files `blueprint-platform/main.roc` links, relative to both the
	## archive root and the platform directory.
	linked = [
		"targets/x64musl/crt1.o",
		"targets/x64musl/libc.a",
		"targets/x64musl/libzigc.a",
		"targets/x64musl/libcompiler_rt.a",
		"targets/arm64musl/crt1.o",
		"targets/arm64musl/libc.a",
		"targets/arm64musl/libzigc.a",
		"targets/arm64musl/libcompiler_rt.a",
	]

	max_manifest : U64
	max_manifest = 64 * 1024
	max_archive : U64
	max_archive = 256 * 1024 * 1024
	limits : Tar.Limits
	limits = { members: 256, bytes: 512 * 1024 * 1024 }

	## Decode and validate the lock. The release name must be derived from the
	## manifest digest, so a lock cannot name one release and pin another.
	parse_lock : Str -> Try(Lock, [LockInvalid(Str)])
	parse_lock = |encoded| {
		# Adapt the published key only at this boundary, and never accept the
		# internal alias in a lock.
		if encoded.contains("\"artifacts\"") {
			return Err(LockInvalid("unexpected key \"artifacts\""))
		}
		decoded : Try(Lock, _)
		decoded = Json.parse(Str.replace_each(encoded, "\"targets\"", "\"artifacts\""))
		lock = decoded.map_err(|_| LockInvalid("not a linker-input lock"))?
		source = lock.source
		archive = lock.artifacts.all
		if lock.schema_version != 1 or lock.kind != "roc-zig-link-inputs" {
			Err(LockInvalid("unsupported schema_version or kind"))
		} else if !valid_repository(lock.repository) {
			Err(LockInvalid("repository must be a GitHub owner/name"))
		} else if lock.manifest.asset != "build-input-release.json" or !Integrity.is_hex(lock.manifest.sha256, 64) {
			Err(LockInvalid("manifest must be build-input-release.json with a SHA-256"))
		} else if lock.release != "link-inputs-sha256-${lock.manifest.sha256}" {
			Err(LockInvalid("release must be link-inputs-sha256-<manifest.sha256>"))
		} else if source.repository != lock.repository or !Integrity.is_hex(source.sha, 40) or !Integrity.is_hex(source.input_fingerprint, 64) or !source.ref.starts_with("refs/heads/") or !source.workflow.starts_with("${lock.repository}/.github/workflows/") {
			Err(LockInvalid("source does not describe a build in the release repository"))
		} else if archive.asset != "link-inputs-all.tar" or !Integrity.is_hex(archive.sha256, 64) or archive.size == 0 or archive.size > max_archive {
			Err(LockInvalid("targets.all must be link-inputs-all.tar with a SHA-256 and a size"))
		} else {
			Ok(lock)
		}
	}

	## Decode the manifest and require it to describe exactly what the lock pins.
	check_manifest : List(U8), Lock -> Try({}, [ManifestInvalid(Str)])
	check_manifest = |bytes, lock| {
		text = Str.from_utf8(bytes).map_err(|_| ManifestInvalid("not UTF-8"))?
		decoded : Try(Manifest, _)
		decoded = Json.parse(text)
		manifest = decoded.map_err(|_| ManifestInvalid("not a linker-input release manifest"))?
		if manifest.schema_version != 1 or manifest.kind != lock.kind {
			Err(ManifestInvalid("schema_version or kind disagrees with the lock"))
		} else if manifest.source != lock.source {
			Err(ManifestInvalid("source disagrees with the lock"))
		} else if manifest.assets != lock.artifacts {
			Err(ManifestInvalid("assets disagree with the lock's targets"))
		} else {
			Ok({})
		}
	}

	## Read every member of a verified archive and check each against the
	## archive's inventory: same names, sizes and digests, nothing undeclared
	## and nothing missing.
	unpack : List(U8), Lock -> Try(List(Tar.Entry), [ArchiveInvalid(Str)])
	unpack = |bytes, lock| {
		entries = Tar.entries(bytes, limits).map_err(|TarInvalid(reason)| ArchiveInvalid(reason))?
		encoded = member(entries, "dependency.json")?
		text = Str.from_utf8(encoded).map_err(|_| ArchiveInvalid("dependency.json is not UTF-8"))?
		decoded : Try(Inventory, _)
		decoded = Json.parse(text)
		inventory = decoded.map_err(|_| ArchiveInvalid("dependency.json is not a linker-input inventory"))?
		if inventory.schema != 1 or !Integrity.is_hex(inventory.input_fingerprint, 64) {
			return Err(ArchiveInvalid("dependency.json has an unsupported schema"))
		}
		if inventory.source_commit != lock.source.sha {
			return Err(ArchiveInvalid("dependency.json source_commit ${inventory.source_commit} disagrees with the lock's ${lock.source.sha}"))
		}
		for entry in entries {
			if entry.name != "dependency.json" {
				match inventory.files.get(entry.name) {
					Err(KeyNotFound) => return Err(ArchiveInvalid("member not declared in dependency.json: ${entry.name}"))
					Ok(expected) =>
						match Integrity.verify(entry.data, expected) {
							Err(Mismatch(reason)) => return Err(ArchiveInvalid("${entry.name}: ${reason}"))
							Ok({}) => {}
						}
				}
			}
		}
		for name in inventory.files.keys() {
			if !entries.any(|entry| entry.name == name) {
				return Err(ArchiveInvalid("member declared in dependency.json is missing: ${name}"))
			}
		}
		Ok(entries)
	}

	## What this repository takes from the archive: the linked files, every
	## licence and the inventory itself.
	selection : List(Tar.Entry) -> Try(List(Installed), [ArchiveInvalid(Str)])
	selection = |entries| {
		var $selected = []
		for name in linked {
			$selected = $selected.append({ path: "${platform_dir}/${name}", data: member(entries, name)? })
		}
		licences = entries.keep_if(|entry| entry.name.starts_with("licenses/"))
		if licences.is_empty() {
			return Err(ArchiveInvalid("no licenses/ members"))
		}
		for entry in licences {
			$selected = $selected.append({ path: "${notices_dir}/${entry.name}", data: entry.data })
		}
		Ok($selected.append({ path: "${notices_dir}/dependency.json", data: member(entries, "dependency.json")? }))
	}

	## Download if not cached, verify, and install the linker inputs. Files
	## that already hold the verified bytes are left untouched.
	fetch! : Path => Try({}, _)
	fetch! = |root| {
		lock = read_lock!(root)?
		cache = cache_dir(root, lock)
		Path.create_all!(cache)?
		selected = verified_selection!(lock, cache, Download)?
		count = selected.len().to_str()
		match installed_state!(root, selected)? {
			Same => Script.pass!("${count} linker-input files from ${lock.release} are already installed")
			Differs(_) => {
				staging = Env.create_temp_dir_in!(cache, "staging-")?
				result = install!(root, staging, selected)
				Path.delete_all!(staging)?
				result?
				match installed_state!(root, selected)? {
					Same => Script.pass!("installed ${count} linker-input files from ${lock.release}")
					Differs(reason) => Script.fail!("${reason} after installing")
				}
			}
		}
	}

	## Verify the installed files against the lock without using the network.
	check! : Path => Try({}, _)
	check! = |root| {
		lock = read_lock!(root)?
		selected = verified_selection!(lock, cache_dir(root, lock), Offline)?
		match installed_state!(root, selected)? {
			Same => Script.pass!("${selected.len().to_str()} installed linker-input files match ${lock.release}")
			Differs(reason) => Script.fail!("${reason}; ${fetch_hint}")
		}
	}
}

fetch_hint = "run scripts/link_inputs.roc fetch"

valid_repository = |value| match Str.split_on(value, "/") {
	[owner, name] => Tar.safe_name(owner) and Tar.safe_name(name)
	_ => Bool.False
}

member : List(Tar.Entry), Str -> Try(List(U8), [ArchiveInvalid(Str)])
member = |entries, name|
	match entries.keep_if(|entry| entry.name == name) {
		[entry] => Ok(entry.data)
		_ => Err(ArchiveInvalid("required member is missing: ${name}"))
	}

parent : Str -> Str
parent = |name| Str.join_with(Str.split_on(name, "/").drop_last(1), "/")

## Content-addressed, so a changed lock never reuses another archive's slot.
cache_dir = |root, lock| Path.join(root, ".cache/link-inputs/${lock.artifacts.all.sha256}")

read_lock! = |root| {
	path = Path.join(root, LinkInputs.lock_file)
	if !Path.is_file!(path)? {
		return Script.fail!("${LinkInputs.lock_file} not found; run this script from the repository root")
	}
	match LinkInputs.parse_lock(Path.read_utf8!(path)?) {
		Ok(lock) => Ok(lock)
		Err(LockInvalid(reason)) => Script.fail!("${LinkInputs.lock_file}: ${reason}")
	}
}

## The manifest and archive the lock pins, verified on every call whether or
## not they were already cached, then the archive's verified members.
verified_selection! = |lock, cache, mode| {
	manifest = obtain!(lock, cache, lock.manifest.asset, AtMost(LinkInputs.max_manifest), lock.manifest.sha256, mode)?
	match LinkInputs.check_manifest(manifest, lock) {
		Ok({}) => {}
		Err(ManifestInvalid(reason)) => return Script.fail!("${lock.manifest.asset}: ${reason}")
	}
	archive = lock.artifacts.all
	bytes = obtain!(lock, cache, archive.asset, Exactly(archive.size), archive.sha256, mode)?
	selected = match LinkInputs.unpack(bytes, lock) {
		Ok(entries) => LinkInputs.selection(entries)
		Err(ArchiveInvalid(reason)) => Err(ArchiveInvalid(reason))
	}
	match selected {
		Ok(files) => Ok(files)
		Err(ArchiveInvalid(reason)) => Script.fail!("${archive.asset}: ${reason}")
	}
}

## The bytes of a release asset, from the cache or the lock-derived URL. The
## size is checked before the file is read and the digest before the bytes are
## returned. A cached file that differs is removed and the run fails.
obtain! = |lock, cache, asset, size, sha256, mode| {
	path = Path.join(cache, asset)
	if Path.exists!(path)? {
		return match read_verified!(path, size, sha256) {
			Ok(bytes) => {
				Script.info!("HIT ", "${asset} (cached; sha256 ${sha256} verified)")?
				Ok(bytes)
			}
			Err(Mismatch(reason)) => {
				match mode {
					Download => Path.delete!(path)?
					Offline => {}
				}
				Script.fail!("cached ${asset} does not match ${LinkInputs.lock_file}: ${reason}; ${fetch_hint} to download it again")
			}
			Err(other) => Err(other)
		}
	}
	match mode {
		Offline => Script.fail!("${asset} is not in ${Path.display(cache)}; ${fetch_hint}")
		Download => {
			url = "https://github.com/${lock.repository}/releases/download/${lock.release}/${asset}"
			limit = match size {
				Exactly(bytes) => bytes
				AtMost(bytes) => bytes
			}
			temp = Env.create_temp_dir_in!(cache, "download-")?
			result = download!(url, Path.join(temp, asset), path, limit, size, sha256)
			Path.delete_all!(temp)?
			result
		}
	}
}

download! = |url, temp, path, limit, size, sha256| {
	arguments = ["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--retry", "3", "--max-time", "300", "--max-filesize", limit.to_str(), "--output", Path.display(temp), url]
	match Script.command("curl").run!(arguments) {
		Ok({}) => {}
		# curl has already said why. There is nowhere else to look.
		Err(_) => return Script.fail!("could not download ${url}")
	}
	match read_verified!(temp, size, sha256) {
		Ok(bytes) => {
			# Only verified bytes enter the cache.
			Path.rename!(temp, path)?
			Ok(bytes)
		}
		Err(Mismatch(reason)) => Script.fail!("download of ${url} does not match ${LinkInputs.lock_file}: ${reason}")
		Err(other) => Err(other)
	}
}

read_verified! = |path, size, sha256| {
	actual = Path.size_in_bytes!(path)?
	within = match size {
		Exactly(bytes) => actual == bytes
		AtMost(bytes) => actual <= bytes
	}
	if !within {
		expected = match size {
			Exactly(bytes) => bytes.to_str()
			AtMost(bytes) => "at most ${bytes.to_str()}"
		}
		return Err(Mismatch("size is ${actual.to_str()} bytes, expected ${expected}"))
	}
	bytes = Path.read_bytes!(path)?
	Integrity.verify(bytes, { sha256, size: bytes.len() })?
	Ok(bytes)
}

## Write the selection into fresh staging, read it back to confirm it, then
## move each file into place. Staging shares a filesystem with the platform,
## so each move is a rename.
install! = |root, staging, selected| {
	for file in selected {
		path = Path.join(staging, file.path)
		Path.create_all!(Path.join(staging, parent(file.path)))?
		Path.write_bytes!(path, file.data)?
	}
	for file in selected {
		match Integrity.verify(Path.read_bytes!(Path.join(staging, file.path))?, { sha256: Integrity.digest(file.data), size: file.data.len() }) {
			Ok({}) => {}
			Err(Mismatch(reason)) => return Script.fail!("staged ${file.path}: ${reason}")
		}
	}
	# Licences and the inventory belong wholly to this script; replace them
	# so nothing from an earlier release survives.
	notices = Path.join(root, LinkInputs.notices_dir)
	if Path.exists!(notices)? {
		Path.delete_all!(notices)?
	}
	for file in selected {
		Path.create_all!(Path.join(root, parent(file.path)))?
		Path.rename!(Path.join(staging, file.path), Path.join(root, file.path))?
	}
	Ok({})
}

## Whether every selected file is present as a regular file with the verified
## bytes and the notices directory holds nothing else; otherwise what differs.
installed_state! = |root, selected| {
	for file in selected {
		path = Path.join(root, file.path)
		if !Path.exists!(path)? {
			return Ok(Differs("${file.path} is missing"))
		}
		match Path.type!(path)? {
			IsFile => {}
			_ => return Ok(Differs("${file.path} is not a regular file"))
		}
		match Integrity.verify(Path.read_bytes!(path)?, { sha256: Integrity.digest(file.data), size: file.data.len() }) {
			Ok({}) => {}
			Err(Mismatch(reason)) => return Ok(Differs("${file.path} does not match ${LinkInputs.lock_file}: ${reason}"))
		}
	}
	for name in files_under!(Path.join(root, LinkInputs.notices_dir), LinkInputs.notices_dir)? {
		if !selected.any(|file| file.path == name) {
			return Ok(Differs("${name} is not part of the locked linker inputs"))
		}
	}
	Ok(Same)
}

files_under! : Path, Str => Try(List(Str), _)
files_under! = |dir, prefix| {
	var $names = []
	for child in Path.list!(dir)? {
		base = match Path.filename(child) {
			Ok(value) => Path.display(value)
			Err(_) => return Script.fail!("unexpected entry in ${prefix}")
		}
		name = "${prefix}/${base}"
		match Path.type!(child)? {
			IsFile => {
				$names = $names.append(name)
			}
			IsDir => {
				$names = $names.concat(files_under!(child, name)?)
			}
			# Reported by name so the caller sees it is not in the selection.
			_ => {
				$names = $names.append(name)
			}
		}
	}
	Ok($names)
}

lock_error = |encoded| match LinkInputs.parse_lock(encoded) {
	Ok(_) => "accepted"
	Err(LockInvalid(reason)) => reason
}

manifest_error = |encoded| match_manifest(committed_lock, encoded)

match_manifest = |lock_text, encoded| match LinkInputs.parse_lock(lock_text) {
	Err(LockInvalid(reason)) => reason
	Ok(lock) =>
		match LinkInputs.check_manifest(encoded.to_utf8(), lock) {
			Ok({}) => "accepted"
			Err(ManifestInvalid(reason)) => reason
		}
}

committed_manifest = "{\"assets\":{\"all\":{\"asset\":\"link-inputs-all.tar\",\"sha256\":\"e54e6ed10fd433f55c9ab9d1b8ff346739b5c9d21f24c833cd0be4785393aef4\",\"size\":7004160}},\"kind\":\"roc-zig-link-inputs\",\"schema_version\":1,\"source\":{\"input_fingerprint\":\"5d5376f62958ab464f51b5facd3b78c7cb2605273b1e7b732e44a7df8e16ddff\",\"ref\":\"refs/heads/adopt/content-addressed-linker-inputs\",\"repository\":\"lukewilliamboswell/roc-platform-template-zig\",\"sha\":\"4051337809b72aedddf87dbcf7d885cdbcf13309\",\"workflow\":\"lukewilliamboswell/roc-platform-template-zig/.github/workflows/linker-inputs.yml\"}}"

# The committed lock is valid, and each identity it carries is checked.
expect lock_error(committed_lock) == "accepted"
expect lock_error("{}") == "not a linker-input lock"
expect lock_error(Str.replace_each(committed_lock, "\"targets\"", "\"artifacts\"")) == "unexpected key \"artifacts\""
expect lock_error(Str.replace_each(committed_lock, "\"schema_version\": 1", "\"schema_version\": 2")) == "unsupported schema_version or kind"
# A release that is not named after the pinned manifest is refused, whichever
# of the two was edited.
expect lock_error(Str.replace_each(committed_lock, "link-inputs-sha256-2d", "link-inputs-sha256-3d")) == "release must be link-inputs-sha256-<manifest.sha256>"
expect lock_error(Str.replace_each(committed_lock, "\"sha256\": \"2d", "\"sha256\": \"3d")) == "release must be link-inputs-sha256-<manifest.sha256>"
expect lock_error(Str.replace_each(committed_lock, "\"sha256\": \"e54e", "\"sha256\": \"E54E")) == "targets.all must be link-inputs-all.tar with a SHA-256 and a size"
expect lock_error(Str.replace_each(committed_lock, "\"size\": 7004160", "\"size\": 0")) == "targets.all must be link-inputs-all.tar with a SHA-256 and a size"
expect lock_error(Str.replace_each(committed_lock, "\"repository\": \"lukewilliamboswell/roc-platform-template-zig\",\n  \"release\"", "\"repository\": \"../elsewhere\",\n  \"release\"")) == "repository must be a GitHub owner/name"

# The release manifest must pin the same archive as the lock.
expect manifest_error(committed_manifest) == "accepted"
expect manifest_error(Str.replace_each(committed_manifest, "e54e", "f54e")) == "assets disagree with the lock's targets"
expect manifest_error(Str.replace_each(committed_manifest, "7004160", "7004161")) == "assets disagree with the lock's targets"
expect manifest_error(Str.replace_each(committed_manifest, "4051337", "5051337")) == "source disagrees with the lock"
expect manifest_error("[]") == "not a linker-input release manifest"
