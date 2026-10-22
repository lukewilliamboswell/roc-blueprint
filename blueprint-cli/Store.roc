import pf.Cmd
import pf.Env
import pf.File
import pf.OsStr
import pf.Path
import pf.Stderr
import core.Project
import core.Sexpr
import core.Steps
import core.Tree
import Download
import Paths

## The per-user store of what Blueprint downloads, named by content:
##
##     <store>/v1/artifacts/sha256/<hex>                the downloaded bytes
##     <store>/v1/trees/sha256/<hex>.<kind>/            those bytes, made usable
##     <store>/v1/trees/sha256/<hex>.<kind>.digest      what that tree held when made
##
## Nothing in the store is trusted. An artifact is hashed again before every
## use, wherever it came from: a download, an earlier run, a restored cache or
## a hand that put it there. One that does not have its name's digest is
## removed and fetched again.
##
## A tree is derived state: an archive unpacked whole, or a single file made
## executable. When it is made from an artifact that has just been verified,
## its core `Tree` digest is written beside it as S-expression text, never
## inside it. Before every use, after its artifact, the tree is hashed again
## and compared with that record, which only reads it. One that differs, or
## has no record, is removed and made again from the verified artifact, with
## no download. A cache that outlives the machine, such as a CI cache, should
## still hold `v1/artifacts` alone: trees are rebuilt from it.
##
## Everything is written under a fresh name in its final directory and then
## renamed, so no half-written file or tree is ever seen under its final
## name, and two processes that make the same thing both succeed.
Store := [].{

	## Where the digest of a download is recorded, for a message.
	Origin : [Lock, BuiltIn, Declared]

	## The store's directory from the caller's environment: `blueprint` under
	## `XDG_CACHE_HOME`, else under `.cache` in `HOME`; on Windows under
	## `LOCALAPPDATA` when `XDG_CACHE_HOME` is unset. A relative value is not
	## a per-user place and is refused.
	root_of : { xdg_cache_home : Try(Str, _), home : Try(Str, _), local_app_data : Try(Str, _), windows : Bool } -> Try(Str, Str)
	root_of = |env| {
		usable = |value|
			match value {
				Ok(text) => if (Paths.absolute(Paths.portable(text))) Ok(Paths.normalize(Paths.portable(text))) else Err(Unusable)
				Err(_) => Err(Unusable)
			}
		match (usable(env.xdg_cache_home), usable(env.local_app_data), usable(env.home)) {
			(Ok(directory), _, _) => Ok("${directory}/blueprint")
			(Err(_), Ok(directory), _) if env.windows => Ok("${directory}/blueprint")
			(Err(_), _, Ok(directory)) => Ok("${directory}/.cache/blueprint")
			_ => Err("neither XDG_CACHE_HOME nor HOME names an absolute directory to keep downloads in")
		}
	}

	artifact_path : Str, Str -> Str
	artifact_path = |store, sha256| "${store}/v1/artifacts/sha256/${sha256}"

	## One tree for each way of making the same bytes usable.
	tree_path : Str, Str, [File, TarGz, TarXz, Zip] -> Str
	tree_path = |store, sha256, unpack| {
		kind = match unpack {
			File => "file"
			TarGz => "tar.gz"
			TarXz => "tar.xz"
			Zip => "zip"
		}
		"${store}/v1/trees/sha256/${sha256}.${kind}"
	}

	## The record of a tree, beside it and never inside it.
	record_path : Str, Str, [File, TarGz, TarXz, Zip] -> Str
	record_path = |store, sha256, unpack| "${tree_path(store, sha256, unpack)}.digest"

	## What a tree held when it was made: its core `Tree` digest, which covers
	## its directories, files and executable bits, and where each symbolic link
	## in it leads, which that digest cannot say. A link's target is a path
	## within the tree, or what it reaches outside it, or empty when it reaches
	## nothing.
	TreeRecord : { format : U64, digest : Str, links : List({ path : Str, target : Str }) }

	record_format : U64
	record_format = 1

	record_text : TreeRecord -> Str
	record_text = |record| Str.concat(Sexpr.to_str(record), "\n")

	read_record : Str -> Try(TreeRecord, [InvalidSexpr(Str), MissingRequiredField(Str), UnsupportedFormat(U64)])
	read_record = |text| {
		record : TreeRecord
		record = Sexpr.parse(text)?
		if (record.format == record_format) Ok(record) else Err(UnsupportedFormat(record.format))
	}

	## A program's tree, hashed now and compared with its record. It only
	## reads: nothing in the tree is opened for writing or changed.
	## `Absent`: there is no tree to verify.
	intact! : Str, Steps.Program => Try({}, [Absent, Damaged(Str)])
	intact! = |store, program| {
		tree = tree_path(store, program.sha256, program.unpack)
		match Path.utf8(tree).type!() {
			Ok(IsDir) => {}
			Ok(_) => return Err(Damaged("is not a directory"))
			Err(_) => return Err(Absent)
		}
		text = Path.utf8(record_path(store, program.sha256, program.unpack)).read_utf8!().map_err(|_| Damaged("has no digest record"))?
		recorded = read_record(text).map_err(|_| Damaged("has a digest record that cannot be read"))?
		found = observed!(tree).map_err(|reason| Damaged("cannot be read: ${reason}"))?
		if (found == recorded) Ok({}) else Err(Damaged("is not what was recorded when it was made"))
	}

	## What a tree holds now, as its record says it. Each file is streamed
	## through SHA-256 once; a link is resolved, never written through.
	observed! : Str => Try(TreeRecord, Str)
	observed! = |tree| {
		root = Path.utf8(tree).canonicalize!().map_err(|_| "${tree} cannot be read")?
		root_text = Paths.portable(root.to_str().map_err(|_| "${tree} is not text")?)
		found = walked!(tree, root_text, "")?
		digest = Tree.digest(found.entries)?
		Ok({ format: record_format, digest, links: found.links.sort_with(|a, b| Project.bytewise(a.path, b.path)) })
	}

	## The program inside its tree. A `File` has one name there.
	program_path : Str, Steps.Program -> Str
	program_path = |store, program| {
		inner = match program.unpack {
			File => "program"
			_ => clean(program.path)
		}
		"${tree_path(store, program.sha256, program.unpack)}/${inner}"
	}

	## A name as an archive lists it, without `./` and a directory's last `/`.
	clean : Str -> Str
	clean = |name| Str.join_with(name.split_on("/").keep_if(|part| part != "" and part != "."), "/")

	## A link's target, taken from where the link is, that stays in the tree.
	inside : Str, Str -> Bool
	inside = |from, target| {
		if target.is_empty() or target.starts_with("/") or target.contains("\\") or target.contains(":") {
			return False
		}
		var $kept = from.split_on("/").keep_if(|part| part != "" and part != ".")
		for part in target.split_on("/") {
			if part == ".." {
				if $kept.is_empty() {
					return False
				}
				$kept = $kept.drop_last(1)
			} else if part != "" and part != "." {
				$kept = $kept.append(part)
			}
		}
		True
	}

	## A canonical path as a link's target in a record: relative to the
	## tree's canonical `root` when it is in the tree, else itself.
	within : Str, Str -> Str
	within = |root, reached|
		if reached == root {
			"."
		} else if reached.starts_with("${root}/") {
			reached.drop_prefix("${root}/")
		} else {
			reached
		}

	## What is wrong with an archive, from its two listings: the names alone
	## (`tar -tf`) and the long form (`tar -tvf`), line for line. Nothing is
	## unpacked from an archive that holds an absolute name, a `..` segment,
	## a name that is not plain text, a link that leaves the tree, or anything
	## that is not a file, a directory or a link; or that lacks `path` as a
	## regular file. The check is made before `tar` writes anything, because
	## a hard link out of the tree cannot be told from a file afterwards.
	listing_problem : Str, Str, Str -> Try({}, Str)
	listing_problem = |names_text, long_text, path| {
		lines = |text| text.split_on("\n").map(|line| line.drop_suffix("\r")).keep_if(|line| !line.is_empty())
		names = lines(names_text)
		long = lines(long_text)
		if names.len() != long.len() {
			return Err("its two listings disagree")
		}
		var $found = False
		var $index = 0
		for name in names {
			line = long.get($index) ?? ""
			$index = $index + 1
			if name.starts_with("/") or name.contains("\\") or name.contains(":") or name.to_utf8().any(|b| b < 32 or b == 127) {
				return Err("it holds the name ${Str.inspect(name)}, which is absolute or not plain text")
			}
			if name.split_on("/").any(|part| part == "..") {
				return Err("it holds ${name}, which leaves the directory it is unpacked in")
			}
			directory = Str.join_with(clean(name).split_on("/").drop_last(1), "/")
			match line.to_utf8().first() {
				Ok('-') =>
					if !line.ends_with(" ${name}") {
						return Err("its listing of ${name} cannot be read")
					} else if clean(name) == clean(path) {
						$found = True
					}

				Ok('d') => if !line.ends_with(" ${name}") {
					return Err("its listing of ${name} cannot be read")
				}
				Ok('l') =>
					match line.split_on(" ${name} -> ") {
						[_, target] => if !inside(directory, target) {
							return Err("it holds the link ${name} to ${target}, outside the directory it is unpacked in")
						}
						_ => return Err("its listing of the link ${name} cannot be read")
					}

				Ok('h') =>
					match line.split_on(" ${name} link to ") {
						[_, target] => if !inside("", target) or target.split_on("/").any(|part| part == "..") {
							return Err("it holds the link ${name} to ${target}, outside the directory it is unpacked in")
						}
						_ => return Err("its listing of the link ${name} cannot be read")
					}

				_ => return Err("it holds ${name}, which is not a file, a directory or a link")
			}
		}
		if ($found) Ok({}) else Err("it holds no file ${path}")
	}

	## The store on this machine.
	root! : () => Try(Str, Str)
	root! = || {
		text! = |name| Env.var_str!(OsStr.from_str(name))
		root_of({
			xdg_cache_home: text!("XDG_CACHE_HOME"),
			home: text!("HOME"),
			local_app_data: text!("LOCALAPPDATA"),
			windows: Env.platform!().os == WINDOWS,
		})
	}

	## Bytes are read in bounded chunks until the reader reports EndOfInput.
	file_digest! : Str => Try(Crypto.SHA256.Digest, _)
	file_digest! = |file| {
		reader = File.open_reader_with_capacity!(Path.utf8(file), 65536)?
		var $hasher = Crypto.SHA256.Hasher.empty()
		for! chunk in reader.chunks() {
			$hasher = $hasher.write(chunk?)
		}
		Ok($hasher.finish())
	}

	## The file that is `program`, ready to start: its artifact verified now,
	## and its tree made from that artifact if it is not there. The answer is
	## the program's real path in the store; nothing is on PATH yet.
	program! : Str, Steps.Program, Origin => Try(Str, Str)
	program! = |store, program, origin| program_with!(store, program, origin, Err(NotEmbedded))

	## An original source file, hashed before every use. This uses the same
	## artifact store and fixed digest as programs, without extraction or chmod.
	source_file! : Str, { name : Str, url : Str, sha256 : Str } => Try(Str, Str)
	source_file! = |store, source| source_file_with!(store, source, Err(NotEmbedded))

	## A provider may need the exact original archive already embedded in the
	## consumer. Verify and keep it as raw bytes, without extracting a program.
	embedded_source_file! : Str, { name : Str, url : Str, sha256 : Str }, List(U8) => Try(Str, Str)
	embedded_source_file! = |store, source, bytes| source_file_with!(store, source, Ok(bytes))

	source_file_with! : Str, { name : Str, url : Str, sha256 : Str }, Try(List(U8), [NotEmbedded]) => Try(Str, Str)
	source_file_with! = |store, source, embedded| {
		if !digest(source.sha256) {
			return Err("invalid source file SHA-256: ${source.name}")
		}
		program = { name: source.name, urls: [source.url], sha256: source.sha256, size: 0, unpack: File, path: "" }
		artifact!(
			store,
			program,
			if embedded.is_ok() {
				BuiltIn
			} else {
				Declared
			},
			embedded,
		)?
		Ok(artifact_path(store, source.sha256))
	}

	## Install the compiler bundled with this executable, without a download.
	## Its archive uses the same digest, tree and cache repair as a fetched one.
	embedded_program! : Str, Steps.Program, List(U8) => Try(Str, Str)
	embedded_program! = |store, program, bytes| program_with!(store, program, BuiltIn, Ok(bytes))

	program_with! : Str, Steps.Program, Origin, Try(List(U8), [NotEmbedded]) => Try(Str, Str)
	program_with! = |store, program, origin, embedded| {
		if !digest(program.sha256) {
			return Err("${program.name}: ${recorded(origin)} holds no SHA-256 for it")
		}
		artifact!(store, program, origin, embedded)?
		file = program_path(store, program)
		match intact!(store, program) {
			Ok({}) => return if (regular!(file)) Ok(file) else Err("the archive for ${program.name} holds no ${program.path}")
			Err(Absent) => {}
			Err(Damaged(reason)) => {
				_ = Stderr.line!("blueprint: the stored tree of ${program.name} ${reason}; making it again from its download")
				discard_tree!(store, program.sha256, program.unpack)
			}
		}
		tree!(store, program)?
		if (regular!(file)) Ok(file) else Err("the store has no ${file} after making it; delete ${tree_path(store, program.sha256, program.unpack)} and run again")
	}

	## Keep bytes an update has just hashed as the artifact of that digest,
	## so that the run after it need not fetch them again. A use still
	## hashes the file before it trusts it.
	remember! : Str, Str, List(U8) => Try({}, Str)
	remember! = |store, sha256, bytes| {
		file = artifact_path(store, sha256)
		if (regular!(file)) Ok({}) else keep!(Paths.parent(file), file, bytes)
	}

	## The digest and length of a download the store already holds, hashed
	## now: for an update that records a program whose download is one this
	## executable fetched for itself. `NotHeld`: there is no such artifact, or
	## its bytes are not the ones its name says, and the caller downloads.
	held! : Str, Str => Try({ sha256 : Str, size : U64 }, [NotHeld])
	held! = |store, sha256| {
		file = artifact_path(store, sha256)
		if !regular!(file) {
			return Err(NotHeld)
		}
		reader = File.open_reader_with_capacity!(Path.utf8(file), 65536).map_err(|_| NotHeld)?
		var $hasher = Crypto.SHA256.Hasher.empty()
		var $size = 0
		for! result in reader.chunks() {
			chunk = result.map_err(|_| NotHeld)?
			$hasher = $hasher.write(chunk)
			$size = $size + chunk.len()
		}
		if ($hasher.finish().to_hex() == sha256) Ok({ sha256, size: $size }) else Err(NotHeld)
	}

	## Preserve an explicitly named executable extension on Windows.
	executable_name : Str -> Str
	executable_name = |name| if (name.ends_with(".exe")) name else "${name}.exe"

	## Put `target` on a run's PATH as `name`: a symbolic link in `bin`, so
	## that a program finds what is beside its real path. On Windows, where a
	## symbolic link needs a privilege, and wherever `ln` cannot make one, it
	## is a copy with the same mode. Never a hard link: that is the store's own
	## file under a second name, so a step that writes to it or changes its
	## mode changes the store, under a name no verification looks at.
	expose! : Str, Str, Str => Try({}, Str)
	expose! = |bin, name, target| {
		copy! = |destination|
			Path.utf8(target).copy!(Path.utf8(destination)).map_err(|_| "could not expose ${name} from ${target} in ${bin}")
		if Env.platform!().os == WINDOWS {
			copy!("${bin}/${executable_name(name)}")
		} else {
			match Cmd.new("ln").args(["-s", target, "${bin}/${name}"].map(OsStr.from_str)).exec!() {
				Ok({}) => Ok({})
				Err(_) => copy!("${bin}/${name}")
			}
		}
	}
}

