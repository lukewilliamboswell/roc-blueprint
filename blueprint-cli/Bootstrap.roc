import core.Steps

## The compiler that reads a Blueprint.roc, as archives this executable
## embeds: a project has no Lock until it has been read, so the digests cannot
## come from one. They are data and nothing else: no rule here derives a URL
## or a name. Each entry is what the release of roc-lang/nightlies with that
## tag reports for the archive, and is the same download a project declares
## with `Recipes.roc_nightly` of the tag, so the store holds it once.
## scripts/test.roc requires an entry, for every System blueprint runs on, of
## the nightly in blueprint-cli/compiler-version.
Bootstrap := [].{
	Compiler : { tag : Str, system : Str, program : Steps.Program }

	compilers : List(Compiler)
	compilers = [
		{
			tag: "nightly-2026-11-23-b5c77fc",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-23-b5c77fc/roc_nightly-linux_x86_64-2026-11-23-b5c77fc.tar.gz"],
				sha256: "05e2cebf97100af3f86420f1ccf5008cf3ba09f0c783b327e90eca7e5c54919f",
				size: 95026366,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-11-23-b5c77fc/roc",
			},
		},
		{
			tag: "nightly-2026-11-23-b5c77fc",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-23-b5c77fc/roc_nightly-linux_arm64-2026-11-23-b5c77fc.tar.gz"],
				sha256: "d47e72b511875985db0dfaae2aa05a59f872e1f57184c7445ee8a03de25f3008",
				size: 91151745,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-11-23-b5c77fc/roc",
			},
		},
		{
			tag: "nightly-2026-11-23-b5c77fc",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-23-b5c77fc/roc_nightly-macos_apple_silicon-2026-11-23-b5c77fc.tar.gz"],
				sha256: "80af103bc17b5fb83da8ddc25b300ea47657ddf6c62a542e43ecefcbc5f91a6e",
				size: 92632174,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-11-23-b5c77fc/roc",
			},
		},
		{
			tag: "nightly-2026-11-23-b5c77fc",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-23-b5c77fc/roc_nightly-macos_x86_64-2026-11-23-b5c77fc.tar.gz"],
				sha256: "a49a39e52daccc668de9d68b3769c7dd98a8cf3bc5cfab9e907892a38da36f8e",
				size: 98157402,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-11-23-b5c77fc/roc",
			},
		},
		{
			tag: "nightly-2026-11-23-b5c77fc",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-23-b5c77fc/roc_nightly-windows_x86_64-2026-11-23-b5c77fc.zip"],
				sha256: "8461e674a88c5cc177fcdb2fa0d7a65145d0eb5a11dee67c345738477396a97d",
				size: 92947330,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-11-23-b5c77fc/roc.exe",
			},
		},
	]

	## The download of one release for one System.
	compiler : Str, Str -> Try(Steps.Program, [NotRecorded])
	compiler = |tag, system|
		compilers.find_first(|entry| entry.tag == tag and entry.system == system)
			.map_ok(|entry| entry.program)
			.map_err(|_| NotRecorded)

	## The compiler download that is served from the first of `urls`: what a
	## project's program is when it is the same download as a compiler here.
	## An update that finds its bytes in the store, with the digest recorded
	## here, hashes those and does not fetch them a second time.
	serving : List(Str) -> Try(Steps.Program, [NotRecorded])
	serving = |urls|
		match urls.first() {
			Ok(url) =>
				compilers.find_first(|entry| entry.program.urls.first() == Ok(url))
					.map_ok(|entry| entry.program)
					.map_err(|_| NotRecorded)

			Err(_) => Err(NotRecorded)
		}
}

# One entry for each System of a release, each a whole digest and a length.
expect Bootstrap.compilers.all(|entry| Bootstrap.compilers.keep_if(|other| other.tag == entry.tag and other.system == entry.system).len() == 1)
expect Bootstrap.compilers.all(|entry| entry.program.sha256.to_utf8().len() == 64 and entry.program.sha256.to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'f')) and entry.program.size > 0)
expect Bootstrap.compilers.all(|entry| entry.program.urls.all(|url| url.starts_with("https://github.com/roc-lang/nightlies/releases/download/${entry.tag}/")))

expect Bootstrap.compiler("nightly-2026-11-23-b5c77fc", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-11-23-b5c77fc/roc")
expect Bootstrap.compiler("nightly-2026-11-23-b5c77fc", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-23-b5c77fc/roc_nightly-linux_arm64-2026-11-23-b5c77fc.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("d47e72b511875985db0dfaae2aa05a59f872e1f57184c7445ee8a03de25f3008")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
		and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
		and Bootstrap.serving([]) == Err(NotRecorded)
}
