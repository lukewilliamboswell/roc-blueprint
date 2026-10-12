import pf.Cmd
import pf.Env
import pf.File
import pf.OsStr
import pf.Path
import pf.Stderr
import core.Steps
import Download
import Paths

## The per-user store of what Blueprint downloads, named by content:
##
##     <store>/v1/artifacts/sha256/<hex>          the downloaded bytes
##     <store>/v1/trees/sha256/<hex>.<kind>/      those bytes, made usable
##
## An artifact is never trusted. It is hashed again before every use,
## wherever it came from: a download, an earlier run, a restored cache or a
## hand that put it there. One that does not have its name's digest is
## removed and fetched again.
##
## A tree is derived state: an archive unpacked whole, or a single file made
## executable. It is checked once, when it is made from an artifact that has
## just been verified, and is NOT verified again on later uses. Whoever can
## write to the store can change a tree. So a tree is used only beside its
## verified artifact, and a cache that outlives the machine, such as a CI
## cache, should hold `v1/artifacts` alone: trees are rebuilt from it.
##
## Everything is written under a fresh name in its final directory and then
## renamed, so no half-written file or tree is ever seen under its final
## name, and two processes that make the same thing both succeed.
Store := [].{

	## Where the digest of a download is recorded, for a message.
	Origin : [Lock, BuiltIn]

	## The store's directory from the caller's environment: `blueprint` under
	## `XDG_CACHE_HOME`, else under `.cache` in `HOME`; on Windows under
	## `LOCALAPPDATA` when `XDG_CACHE_HOME` is unset. A relative value is not
	## a per-user place and is refused.
	root_of : { xdg_cache_home : Try(Str, _), home : Try(Str, _), local_app_data : Try(Str, _), windows : Bool } -> Try(Str, Str)
	root_of = |env| {
		usable = |value|
			match value {
				Ok(text) => if Paths.absolute(Paths.portable(text)) Ok(Paths.normalize(Paths.portable(text))) else Err(Unusable)
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
		if $found Ok({}) else Err("it holds no file ${path}")
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

	## Bytes are read in bounded chunks; an empty chunk is the end of the file.
	file_digest! : Str => Try(Crypto.SHA256.Digest, _)
	file_digest! = |file| {
		reader = File.open_reader_with_capacity!(Path.utf8(file), 65536)?
		var $hasher = Crypto.SHA256.Hasher.empty()
		var $chunk = reader.read_up_to!(65536)?
		while !$chunk.is_empty() {
			$hasher = $hasher.write($chunk)
			$chunk = reader.read_up_to!(65536)?
		}
		Ok($hasher.finish())
	}

	## The file that is `program`, ready to start: its artifact verified now,
	## and its tree made from that artifact if it is not there. The answer is
	## the program's real path in the store; nothing is on PATH yet.
	program! : Str, Steps.Program, Origin => Try(Str, Str)
	program! = |store, program, origin| {
		if !digest(program.sha256) {
			return Err("${program.name}: ${recorded(origin)} holds no SHA-256 for it")
		}
		kept = artifact!(store, program, origin)?
		file = program_path(store, program)
		if kept == Replaced {
			# The tree stood beside bytes that were not the recorded ones.
			discard!(tree_path(store, program.sha256, program.unpack))
		}
		if regular!(file) {
			return Ok(file)
		}
		tree!(store, program)?
		if regular!(file) Ok(file) else Err("the store has no ${file} after making it; delete ${tree_path(store, program.sha256, program.unpack)} and run again")
	}

	## Put `target` on a run's PATH as `name`: a symbolic link in `bin`, so
	## that a program finds what is beside its real path.
	expose! : Str, Str, Str => Try({}, Str)
	expose! = |bin, name, target|
		Cmd.new_str("ln").args_str(["-s", target, "${bin}/${name}"]).exec_cmd!()
			.map_err(|_| "could not link ${name} to ${target} in ${bin}")
}

digest : Str -> Bool
digest = |text| text.to_utf8().len() == 64 and text.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))

recorded : Store.Origin -> Str
recorded = |origin|
	match origin {
		Lock => "Blueprint.lock"
		BuiltIn => "this blueprint"
	}

## What to do when the bytes are not the recorded ones.
advice : Store.Origin, Str -> Str
advice = |origin, name|
	match origin {
		Lock => "If the publisher replaced the file, run blueprint update ${name} and review the change"
		BuiltIn => "Set ROC to a compiler you trust, or use a blueprint release that records this one"
	}