digest : Str -> Bool
digest = |text| text.to_utf8().len() == 64 and text.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))

recorded : Store.Origin -> Str
recorded = |origin|
	match origin {
		Declared => "SourceFile declaration"
		Lock => "Blueprint.lock"
		BuiltIn => "this blueprint"
	}

## What to do when the bytes are not the recorded ones.
advice : Store.Origin, Str -> Str
advice = |origin, name|
	match origin {
		Declared => "Check the original release and its published SHA-256; to deliberately change this pin, edit SourceFile and run blueprint update ${name}"
		Lock => "If the publisher replaced the file, run blueprint update ${name} and review the change"
		BuiltIn => "Set ROC to a compiler you trust, or use a blueprint release that records this one"
	}

regular! : Str => Bool
regular! = |file|
	match Path.utf8(file).type!() {
		Ok(IsFile) => True
		_ => False
	}

## Remove a file or tree. One that is not there is already removed. A link
## is removed itself, never what it leads to.
discard! : Str => {}
discard! = |target| {
	_ = match Path.utf8(target).type!() {
		Ok(IsDir) => Path.utf8(target).delete_all!()
		Ok(_) => Path.utf8(target).delete!()
		Err(_) => Ok({})
	}
	{}
}

## Remove a tree and its record.
discard_tree! : Str, Str, [File, TarGz, TarXz, Zip] => {}
discard_tree! = |store, sha256, unpack| {
	discard!(Store.tree_path(store, sha256, unpack))
	discard!(Store.record_path(store, sha256, unpack))
}

