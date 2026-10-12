import Config

## Recipes for programs many projects fetch. A recipe is what `Fetch` takes: a
## function from a System, such as "x86_64-linux", to where the program is
## downloaded from there. It only answers; nothing is fetched until
## `blueprint` runs, and `Blueprint.lock` holds the digest of each download.
##
## ```roc
## Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-04-130536d")),
## ```
##
## A project writes its own the same way, in its `Blueprint.roc` or in a
## module beside it:
##
## ```roc
## Fetch("tool", |system| File("https://example.org/releases/1.0/tool-${system}")),
## ```
Recipes :: [].{

	## The Roc compiler of one release of
	## [roc-lang/nightlies](https://github.com/roc-lang/nightlies/releases),
	## named by its tag, as in `nightly-2026-10-04-130536d`. The archive is
	## kept whole: on macOS `roc` links with the `darwin` directory beside it.
	## A tag of another shape is `Invalid`, on every System; a System the
	## nightlies are not built for is `Unavailable`.
	roc_nightly : Str -> (Str -> Config.Download)
	roc_nightly = |tag|
		|system| {
			if !nightly_tag(tag) {
				return Invalid("\"${tag}\" is not a Roc nightly tag; expected nightly-YYYY-MM-DD-<commit>")
			}
			{ build, extension, program } = match system {
				"x86_64-linux" => { build: "linux_x86_64", extension: ".tar.gz", program: "roc" }
				"aarch64-linux" => { build: "linux_arm64", extension: ".tar.gz", program: "roc" }
				"aarch64-darwin" => { build: "macos_apple_silicon", extension: ".tar.gz", program: "roc" }
				"x86_64-darwin" => { build: "macos_x86_64", extension: ".tar.gz", program: "roc" }
				"x86_64-windows" => { build: "windows_x86_64", extension: ".zip", program: "roc.exe" }
				_ => return Unavailable
			}
			top = "roc_nightly-${build}-${tag.drop_prefix("nightly-")}"
			Archive(
				"https://github.com/roc-lang/nightlies/releases/download/${tag}/${top}${extension}",
				if extension == ".zip" Zip else TarGz,
				"${top}/${program}",
			)
		}

	## `nightly-YYYY-MM-DD-<commit>`, as roc-lang/nightlies names a release:
	## the commit is 7 to 40 lowercase hex digits.
	nightly_tag : Str -> Bool
	nightly_tag = |tag| {
		digits = |part, count| part.to_utf8().len() == count and part.to_utf8().all(|b| b >= '0' and b <= '9')
		match tag.split_on("-") {
			["nightly", year, month, day, commit] =>
				digits(year, 4) and digits(month, 2) and digits(day, 2)
					and commit.to_utf8().len() >= 7 and commit.to_utf8().len() <= 40
						and commit.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))

			_ => False
		}
	}
}

october : Str -> Config.Download
october = Recipes.roc_nightly("nightly-2026-10-04-130536d")

# Each System's asset and the compiler inside it, as the release names them.
expect october("x86_64-linux") == Archive("https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_x86_64-2026-10-04-130536d.tar.gz", TarGz, "roc_nightly-linux_x86_64-2026-10-04-130536d/roc")
expect october("aarch64-linux") == Archive("https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_arm64-2026-10-04-130536d.tar.gz", TarGz, "roc_nightly-linux_arm64-2026-10-04-130536d/roc")
expect october("aarch64-darwin") == Archive("https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-macos_apple_silicon-2026-10-04-130536d.tar.gz", TarGz, "roc_nightly-macos_apple_silicon-2026-10-04-130536d/roc")
expect october("x86_64-darwin") == Archive("https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-macos_x86_64-2026-10-04-130536d.tar.gz", TarGz, "roc_nightly-macos_x86_64-2026-10-04-130536d/roc")
expect october("x86_64-windows") == Archive("https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-windows_x86_64-2026-10-04-130536d.zip", Zip, "roc_nightly-windows_x86_64-2026-10-04-130536d/roc.exe")

# No nightly is built for any other System, and nothing is guessed for one.
expect ["aarch64-windows", "riscv64-linux", "x86_64-freebsd", "linux", ""].all(|system| october(system) == Unavailable)

# A tag of another shape is said to be one, whatever the System, and never
# becomes part of a URL.
expect
	["nightly", "0.1.0", "nightly-2026-10-4-130536d", "nightly-2026-10-04-13053", "nightly-2026-10-04-130536D", "nightly-2026-10-04-130536d/..", "nightly-2026-10-04-130536d-extra", "nightly-latest", "rocpkgs.nightly-2026-10-04-130536d", ""].all(
		|tag| ["x86_64-linux", "x86_64-windows", "riscv64-linux"].all(
			|system| Recipes.roc_nightly(tag)(system) == Invalid("\"${tag}\" is not a Roc nightly tag; expected nightly-YYYY-MM-DD-<commit>"),
		),
	)

# A full commit hash is a tag too.
expect Recipes.nightly_tag("nightly-2026-10-04-130536d0123456789abcdef0123456789abcdef0") and !Recipes.nightly_tag("nightly-2026-10-04-130536d0123456789abcdef0123456789abcdef01")
