## A system such as "x86_64-linux" or "aarch64-darwin", checked at compile
## time: `<arch>-<os>`, of an architecture and an operating system Blueprint
## knows. A quoted system is checked wherever one is written, including in the
## patterns of a `match` and on either side of `==`, so a misspelt one is an
## error where it stands and never a branch that silently matches nothing.
System :: { name : Str }.{

	## The architectures a system may name: those `blueprint` runs on and
	## those a package provider commonly builds for besides.
	architectures : List(Str)
	architectures = ["x86_64", "aarch64", "riscv64", "i686", "armv7l", "powerpc64le"]

	## The operating systems a system may name: those `blueprint` runs on,
	## Windows, which a program may be fetched for, and FreeBSD.
	operating_systems : List(Str)
	operating_systems = ["linux", "darwin", "windows", "freebsd"]

	is_eq : _

	from_quote : Str -> Try(System, [BadQuotedBytes(Str)])
	from_quote = |raw|
		match raw.split_on("-") {
			[arch, os] =>
				if !architectures.contains(arch) {
					Err(BadQuotedBytes("\"${raw}\" is not a system: \"${arch}\" is not an architecture Blueprint knows (${Str.join_with(architectures, ", ")})"))
				} else if !operating_systems.contains(os) {
					Err(BadQuotedBytes("\"${raw}\" is not a system: \"${os}\" is not an operating system Blueprint knows (${Str.join_with(operating_systems, ", ")})"))
				} else {
					Ok(System.{ name: raw })
				}

			_ => Err(BadQuotedBytes("\"${raw}\" is not a system; expected <arch>-<os> such as \"x86_64-linux\" or \"aarch64-darwin\""))
		}

	## The system as text, for a URL or a file name: `${system.to_str()}`.
	to_str : System -> Str
	to_str = |value| value.name
}

checked : Str -> Try(Str, [BadQuotedBytes(Str)])
checked = |raw| System.from_quote(raw).map_ok(System.to_str)

# Every architecture with every operating system is a system, as written.
expect System.architectures.all(|arch| System.operating_systems.all(|os| checked("${arch}-${os}") == Ok("${arch}-${os}")))

# A part that is not known is named, with what is.
expect checked("x86_64-linx") == Err(BadQuotedBytes("\"x86_64-linx\" is not a system: \"linx\" is not an operating system Blueprint knows (linux, darwin, windows, freebsd)"))
expect checked("x86-linux") == Err(BadQuotedBytes("\"x86-linux\" is not a system: \"x86\" is not an architecture Blueprint knows (x86_64, aarch64, riscv64, i686, armv7l, powerpc64le)"))
expect checked("arm64-darwin").is_err() and checked("x86_64-macos").is_err() and checked("X86_64-linux").is_err()

# Anything that is not two parts is not a system at all.
expect ["linux", "x86_64-unknown-linux", "x86_64-", "-linux", "", "x86_64 linux"].all(|raw| checked(raw).is_err())
expect checked("linux") == Err(BadQuotedBytes("\"linux\" is not a system; expected <arch>-<os> such as \"x86_64-linux\" or \"aarch64-darwin\""))

# A quoted system is one, in a pattern and beside `==`.
expect {
	linux : System
	linux = "x86_64-linux"
	named = |system|
		match system {
			"x86_64-linux" => "linux"
			"aarch64-darwin" => "macos"
			_ => "other"
		}
	named(linux) == "linux" and linux == "x86_64-linux" and linux != "aarch64-linux" and named("riscv64-freebsd") == "other"
}