## A fresh directory in `directory`, which is created if need be. What is
## renamed out of it stays on one filesystem.
fresh! : Str => Try(Path, Str)
fresh! = |directory| {
	Path.utf8(directory).create_all!().map_err(|_| "cannot create ${directory}")?
	Env.create_temp_dir_in!(Path.utf8(directory), ".tmp-").map_err(|_| "cannot write in ${directory}")
}

## The verified artifact of a program: the one in the store when its digest
## is its name, otherwise the first URL whose bytes have that digest. Bytes
## under the name that are not the recorded ones are removed, and so is every
## tree that stood beside them, before anything is fetched.
artifact! : Str, Steps.Program, Store.Origin, Try(List(U8), [NotEmbedded]) => Try({}, Str)
artifact! = |store, program, origin, embedded| {
	file = Store.artifact_path(store, program.sha256)
	if regular!(file) {
		match Store.file_digest!(file) {
			Ok(found) if found.to_hex() == program.sha256 => return Ok({})
			_ => {
				action = if (embedded.is_ok()) "restoring it from the embedded archive" else "fetching it again"
				_ = Stderr.line!("blueprint: the stored download of ${program.name} is not what its name says; ${action}")
				discard!(file)
				for kind in [File, TarGz, TarXz, Zip] {
					discard_tree!(store, program.sha256, kind)
				}
			}
		}
	}
	match embedded {
		Ok(bytes) => {
			verified!(bytes, "embedded archive", program, origin)?
			_ = Stderr.line!("blueprint: installing embedded Roc compiler")
			return keep!(Paths.parent(file), file, bytes)
		}
		Err(NotEmbedded) => {}
	}
	var $failures = []
	for url in program.urls {
		_ = Stderr.line!("blueprint: fetching ${program.name} from ${url}")
		match fetched!(url, program, origin) {
			Ok(bytes) => {
				keep!(Paths.parent(file), file, bytes)?
				return Ok({})
			}
			Err(reason) => {
				$failures = $failures.append(reason)
			}
		}
	}
	match $failures {
		[] => Err("${program.name} has no URL to download it from")
		[only] => Err(only)
		_ => Err("no URL of ${program.name} served it:\n  ${Str.join_with($failures, "\n  ")}")
	}
}

