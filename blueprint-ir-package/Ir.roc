import Sexpr
import Value

## The blueprint IR: everything a `Blueprint.roc` describes, after the
## platform has validated it. The platform writes it with `Ir.to_str`; the
## `blueprint` CLI (or any other backend) reads it back with `Ir.parse`.
##
## # Schema
##
## - `format` — `{ major, minor }` of the IR contract (see below). Required.
## - `name` — the project name. Required.
## - `requires` (Roc field `requires_`) — feature names this IR uses beyond the core contract, e.g.
##   `"extensions"` or `"raw"`. A consumer calls `Ir.unsupported_features` with
##   the features it implements and refuses (asking the user to upgrade) if
##   any are left. Features are named by the platform; the core fields below
##   never need an entry.
## - `systems` — target system strings such as `"x86_64-linux"` or
##   `"aarch64-darwin"`. Open-ended; a backend rejects ones it can't build.
## - `inputs` — named sources of packages: `{ name, url, kind }` where `kind`
##   is `Packages` (a package set, like nixpkgs), `Overlay` (applied on top of
##   the default package set) or `Flake` (an arbitrary input, only referenced
##   from `raw` values). The IR is neutral: it implies no inputs. A consumer
##   that needs a package set and finds no `Packages` input named `"nixpkgs"`
##   supplies its own default `"nixpkgs"`.
## - `shells` — dev shells: `{ name, packages }` (Roc field `packages_`); each package is
##   `{ source, path }`, where `source` names an input (e.g. `"nixpkgs"`) and
##   `path` is the attribute path, e.g. `["llvmPackages", "bintools"]`.
## - `tasks` — named commands `{ name, shell, run }` run inside a shell; `run`
##   is the argv.
## - `extensions` — typed-by-name blocks `{ kind, name, value : Value }` that a
##   backend may understand (e.g. kind `"service"`). Backends ignore kinds they
##   don't know unless `requires` says otherwise.
## - `raw` — opaque backend passthrough `{ backend, target, value : Value }`,
##   e.g. backend `"nix"`, target `"shell:default"` or `"flake"`.
##
## # Compatibility
##
## `Ir.parse` accepts any IR whose `format.major` equals `current_format.major`,
## whatever its minor (older or newer), and rejects any other major with
## `UnsupportedFormat`. Unknown fields are ignored, and every top-level field
## other than `format` and `name` may be missing (it defaults to empty).
##
## Roc keywords can't be field names, so `requires` and `packages` are
## `requires_` and `packages_` in Roc; `Sexpr` drops the trailing `_`.
##
## - Minor bump: adding an optional top-level field (it must parse when
##   missing), or a new `requires` entry. Old readers ignore the
##   field; if ignoring it would be wrong, the writer lists a feature in
##   `requires`.
## - Major bump: removing or renaming a field, changing a field's type or
##   meaning, adding a field to a nested record or a tag to a closed union
##   (e.g. input `kind`), or making a field required.
Ir := {
	format : { major : U64, minor : U64 },
	name : Str,
	requires_ : List(Str),
	systems : List(Str),
	inputs : List({ name : Str, url : Str, kind : [Packages, Overlay, Flake] }),
	shells : List({ name : Str, packages_ : List({ source : Str, path : List(Str) }) }),
	tasks : List({ name : Str, shell : Str, run : List(Str) }),
	extensions : List({ kind : Str, name : Str, value : Value }),
	raw : List({ backend : Str, target : Str, value : Value }),
}.{
	is_eq : _
	encoder_for : _

	## The IR contract version this package writes and reads.
	current_format : Format
	current_format = { major: 1, minor: 0 }

	Format : { major : U64, minor : U64 }

	## A named package source; see the schema above.
	Input : { name : Str, url : Str, kind : [Packages, Overlay, Flake] }

	## A package: the input it comes from and its attribute path.
	Package : { source : Str, path : List(Str) }

	## One dev shell and the packages it provides.
	Shell : { name : Str, packages_ : List({ source : Str, path : List(Str) }) }

	## A named command, run inside one of the shells.
	Task : { name : Str, shell : Str, run : List(Str) }

	## A typed-by-name block a backend may understand.
	Extension : { kind : Str, name : Str, value : Value }

	## Opaque data for one backend.
	Raw : { backend : Str, target : Str, value : Value }

	## An IR with the current format, the given name and nothing else.
	empty : Str -> Ir
	empty = |name| Ir.{
		format: current_format,
		name,
		requires_: [],
		systems: [],
		inputs: [],
		shells: [],
		tasks: [],
		extensions: [],
		raw: [],
	}

	## Encode as S-expression text, fields in alphabetical order.
	to_str : Ir -> Str
	to_str = |ir| Str.concat(Sexpr.to_str(ir), "\n")

	## Parse IR text. Any minor of the current major is accepted; a different
	## major is rejected before the rest of the text is interpreted.
	parse : Str -> Try(Ir, [InvalidSexpr(Str), MissingRequiredField(Str), UnsupportedFormat(Format)])
	parse = |text| {
		header : { format : Format }
		header = Sexpr.parse(text)?
		if header.format.major != current_format.major {
			return Err(UnsupportedFormat(header.format))
		}
		wire : Wire
		wire = Sexpr.parse(text)?
		Ok(
			Ir.{
				format: wire.format,
				name: wire.name,
				requires_: wire.requires_ ?? [],
				systems: wire.systems ?? [],
				inputs: wire.inputs ?? [],
				shells: wire.shells ?? [],
				tasks: wire.tasks ?? [],
				extensions: wire.extensions ?? [],
				raw: wire.raw ?? [],
			},
		)
	}

	## The features in `ir.requires_` that are not in `supported`, in order.
	unsupported_features : Ir, List(Str) -> List(Str)
	unsupported_features = |ir, supported| ir.requires_.keep_if(|feature| !supported.contains(feature))
}

