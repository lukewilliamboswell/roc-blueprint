app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst" }

import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr

## Real builds with exact outputs, filtered trees and immutable inputs.
##
##   roc-stable build.roc -- library
##   roc-stable build.roc -- bundle
##   roc-stable build.roc -- app ARGS...
main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	result = match args.map(OsStr.display) {
		["library"] => library!()
		["bundle"] => bundle!()
		["app", .. as rest] => app!(rest)
		_ => Err(Failed("unknown fixture build"))
	}
	match result {
		Ok({}) => Ok({})
		Err(Failed(message)) => {
			_ = Stderr.line!("fixture build: ${message}")
			Err(Exit(1))
		}
		Err(other) => {
			_ = Stderr.line!("fixture build: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

require : Bool, Str -> Try({}, [Failed(Str)])
require = |holds, message| if holds Ok({}) else Err(Failed(message))

library! : () => Try({}, _)
library! = || {
	# The environment declares Roc alone, so nothing here can start a shell.
	# This script does see more than the build was given: the Roc compiler's
	# package adds coreutils and a C compiler to the PATH of what it runs. The
	# suite checks the build's own PATH with commands that are not Roc.
	require(!Cmd.check_available!("sh") and !Cmd.check_available!("bash"), "an undeclared shell is on PATH: ${Env.var_str!("PATH") ?? ""}")?
	require(Path.list!(Path.from_os_str(Env.var!("BLUEPRINT_INPUTS")?))?.is_empty(), "undeclared inputs are present")?
	require(Path.list!(Path.from_os_str(Env.var!("BLUEPRINT_ARTIFACTS")?))?.is_empty(), "undeclared artifacts are present")?
	Path.create_dir!("dist")?
	Path.write_bytes!("dist/library", library_payload!()?)?
	Ok({})
}

## The current project bytes a library is made of.
library_payload! : () => Try(List(U8), _)
library_payload! = || {
	task = if Path.exists!("task-produced.txt")? Path.read_bytes!("task-produced.txt")? else "<absent>".to_utf8()
	Ok("library".to_utf8().append(0).concat(Path.read_bytes!("untracked.txt")?).append('|').concat(task))
}

## What `bundle` and `app` share: the declared inputs are exactly those named,
## read-only, and outside the writable project copy, which holds no excluded
## entry. Returns the payload and the project's files.
shared! : List(Str) => Try({ payload : List(U8), files : List(List(U8)), artifacts : Path }, _)
shared! = |needed| {
	work = Env.cwd!()?
	sources = Path.canonicalize!(Path.from_os_str(Env.var!("BLUEPRINT_INPUTS")?))?
	artifacts = Path.canonicalize!(Path.from_os_str(Env.var!("BLUEPRINT_ARTIFACTS")?))?
	require(!inside(sources, work) and !inside(artifacts, work), "inputs lie inside the writable project copy")?
	require(names!(sources)? == ["assets"], "sources are not exactly the declared Inputs")?
	require(names!(artifacts)? == needed, "artifacts are not exactly the declared Needs")?
	asset = Path.join(sources, "assets/message.txt")
	# Exactly Output, not an enclosing directory. The farm entry is a link.
	library = Path.canonicalize!(Path.join(artifacts, "library"))?
	require(Path.is_file!(library)?, "the library artifact is not a file")?
	deny_write!(asset)?
	deny_create!(Path.join(sources, "assets"))?
	deny_write!(library)?
	entries = walk!(work, [])?
	forbidden = [".git", ".hg", ".svn", ".jj", "assets", "packages", "work", "generated", "authority.lock", "INJECTED"].map(|name| name.to_utf8())
	require(!entries.any(|entry| forbidden.contains(basename(entry.name))), "an excluded entry reached the build")?
	payload = Path.read_bytes!(library)?.append('|').concat(Path.read_bytes!(asset)?)
	Ok({ payload, files: entries.keep_if(|entry| !entry.directory).map(|entry| entry.name), artifacts })
}

bundle! : () => Try({}, _)
bundle! = || {
	{ payload, files, .. } = shared!(["library"])?
	var $lines = []
	for name in files {
		file = Path.unix_bytes(name)
		executable = if Path.is_executable!(file)? "x" else "-"
		$lines = $lines.append("${hex(name)} ${executable} ${hex(Path.read_bytes!(file)?)}\n")
	}
	Path.create_all!("dist/bundle")?
	Path.write_bytes!("dist/bundle/payload", payload)?
	# One line per project file, ordered by name: the name and the bytes in
	# hexadecimal, and whether the file is executable.
	Path.write_utf8!("dist/bundle/manifest", Str.join_with($lines.sort_with(|left, right| order(left.to_utf8(), right.to_utf8())), ""))?
	Path.write_utf8!("dist/bundle/proof", "source+dependency readonly\n")?
	Ok({})
}

app! : List(Str) => Try({}, _)
app! = |argv| {
	{ payload, artifacts, .. } = shared!(["bundle", "library"])?
	bundle = Path.canonicalize!(Path.join(artifacts, "bundle"))?
	require(Path.is_dir!(bundle)?, "the bundle artifact is not a directory")?
	require(names!(bundle)? == ["manifest", "payload", "proof"], "the bundle artifact holds something else")?
	deny_write!(Path.join(bundle, "payload"))?
	deny_create!(bundle)?
	require(Path.read_bytes!(Path.join(bundle, "payload"))? == payload, "the bundle was built from other bytes")?
	Path.create_dir!("dist")?
	Path.write_bytes!("dist/app", "app".to_utf8().append(0).concat(payload).append('|').concat(Json.to_str(argv).to_utf8()))?
	Ok({})
}

## Attempt an actual write; inspecting mode bits alone is not proof. basic-cli
## cannot append, so this would replace the file; it must be refused instead.
deny_write! : Path => Try({}, _)
deny_write! = |file| {
	original = Path.read_bytes!(file)?
	match Path.write_bytes!(file, original.concat("unexpected-write".to_utf8())) {
		Ok({}) => Err(Failed("input was writable: ${Path.display(file)}"))
		Err(PathErr(PermissionDenied, _)) => require(Path.read_bytes!(file)? == original, "a refused write changed ${Path.display(file)}")
		Err(other) => Err(Failed("writing ${Path.display(file)} failed for another reason: ${Str.inspect(other)}"))
	}
}

## Read-only inputs must also reject adding new children.
deny_create! : Path => Try({}, _)
deny_create! = |directory|
	match Path.write_bytes!(Path.join(directory, "forbidden-write"), "bad".to_utf8()) {
		Ok({}) => Err(Failed("input directory was writable: ${Path.display(directory)}"))
		Err(PathErr(PermissionDenied, _)) => Ok({})
		Err(other) => Err(Failed("creating a file in ${Path.display(directory)} failed for another reason: ${Str.inspect(other)}"))
	}

## Every entry beneath a directory, by raw relative name: a name need not be UTF-8.
walk! : Path, List(U8) => Try(List({ name : List(U8), directory : Bool }), _)
walk! = |directory, prefix| {
	var $found = []
	for entry in Path.list!(directory)? {
		base = basename(Path.to_os_str(entry).to_bytes())
		name = if prefix.is_empty() base else prefix.append('/').concat(base)
		if Path.is_dir!(entry)? {
			$found = $found.append({ name, directory: Bool.True }).concat(walk!(entry, name)?)
		} else {
			$found = $found.append({ name, directory: Bool.False })
		}
	}
	Ok($found)
}

## The sorted entry names of a directory.
names! : Path => Try(List(Str), _)
names! = |directory| {
	found = Path.list!(directory)?.map(|entry| Str.from_utf8_lossy(basename(Path.to_os_str(entry).to_bytes())))
	Ok(found.sort_with(|left, right| order(left.to_utf8(), right.to_utf8())))
}

basename : List(U8) -> List(U8)
basename = |bytes| bytes.fold([], |name, byte| if byte == '/' [] else name.append(byte))

## Whether `inner` is `outer` or lies beneath it.
inside : Path, Path -> Bool
inside = |inner, outer| {
	base = Path.to_os_str(outer).to_bytes()
	candidate = Path.to_os_str(inner).to_bytes()
	candidate == base or candidate.take_first(base.len() + 1) == base.append('/')
}

order : List(U8), List(U8) -> [Before, Same, After]
order = |left, right|
	match (left, right) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([first, .. as rest], [other, .. as others]) => if first < other Before else if first > other After else order(rest, others)
	}

hex : List(U8) -> Str
hex = |bytes| Str.from_utf8_lossy(bytes.fold([], |out, byte| out.append(digit(byte // 16)).append(digit(byte % 16))))

digit : U8 -> U8
digit = |nibble| if nibble < 10 '0' + nibble else 'a' + (nibble - 10)

expect hex([0, 255, 16, 'a']) == "00ff1061"
expect basename("/project/nested/file".to_utf8()) == "file".to_utf8()
expect ["b", "a", "", "aa"].sort_with(|left, right| order(left.to_utf8(), right.to_utf8())) == ["", "a", "aa", "b"]
expect inside(Path.utf8("/build/work/dist"), Path.utf8("/build/work")) and !inside(Path.utf8("/build/work-2"), Path.utf8("/build/work"))