## One URL's bytes, if they are the recorded ones. The length is compared
## first, when one is recorded: an error page is told from a release by its
## size, in words that say so, before its digest is.
fetched! : Str, Steps.Program, Store.Origin => Try(List(U8), Str)
fetched! = |url, program, origin| {
	bytes = Download.get!(url).map_err(|reason| "could not download ${program.name} from ${url}: ${reason}")?
	verified!(bytes, url, program, origin)?
	Ok(bytes)
}

## Both embedded and downloaded archives must match their recorded identity.
verified! : List(U8), Str, Steps.Program, Store.Origin => Try({}, Str)
verified! = |bytes, url, program, origin| {
	if program.size != 0 and bytes.len() != program.size {
		return Err("${program.name} from ${url} is ${bytes.len().to_str()} bytes, not the ${program.size.to_str()} recorded in ${recorded(origin)}; nothing was unpacked")
	}
	actual = Crypto.SHA256.hash(bytes).to_hex()
	if actual != program.sha256 {
		return Err("${program.name} from ${url} has SHA-256 ${actual}, not the ${program.sha256} in ${recorded(origin)}; nothing was unpacked. ${advice(origin, program.name)}")
	}
	Ok({})
}

## Write verified bytes under a fresh name beside their final one, then
## rename. Another process that kept the same bytes first has done this work.
keep! : Str, Str, List(U8) => Try({}, Str)
keep! = |directory, file, bytes| {
	temporary = fresh!(directory)?
	staged = temporary.join("artifact")
	result = match staged.write_bytes!(bytes) {
		Ok({}) =>
			match staged.rename!(Path.utf8(file)) {
				Ok({}) => Ok({})
				Err(_) => if (regular!(file)) Ok({}) else Err("cannot keep a download at ${file}")
			}

		Err(_) => Err("cannot write a download in ${directory}")
	}
	_ = temporary.delete_all!()
	result
}