## What `Ir.parse` reads: `Ir` with every field but `format` and `name`
## optional, so older and newer minors both parse.
Wire : {
	format : { major : U64, minor : U64 },
	name : Str,
	requires_ : Try(List(Str), [Missing]),
	systems : Try(List(Str), [Missing]),
	inputs : Try(List({ name : Str, url : Str, kind : [Packages, Overlay, Flake] }), [Missing]),
	shells : Try(List({ name : Str, packages_ : List({ source : Str, path : List(Str) }) }), [Missing]),
	tasks : Try(List({ name : Str, shell : Str, run : List(Str) }), [Missing]),
	extensions : Try(List({ kind : Str, name : Str, value : Value }), [Missing]),
	raw : Try(List({ backend : Str, target : Str, value : Value }), [Missing]),
}

sample : Ir
sample = Ir.{
	format: Ir.current_format,
	name: "demo",
	requires_: ["extensions", "raw"],
	systems: ["x86_64-linux", "aarch64-darwin"],
	inputs: [
		{ name: "nixpkgs", url: "github:NixOS/nixpkgs/nixos-unstable", kind: Packages },
		{ name: "roc", url: "github:roc-lang/roc-overlay", kind: Overlay },
	],
	shells: [{ name: "default", packages_: [{ source: "nixpkgs", path: ["git"] }, { source: "nixpkgs", path: ["llvmPackages", "bintools"] }] }],
	tasks: [{ name: "test", shell: "default", run: ["python3", "-c", "print(\"hi\")"] }],
	extensions: [
		{
			kind: "service",
			name: "db",
			value: Value.Attrs([
				{ name: "command", value: Value.List([Value.Str("postgres"), Value.Str("-D"), Value.Str("data")]) },
				{ name: "port", value: Value.Int(5432) },
				{ name: "env", value: Value.Attrs([{ name: "DEBUG", value: Value.Bool(True) }]) },
			]),
		},
	],
	raw: [{ backend: "nix", target: "shell:default", value: Value.Attrs([{ name: "shellHook", value: Value.Str("echo hi\n") }]) }],
}

expect Ir.parse(sample.to_str()) == Ok(sample)

expect Ir.parse(Ir.empty("x").to_str()) == Ok(Ir.empty("x"))

expect sample.to_str().contains("(systems (\"x86_64-linux\" \"aarch64-darwin\"))")

# Same major, any minor: accepted.
expect {
	newer = Str.replace_each(sample.to_str(), "(minor 0)", "(minor 7)")
	match Ir.parse(newer) {
		Ok(ir) => ir.format == { major: 1, minor: 7 }
		Err(_) => False
	}
}

# Different major: rejected, even if the rest wouldn't parse.
expect Ir.parse(Str.replace_each(sample.to_str(), "(major 1)", "(major 2)")) == Err(UnsupportedFormat({ major: 2, minor: 0 }))
expect Ir.parse("((format ((major 0) (minor 3))) (shells 42))") == Err(UnsupportedFormat({ major: 0, minor: 3 }))

# Unknown fields, at the top level and nested, are ignored.
expect {
	text = "((future (anything (Tag 1) \"x\")) (format ((minor 9) (major 1))) (name \"x\") (shells (((name \"s\") (packages ()) (colour \"red\")))))"
	parsed = Ir.parse(text)
	match parsed {
		Ok(ir) => ir.format == { major: 1, minor: 9 } and ir.name == "x" and ir.shells == [{ name: "s", packages_: [] }] and ir.tasks == []
		Err(_) => False
	}
}

# Missing optional fields default to empty.
expect Ir.parse("((format ((major 1) (minor 0))) (name \"x\"))") == Ok(Ir.empty("x"))

# `format` and `name` are required.
expect Ir.parse("((format ((major 1) (minor 0))))").is_err()
expect Ir.parse("((name \"x\"))").is_err()

expect sample.unsupported_features(["raw"]) == ["extensions"]
expect sample.unsupported_features(["raw", "extensions", "other"]) == []
