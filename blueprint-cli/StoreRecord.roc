import core.Sexpr

## The record the store keeps beside a tree (see Store): what the tree held
## when it was made, as S-expression text. It needs no effects, so the tests
## that rewrite a record write it with these same functions.
StoreRecord := [].{

	## A tree's core `Tree` digest, which covers its directories, files and
	## executable bits, and where each symbolic link in it leads, which that
	## digest cannot say. A link's target is a path within the tree, or what
	## it reaches outside it, or empty when it reaches nothing.
	Tree : { format : U64, digest : Str, links : List({ path : Str, target : Str }) }

	format : U64
	format = 1

	text : Tree -> Str
	text = |record| Str.concat(Sexpr.to_str(record), "\n")

	read : Str -> Try(Tree, [InvalidSexpr(Str), MissingRequiredField(Str), UnsupportedFormat(U64)])
	read = |source| {
		record : Tree
		record = Sexpr.parse(source)?
		if (record.format == format) Ok(record) else Err(UnsupportedFormat(record.format))
	}
}

sha : Str
sha = "893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f"

# A record reads back as itself. One of another format, or that is not
# S-expression text, is not a record.
expect {
	record = { format: StoreRecord.format, digest: "sha256:${sha}", links: [{ path: "roc/bin", target: "roc/roc" }] }
	StoreRecord.read(StoreRecord.text(record)) == Ok(record)
}
expect StoreRecord.text({ format: 1, digest: "sha256:${sha}", links: [] }) == "(\n\t(digest \"sha256:${sha}\")\n\t(format 1)\n\t(links ()))\n"
expect StoreRecord.read("((format 2) (digest \"sha256:00\") (links ()))") == Err(UnsupportedFormat(2))
expect StoreRecord.read("{\"format\":1,\"digest\":\"sha256:00\",\"links\":[]}").is_err()