## Make a program's tree from its verified artifact, in a fresh directory
## that is renamed into place once it is whole. It is hashed there, once, and
## its record is renamed into place first, so that a tree under its final
## name has one.
tree! : Str, Steps.Program => Try({}, Str)
tree! = |store, program| {
	artifact = Store.artifact_path(store, program.sha256)
	destination = Store.tree_path(store, program.sha256, program.unpack)
	temporary = fresh!(Paths.parent(destination))?
	make! = || {
		staged = Paths.portable(temporary.to_str().map_err(|_| "the store's path is not text")?)
		tree = "${staged}/tree"
		Path.utf8(tree).create_dir!().map_err(|_| "cannot write in ${store}")?
		match program.unpack {
			File => {
				Path.utf8(artifact).copy!(Path.utf8("${tree}/program")).map_err(|_| "cannot copy ${program.name} within ${store}")?
				if Env.platform!().os != WINDOWS {
					run!("chmod", ["0555", "${tree}/program"], "make ${program.name} executable")?
				}
			}
			_ => {
				names = listed!(["-tf", artifact], program.name)?
				long = listed!(["-tvf", artifact], program.name)?
				Store.listing_problem(names, long, program.path).map_err(|reason| "the archive for ${program.name} is not unpacked: ${reason}")?
				run!("tar", ["-xf", artifact, "-C", tree], "unpack the archive for ${program.name}")?
				files = regular_files!(tree).map_err(|reason| "the archive for ${program.name} unpacked to ${reason}")?
				if !regular!("${tree}/${Store.clean(program.path)}") {
					return Err("the archive for ${program.name} holds no ${program.path}")
				}
				# Files are read-only; directories stay writable, so that the
				# tree can still be deleted.
				for batch in (if (Env.platform!().os == WINDOWS) [] else files).chunks_of(256) {
					run!("chmod", ["a-w"].concat(batch), "make the files of ${program.name} read-only")?
				}
			}
		}
		made = Store.observed!(tree).map_err(|reason| "the archive for ${program.name} unpacked to a tree that cannot be recorded: ${reason}")?
		record = Path.utf8("${staged}/digest")
		record.write_utf8!(Store.record_text(made)).map_err(|_| "cannot write in ${store}")?
		record.rename!(Path.utf8(Store.record_path(store, program.sha256, program.unpack))).map_err(|_| "cannot record the tree of ${program.name} beside ${destination}")?
		match Path.utf8(tree).rename!(Path.utf8(destination)) {
			Ok({}) => Ok({})
			# Another process made the same tree first, from the same bytes.
			# It is used only if it holds what this one does.
			Err(_) =>
				match (Path.utf8(destination).type!(), Store.observed!(destination)) {
					(Ok(IsDir), Ok(found)) if found == made => Ok({})
					_ => Err("cannot place ${program.name} at ${destination}; delete what is there")
				}
		}
	}
	result = make!()
	_ = temporary.delete_all!()
	result
}

