import cli.Cmd
import cli.Env
import cli.File
import cli.OsStr
import cli.Path
import core.Sbom
import core.Manifest
import core.Project

## The only filesystem boundary in SBOM reporting: regular inputs, bounded
## metadata reads, streaming final-byte SHA256 and size, exclusive new
## sidecars and manifests, and the members of a produced archive.
SbomFiles := [].{
	read! : Str => Try(Str, _)
	read! = |name| {
		path = Path.utf8(name)
		if !Path.is_file!(path)? {
			return Err(NotRegularFile)
		}
		reader = File.open_reader!(path)?
		var $bytes = []
		var $done = False
		while !$done {
			remaining = Sbom.max_json_bytes + 1 - $bytes.len()
			match reader.read_up_to!(if remaining < 65536 remaining else 65536) {
				Ok(chunk) => {
					$bytes = $bytes.concat(chunk)
					if $bytes.len() > Sbom.max_json_bytes {
						return Err(InputTooLarge)
					}
				}
				Err(EndOfInput) => {
					$done = True
				}
				Err(error) => return Err(error)
			}
		}
		Str.from_utf8($bytes).map_err(|_| InvalidUtf8)
	}

	digest! : Str => Try(Str, _)
	digest! = |name| measure!(name).map_ok(|measured| measured.sha256)

	## The SHA-256 and size of a regular file's bytes, in one pass: what an
	## evidence manifest states about a subject or sidecar.
	measure! : Str => Try({ sha256 : Str, size : U64 }, _)
	measure! = |name| {
		path = Path.utf8(name)
		if !Path.is_file!(path)? {
			return Err(NotRegularFile)
		}
		reader = File.open_reader!(path)?
		var $hasher = Crypto.SHA256.Hasher.empty()
		var $size = 0.U64
		var $done = False
		while !$done {
			match reader.read_up_to!(65536) {
				Ok(bytes) => {
					$hasher = $hasher.write(bytes)
					$size = $size + bytes.len()
				}
				Err(EndOfInput) => {
					$done = True
				}
				Err(error) => return Err(error)
			}
		}
		Ok({ sha256: $hasher.finish().to_hex(), size: $size })
	}

	## Measure declared sidecars and every existing conventional sidecar of the
	## same subject. Missing declared files remain absent for Manifest.check to
	## diagnose; a present unreadable/nonregular canonical candidate is refused.
	## `listed_only` is an explicit legacy/subset policy, not a completeness check.
	observe_sidecars! : Str, Manifest.Manifest, Bool => Try(List({ filename : Str, sha256 : Str, size : U64 }), _)
	observe_sidecars! = |manifest_path, manifest, listed_only| {
		declared = manifest.sidecars.map(|entry| entry.filename)
		var $canonical = []
		if !listed_only {
			directory = Manifest.directory_of(manifest_path)
			for entry in Path.list!(Path.utf8(if (directory.is_empty()) "." else directory))? {
				name = Manifest.file_name_of(Path.to_str(entry) ?? "")
				if Manifest.is_standard_sidecar(manifest.subject.filename, name) {
					$canonical = $canonical.append(name)
				}
			}
		}
		canonical = $canonical.sort_with(Project.bytewise)
		names = declared.concat(canonical).fold([], |all, name| if (all.contains(name)) all else all.append(name))
		var $observed = []
		for name in names {
			path = Manifest.beside(manifest_path, name)
			if Path.exists!(Path.utf8(path))? {
				measured = measure!(path).map_err(|_| Invalid("sidecar ${name} is present but not a readable regular file"))?
				$observed = $observed.append({ filename: name, sha256: measured.sha256, size: measured.size })
			}
		}
		Ok($observed)
	}

	## Check the complete intended set before writing its first member. Writers
	## still use RequireNew to protect against a collision after this check.
	require_new_outputs! : List(Str) => Try({}, _)
	require_new_outputs! = |paths| {
		for path in paths {
			if Path.exists!(Path.utf8(path))? {
				return Err(OutputExists(path))
			}
		}
		Ok({})
	}

	write_new! : Str, Str => Try({}, _)
	write_new! = |output, text| {
		# Count the exact emitted bytes, including the terminating newline.
		if text.to_utf8().len() > Sbom.max_json_bytes {
			return Err(InputTooLarge)
		}
		File.with_writer!(Path.utf8(output), RequireNew, |writer| writer.write_utf8!(text))
	}

	## The members of a `.tar.zst` archive, a `roc bundle` for one: each
	## regular file's name, size and SHA-256, in archive order. The system
	## `tar`, which must read zstd, lists the archive first; a member that is
	## a symbolic or hard link, a device or a fifo, or whose name has an empty,
	## `.` or `..` part or a leading `/`, is refused before anything is
	## extracted. Directory entries are not members. The members are then
	## extracted into a fresh private temporary directory, checked to be
	## regular files there, hashed, and deleted with the directory.
	archive_members! : Str => Try(List({ name : Str, size : U64, sha256 : Str }), _)
	archive_members! = |archive| {
		if !Path.is_file!(Path.utf8(archive))? {
			return Err(NotRegularFile)
		}
		names = tar!(["--zstd", "-tf", archive])?
		kinds = tar!(["--zstd", "-tvf", archive])?
		if names.len() != kinds.len() {
			return Err(ArchiveListing("tar listed ${names.len().to_str()} members and ${kinds.len().to_str()} kinds"))
		}
		if names.len() > 4096 {
			return Err(ArchiveListing("more than 4096 members"))
		}
		var $regular = []
		var $index = 0
		while $index < names.len() {
			name = names.get($index) ?? ""
			kind = (kinds.get($index) ?? "").to_utf8().first() ?? ' '
			$index = $index + 1
			if kind == 'd' {
				if !safe_member(name.drop_suffix("/")) {
					return Err(ArchiveListing("unsafe member name ${name}"))
				}
			} else if kind == '-' {
				if !safe_member(name) {
					return Err(ArchiveListing("unsafe member name ${name}"))
				}
				if $regular.contains(name) {
					return Err(ArchiveListing("member ${name} appears twice"))
				}
				$regular = $regular.append(name)
			} else {
				return Err(ArchiveListing("member ${name} is not a regular file"))
			}
		}
		regular = $regular
		work = Path.to_str(Env.create_temp_dir_with_prefix!("blueprint-sbom-members-")?)?
		result = hashed!(archive, work, regular)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

## Run `tar` with these arguments and return the lines it printed.
tar! : List(Str) => Try(List(Str), _)
tar! = |args| {
	output = Cmd.new(OsStr.from_str("tar")).args(args.map(OsStr.from_str)).run!().map_err(|_| TarUnavailable)?
	match output.status {
		Exited(0) => {}
		_ => return Err(TarFailed(Str.from_utf8_lossy(output.stderr_bytes)))
	}
	text = Str.from_utf8(output.stdout_bytes).map_err(|_| ArchiveListing("member names are not UTF-8"))?
	Ok(text.split_on("\n").keep_if(|line| !line.is_empty()))
}

## A member name `tar` creates only below the extraction directory, and an
## identity can carry: no empty, `.` or `..` part, no control, space,
## backslash or `?` byte.
safe_member : Str -> Bool
safe_member = |name| {
	parts = name.split_on("/")
	!name.is_empty() and name.to_utf8().len() <= 512 and !parts.any(|part| part.is_empty() or part == "." or part == "..") and name.to_utf8().all(|byte| byte > 32 and byte != 127 and byte != '\\' and byte != '?')
}

## Extract `archive` into `work`, then measure and hash each of `regular`.
hashed! = |archive, work, regular| {
	_ = tar!(["--zstd", "-xf", archive, "-C", work])?
	var $members = []
	for name in regular {
		path = "${work}/${name}"
		if Path.type!(Path.utf8(path))? != IsFile {
			return Err(ArchiveListing("member ${name} was not extracted as a regular file"))
		}
		size = Path.size_in_bytes!(Path.utf8(path))?
		$members = $members.append({ name, size, sha256: SbomFiles.digest!(path)? })
	}
	Ok($members)
}

expect safe_member("src/Main.roc") and safe_member("LICENSE")
expect !safe_member("") and !safe_member("/etc/passwd") and !safe_member("../escape") and !safe_member("a/../b") and !safe_member("dir/") and !safe_member("a b") and !safe_member("a\\b")
