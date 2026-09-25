import Project

## Blueprint's content digest for a directory tree, independent of any
## provider's archive format. The Core computes it from its own reads, so
## verifying content never needs a provider's tools.
##
## Callers hash each file's bytes (in chunks, with `Crypto.SHA256.Hasher`)
## and pass one `Entry` per file and directory below the root. The digest is
## the SHA-256 of a canonical manifest: a version line, then one line per
## entry in UTF-8 byte order of its path:
##
##     blueprint-tree-v1
##     D	<path>
##     F	<x|->	<sha256 hex>	<path>
##
## Only the kind, the path, the executable bit and file contents count;
## timestamps, owners and other modes never do. Symlinks and special files
## are not representable.
Tree :: [].{
	Entry : { path : Str, kind : [Dir, File({ executable : Bool, digest : Crypto.SHA256.Digest })] }

	## `sha256:<hex>` for the tree, or why its entries are not a valid tree.
	digest : List(Entry) -> Try(Str, Str)
	digest = |entries| {
		sorted = entries.sort_with(|a, b| Project.bytewise(a.path, b.path))
		var $folded = []
		var $hasher = Crypto.SHA256.Hasher.empty().write("blueprint-tree-v1\n".to_utf8())
		for entry in sorted {
			check_path(entry.path)?
			folded = entry.path.to_utf8().map(|b| if b >= 'A' and b <= 'Z' b + 32 else b)
			if $folded.contains(folded) {
				return Err("tree has paths that differ only by case: ${entry.path}")
			}
			$folded = $folded.append(folded)
			line = match entry.kind {
				Dir => "D\t${entry.path}\n"
				File({ executable, digest: content }) => {
					x = if executable "x" else "-"
					"F\t${x}\t${content.to_hex()}\t${entry.path}\n"
				}
			}
			$hasher = $hasher.write(line.to_utf8())
		}
		Ok("sha256:${$hasher.finish().to_hex()}")
	}

	## A relative `/`-separated path without empty, `.` or `..` segments or
	## control characters, so every manifest line is unambiguous.
	check_path : Str -> Try({}, Str)
	check_path = |path| {
		bytes = path.to_utf8()
		if bytes.is_empty() or bytes.any(|b| b < 32 or b == 127) {
			return Err("invalid tree path: ${path}")
		}
		for segment in path.split_on("/") {
			if segment == "" or segment == "." or segment == ".." {
				return Err("invalid tree path: ${path}")
			}
		}
		Ok({})
	}
}

file : Str, Bool, Str -> Tree.Entry
file = |path, executable, contents| { path, kind: File({ executable, digest: Crypto.SHA256.hash(contents.to_utf8()) }) }

# Pinned vectors: changing the manifest format must be deliberate.
expect Tree.digest([]) == Ok("sha256:${Crypto.SHA256.hash("blueprint-tree-v1\n".to_utf8()).to_hex()}")
expect {
	manifest = "blueprint-tree-v1\nD\tbin\nF\tx\t${Crypto.SHA256.hash("hi\n".to_utf8()).to_hex()}\tbin/tool\n"
	Tree.digest([file("bin/tool", True, "hi\n"), { path: "bin", kind: Dir }])
		== Ok("sha256:${Crypto.SHA256.hash(manifest.to_utf8()).to_hex()}")
}

# Order of entries never matters; content, names and the executable bit do.
expect {
	a = Tree.digest([file("a", False, "1"), file("b", False, "2")])
	a == Tree.digest([file("b", False, "2"), file("a", False, "1")])
		and a != Tree.digest([file("a", False, "1"), file("b", False, "3")])
			and a != Tree.digest([file("a", True, "1"), file("b", False, "2")])
				and a != Tree.digest([file("a", False, "1"), file("c", False, "2")])
}

# Chunked hashing gives the same file digest as hashing the whole file.
expect {
	chunked = Crypto.SHA256.Hasher.empty().write("line one\n".to_utf8()).write("line two".to_utf8()).finish()
	chunked == Crypto.SHA256.hash("line one\nline two".to_utf8())
}

expect ["", "/abs", "a//b", "./a", "a/../b", "a\nb", "a\tb"]
	.all(|p| Tree.digest([file(p, False, "")]).is_err())
expect Tree.digest([file("README", False, ""), file("readme", False, "")]).is_err()