## A listing `tar` prints of an archive.
listed! : List(Str), Str => Try(Str, Str)
listed! = |args, name|
	Cmd.new("tar").args(args.map(OsStr.from_str)).capture!()
		.map_err(|_| "`tar ${Str.join_with(args, " ")}` could not list the archive for ${name}")

run! : Str, List(Str), Str => Try({}, Str)
run! = |program, args, purpose|
	Cmd.new(OsStr.from_str(program)).args(args.map(OsStr.from_str)).exec!().map_err(|_| "could not ${purpose}: `${program}` failed")

## Every regular file below a directory. Anything that is not a file, a
## directory or a link is named as the error.
regular_files! : Str => Try(List(Str), Str)
regular_files! = |directory| {
	var $files = []
	for entry in Path.utf8(directory).list!().map_err(|_| "a directory that cannot be read: ${directory}")? {
		full = Paths.portable(entry.to_str().map_err(|_| "a name that is not text in ${directory}")?)
		match entry.type!() {
			Ok(IsFile) => {
				$files = $files.append(full)
			}
			Ok(IsDir) => {
				$files = $files.concat(regular_files!(full)?)
			}
			Ok(IsSymLink) => {}
			_ => return Err("${full}, which is not a file, a directory or a link")
		}
	}
	Ok($files)
}

## The entries of a tree below `prefix`, for its core `Tree` digest, and its
## symbolic links. Anything that is not a file, a directory or a link is
## named as the error.
walked! : Str, Str, Str => Try({ entries : List(Tree.Entry), links : List({ path : Str, target : Str }) }, Str)
walked! = |tree, root, prefix| {
	directory = if (prefix == "") tree else "${tree}/${prefix}"
	var $entries = []
	var $links = []
	for child in Path.utf8(directory).list!().map_err(|_| "${directory} cannot be read")? {
		full = Paths.portable(child.to_str().map_err(|_| "a name in ${directory} is not text")?)
		name = full.split_on("/").last() ?? full
		relative = if (prefix == "") name else "${prefix}/${name}"
		match child.type!() {
			Ok(IsDir) => {
				below = walked!(tree, root, relative)?
				$entries = $entries.append({ path: relative, kind: Dir }).concat(below.entries)
				$links = $links.concat(below.links)
			}
			Ok(IsFile) => {
				executable = child.is_executable!().map_err(|_| "${full} cannot be read")?
				content = Store.file_digest!(full).map_err(|_| "${full} cannot be read")?
				$entries = $entries.append({ path: relative, kind: File({ executable, digest: content }) })
			}
			Ok(IsSymLink) => {
				$links = $links.append({ path: relative, target: resolved!(full, root) })
			}
			_ => return Err("it holds ${relative}, which is not a file, a directory or a link")
		}
	}
	Ok({ entries: $entries, links: $links })
}