regular! : Str => Bool
regular! = |file|
	match Path.utf8(file).type!() {
		Ok(IsFile) => True
		_ => False
	}

## Remove a file or tree. One that is not there is already removed.
discard! : Str => {}
discard! = |target| {
	_ = Path.utf8(target).delete_all!()
	{}
}

## A fresh directory in `directory`, which is created if need be. What is
## renamed out of it stays on one filesystem.
fresh! : Str => Try(Path, Str)
fresh! = |directory| {
	Path.utf8(directory).create_all!().map_err(|_| "cannot create ${directory}")?
	Env.create_temp_dir_in!(Path.utf8(directory), ".tmp-").map_err(|_| "cannot write in ${directory}")
}

## The verified artifact of a program: the one in the store when its digest
## is its name, otherwise the first URL whose bytes have that digest. `Kept`
## says the store already held it, and `Replaced` that what it held was not
## the recorded bytes.
artifact! : Str, Steps.Program, Store.Origin => Try([Kept, Fetched, Replaced], Str)
artifact! = |store, program, origin| {
	file = Store.artifact_path(store, program.sha256)
	var $outcome = Fetched
	if regular!(file) {
		match Store.file_digest!(file) {
			Ok(found) if found.to_hex() == program.sha256 => return Ok(Kept)
			_ => {
				_ = Stderr.line!("blueprint: the stored download of ${program.name} is not what its name says; fetching it again")
				discard!(file)
				$outcome = Replaced
			}
		}
	}
	var $failures = []
	for url in program.urls {
		_ = Stderr.line!("blueprint: fetching ${program.name} from ${url}")
		match fetched!(url, program, origin) {
			Ok(bytes) => {
				keep!(Paths.parent(file), file, bytes)?
				return Ok($outcome)
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
	if program.size != 0 and bytes.len() != program.size {
		return Err("${program.name} from ${url} is ${bytes.len().to_str()} bytes, not the ${program.size.to_str()} recorded in ${recorded(origin)}; nothing was unpacked")
	}
	actual = Crypto.SHA256.hash(bytes).to_hex()
	if actual != program.sha256 {
		return Err("${program.name} from ${url} has SHA-256 ${actual}, not the ${program.sha256} in ${recorded(origin)}; nothing was unpacked. ${advice(origin, program.name)}")
	}
	Ok(bytes)
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
				Err(_) => if regular!(file) Ok({}) else Err("cannot keep a download at ${file}")
			}

		Err(_) => Err("cannot write a download in ${directory}")
	}
	_ = temporary.delete_all!()
	result
}

## Make a program's tree from its verified artifact, in a fresh directory
## that is renamed into place once it is whole.
tree! : Str, Steps.Program => Try({}, Str)
tree! = |store, program| {
	artifact = Store.artifact_path(store, program.sha256)
	destination = Store.tree_path(store, program.sha256, program.unpack)
	temporary = fresh!(Paths.parent(destination))?
	make! = || {
		tree = "${Paths.portable(temporary.to_str().map_err(|_| "the store's path is not text")?)}/tree"
		Path.utf8(tree).create_dir!().map_err(|_| "cannot write in ${store}")?
		match program.unpack {
			File => {
				Path.utf8(artifact).copy!(Path.utf8("${tree}/program")).map_err(|_| "cannot copy ${program.name} within ${store}")?
				run!("chmod", ["0555", "${tree}/program"], "make ${program.name} executable")?
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
				for batch in files.chunks_of(256) {
					run!("chmod", ["a-w"].concat(batch), "make the files of ${program.name} read-only")?
				}
			}
		}
		match Path.utf8(tree).rename!(Path.utf8(destination)) {
			Ok({}) => Ok({})
			# Losing the rename to another process costs nothing: its tree
			# was made from the same bytes.
			Err(_) => if regular!(Store.program_path(store, program)) Ok({}) else Err("cannot place ${program.name} at ${destination}; delete what is there")
		}
	}
	result = make!()
	_ = temporary.delete_all!()
	result
}

## A listing `tar` prints of an archive.
listed! : List(Str), Str => Try(Str, Str)
listed! = |args, name|
	Cmd.new_str("tar").args_str(args).exec_output!()
		.map_ok(|output| output.stdout_utf8)
		.map_err(|_| "`tar ${Str.join_with(args, " ")}` could not list the archive for ${name}")

run! : Str, List(Str), Str => Try({}, Str)
run! = |program, args, purpose|
	Cmd.new_str(program).args_str(args).exec_cmd!().map_err(|_| "could not ${purpose}: `${program}` failed")

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
