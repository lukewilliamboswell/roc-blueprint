import Sexpr

## The blueprint IR: everything a `Blueprint.roc` describes, after the
## platform has validated it. The platform encodes it with `Ir.to_str` and
## the `blueprint` CLI reads it back with `Ir.parse`.
Ir := {
	version : U64,
	name : Str,
	systems : List([Aarch64Darwin, Aarch64Linux, X86_64Darwin, X86_64Linux]),
	overlays : List(Str),
	shells : List({ name : Str, tools : List(List(Str)) }),
	tasks : List({ name : Str, shell : Str, run : List(Str) }),
}.{
	is_eq : _
	encoder_for : _
	parser_for : _

	## Bumped whenever the IR changes shape.
	current_version : U64
	current_version = 2

	## One dev shell: its name, and nixpkgs attribute paths split on `.`.
	Shell : { name : Str, tools : List(List(Str)) }

	## A named command, run inside one of the shells.
	Task : { name : Str, shell : Str, run : List(Str) }

	System : [Aarch64Darwin, Aarch64Linux, X86_64Darwin, X86_64Linux]

	to_str : Ir -> Str
	to_str = |ir| Str.concat(Sexpr.to_str(ir), "\n")

	## Parse IR text, rejecting any version this package doesn't understand.
	parse : Str -> Try(Ir, [InvalidSexpr(Str), MissingRequiredField(Str), UnsupportedVersion(U64)])
	parse = |text| {
		ir : Ir
		ir = Sexpr.parse(text)?
		if ir.version == current_version {
			Ok(ir)
		} else {
			Err(UnsupportedVersion(ir.version))
		}
	}

	## The nix system string, e.g. "x86_64-linux".
	system_str : System -> Str
	system_str = |system|
		match system {
			Aarch64Darwin => "aarch64-darwin"
			Aarch64Linux => "aarch64-linux"
			X86_64Darwin => "x86_64-darwin"
			X86_64Linux => "x86_64-linux"
		}
}

sample : Ir
sample = Ir.{
	version: 2,
	name: "demo",
	systems: [X86_64Linux, Aarch64Darwin],
	overlays: ["github:roc-lang/roc-overlay"],
	shells: [{ name: "default", tools: [["git"], ["llvmPackages", "bintools"]] }],
	tasks: [{ name: "test", shell: "default", run: ["python3", "-c", "print(\"hi\")"] }],
}

expect Ir.parse(sample.to_str()) == Ok(sample)

expect {
	text = sample.to_str()
	text.contains("(systems (X86_64Linux Aarch64Darwin))")
}

expect Ir.parse(Str.replace_each(sample.to_str(), "(version 2)", "(version 9)")) == Err(UnsupportedVersion(9))