## Where a link leads: a path within the tree whose canonical path is
## `root`, or the canonical path it reaches outside it, or nothing.
resolved! : Str, Str => Str
resolved! = |link, root|
	match Path.utf8(link).canonicalize!() {
		Ok(reached) => Store.within(root, Paths.portable(reached.to_str() ?? ""))
		Err(_) => ""
	}

unix : { xdg_cache_home : Try(Str, [Unset]), home : Try(Str, [Unset]), local_app_data : Try(Str, [Unset]), windows : Bool }
unix = { xdg_cache_home: Err(Unset), home: Ok("/home/me"), local_app_data: Err(Unset), windows: False }

# The store follows the cache convention of the host, and is never relative.
expect Store.root_of(unix) == Ok("/home/me/.cache/blueprint")
expect Store.root_of({ ..unix, xdg_cache_home: Ok("/xdg/") }) == Ok("/xdg/blueprint")
expect Store.root_of({ ..unix, xdg_cache_home: Ok("cache") }) == Ok("/home/me/.cache/blueprint")
expect Store.root_of({ ..unix, local_app_data: Ok("/elsewhere") }) == Ok("/home/me/.cache/blueprint")
expect Store.root_of({ ..unix, home: Err(Unset) }).is_err() and Store.root_of({ ..unix, home: Ok("me") }).is_err()
expect Store.root_of({ xdg_cache_home: Err(Unset), home: Ok("C:\\Users\\me"), local_app_data: Ok("C:\\Users\\me\\AppData\\Local"), windows: True }) == Ok("C:/Users/me/AppData/Local/blueprint")
expect Store.root_of({ xdg_cache_home: Err(Unset), home: Ok("C:\\Users\\me"), local_app_data: Err(Unset), windows: True }) == Ok("C:/Users/me/.cache/blueprint")

sha : Str
sha = "893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f"

roc : Steps.Program
roc = { name: "roc-stable", urls: ["https://example.test/roc.tar.gz"], sha256: sha, size: 0, unpack: TarGz, path: "./roc_nightly/roc" }

# An artifact is named by its digest; a tree by the digest and how it was
# made, so the same bytes as a file and as an archive do not meet.
expect Store.artifact_path("/s", sha) == "/s/v1/artifacts/sha256/${sha}"
expect Store.program_path("/s", roc) == "/s/v1/trees/sha256/${sha}.tar.gz/roc_nightly/roc"
expect Store.program_path("/s", { ..roc, unpack: File, path: "" }) == "/s/v1/trees/sha256/${sha}.file/program"
expect Store.tree_path("/s", sha, Zip) != Store.tree_path("/s", sha, TarXz)

names : Str
names = "roc/\nroc/LICENSE\nroc/roc\nroc/darwin/\nroc/darwin/lib/libSystem.tbd\n"

long : Str
long =
	\\drwxr-xr-x runner/runner     0 2026-10-05 02:20 roc/
	\\-rw-r--r-- runner/runner  1880 2026-10-05 02:20 roc/LICENSE
	\\-rwxr-xr-x runner/runner 228482160 2026-10-05 02:20 roc/roc
	\\drwxr-xr-x runner/runner     0 2026-10-05 02:20 roc/darwin/
	\\-rw-r--r-- runner/runner   120 2026-10-05 02:20 roc/darwin/lib/libSystem.tbd

# An archive of files and directories that holds the program is unpacked.
expect Store.listing_problem(names, long, "roc/roc") == Ok({})
expect Store.listing_problem(names, long, "./roc/roc") == Ok({})

# The program must be one of its regular files: not absent, and not a directory.
expect Store.listing_problem(names, long, "roc/roc.exe") == Err("it holds no file roc/roc.exe")
expect Store.listing_problem(names, long, "roc/darwin") == Err("it holds no file roc/darwin")
expect Store.listing_problem("", "", "roc/roc") == Err("it holds no file roc/roc")

# A name that would be written outside the directory is refused, wherever it is.
expect Store.listing_problem("${names}/etc/cron.d/x\n", "${long}\n-rw-r--r-- root/root 1 2026-10-05 02:20 /etc/cron.d/x", "roc/roc") == Err("it holds the name \"/etc/cron.d/x\", which is absolute or not plain text")
expect Store.listing_problem("${names}roc/../../x\n", "${long}\n-rw-r--r-- root/root 1 2026-10-05 02:20 roc/../../x", "roc/roc") == Err("it holds roc/../../x, which leaves the directory it is unpacked in")
expect Store.listing_problem("${names}roc\\\\x\n", "${long}\n-rw-r--r-- root/root 1 2026-10-05 02:20 roc\\\\x", "roc/roc").is_err()
expect Store.listing_problem("${names}C:/x\n", "${long}\n-rw-r--r-- root/root 1 2026-10-05 02:20 C:/x", "roc/roc").is_err()

# A symbolic link may point within the tree, from where it is, and no further.
expect Store.listing_problem("${names}roc/bin\n", "${long}\nlrwxrwxrwx runner/runner 0 2026-10-05 02:20 roc/bin -> darwin/../roc", "roc/roc") == Ok({})
expect Store.listing_problem("${names}roc/darwin/up\n", "${long}\nlrwxrwxrwx runner/runner 0 2026-10-05 02:20 roc/darwin/up -> ../../roc", "roc/roc") == Ok({})
expect Store.listing_problem("${names}roc/out\n", "${long}\nlrwxrwxrwx runner/runner 0 2026-10-05 02:20 roc/out -> ../../etc", "roc/roc") == Err("it holds the link roc/out to ../../etc, outside the directory it is unpacked in")
expect Store.listing_problem("${names}roc/abs\n", "${long}\nlrwxrwxrwx runner/runner 0 2026-10-05 02:20 roc/abs -> /etc/passwd", "roc/roc") == Err("it holds the link roc/abs to /etc/passwd, outside the directory it is unpacked in")

# A hard link names another member from the top of the archive; one that names
# anything else would be a file of the machine's inside the tree.
expect Store.listing_problem("${names}roc/again\n", "${long}\nhrwxr-xr-x runner/runner 0 2026-10-05 02:20 roc/again link to roc/roc", "roc/roc") == Ok({})
expect Store.listing_problem("${names}roc/passwd\n", "${long}\nhrw-r--r-- root/root 0 2026-10-05 02:20 roc/passwd link to /etc/passwd", "roc/roc") == Err("it holds the link roc/passwd to /etc/passwd, outside the directory it is unpacked in")
expect Store.listing_problem("${names}roc/up\n", "${long}\nhrw-r--r-- root/root 0 2026-10-05 02:20 roc/up link to roc/../../x", "roc/roc").is_err()

# A device, a pipe or a line that does not end in its name is not guessed at.
expect Store.listing_problem("${names}roc/null\n", "${long}\ncrw-rw-rw- root/root 1,3 2026-10-05 02:20 roc/null", "roc/roc") == Err("it holds roc/null, which is not a file, a directory or a link")
expect Store.listing_problem("${names}roc/x\n", "${long}\n-rw-r--r-- root/root 1 2026-10-05 02:20 roc/y", "roc/roc") == Err("its listing of roc/x cannot be read")
expect Store.listing_problem("${names}roc/x\n", long, "roc/roc") == Err("its two listings disagree")
# A link to the program is not the program.
expect Store.listing_problem("roc/\nroc/roc\n", "drwxr-xr-x a/b 0 2026-10-05 02:20 roc/\nlrwxrwxrwx a/b 0 2026-10-05 02:20 roc/roc -> other", "roc/roc") == Err("it holds no file roc/roc")

expect Store.inside("roc/darwin", "../roc") and Store.inside("", "roc/roc") and !Store.inside("roc", "../..") and !Store.inside("roc", "") and !Store.inside("roc", "C:/x")

expect digest(sha) and !digest("sha256:${sha}") and !digest(sha.replace_each("8", "G")) and !digest("")

expect Store.executable_name("roc-stable") == "roc-stable.exe"
expect Store.executable_name("tool.exe") == "tool.exe"

# A tree's record is beside the tree, and reads back as itself. One of
# another format, or that is not S-expression text, is not a record.
expect Store.record_path("/s", sha, TarGz) == "/s/v1/trees/sha256/${sha}.tar.gz.digest"
expect {
	record = { format: Store.record_format, digest: "sha256:${sha}", links: [{ path: "roc/bin", target: "roc/roc" }] }
	Store.read_record(Store.record_text(record)) == Ok(record)
}
expect Store.record_text({ format: 1, digest: "sha256:${sha}", links: [] }) == "(\n\t(digest \"sha256:${sha}\")\n\t(format 1)\n\t(links ()))\n"
expect Store.read_record("((format 2) (digest \"sha256:00\") (links ()))") == Err(UnsupportedFormat(2))
expect Store.read_record("{\"format\":1,\"digest\":\"sha256:00\",\"links\":[]}").is_err()

# A link is recorded by where it leads: within the tree, or outside it.
expect Store.within("/s/t", "/s/t/roc/roc") == "roc/roc" and Store.within("/s/t", "/s/t") == "." and Store.within("/s/t", "/s/tx/roc") == "/s/tx/roc"
