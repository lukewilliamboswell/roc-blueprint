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
			tag: "nightly-2026-10-21-5349569",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-21-5349569/roc_nightly-linux_x86_64-2026-10-21-5349569.tar.gz"],
				sha256: "70346ac60dd0b0507881447c5b47aed799fd1bea01c50bac56f82ed96897f4df",
				size: 72460515,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-10-21-5349569/roc",
			},
		},
		{
			tag: "nightly-2026-10-21-5349569",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-21-5349569/roc_nightly-linux_arm64-2026-10-21-5349569.tar.gz"],
				sha256: "cb6cbe82e45ba284d5b01910e8e91a978701ffed3c2baf2c9a88baa4adc369f5",
				size: 69304823,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-10-21-5349569/roc",
			},
		},
		{
			tag: "nightly-2026-10-21-5349569",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-21-5349569/roc_nightly-macos_apple_silicon-2026-10-21-5349569.tar.gz"],
				sha256: "a8a81b5436c69eb5bf14ddc48bd9f0ef71326fd485340a4a1a7a683db442e5a6",
				size: 69461382,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-10-21-5349569/roc",
			},
		},
		{
			tag: "nightly-2026-10-21-5349569",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-21-5349569/roc_nightly-macos_x86_64-2026-10-21-5349569.tar.gz"],
				sha256: "31b1c15f5627a7144e66c26695bd3fd11c1dac2f619c256398f9134c7cc9bec6",
				size: 73451421,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-10-21-5349569/roc",
			},
		},
		{
			tag: "nightly-2026-10-21-5349569",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-21-5349569/roc_nightly-windows_x86_64-2026-10-21-5349569.zip"],
				sha256: "105026125c36b57b17201380c7d15dafbfd9ce663767d52989e11ffd53d2bcf7",
				size: 70319525,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-10-21-5349569/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-10-21-5349569", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-10-21-5349569/roc")
expect Bootstrap.compiler("nightly-2026-10-21-5349569", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-21-5349569/roc_nightly-linux_arm64-2026-10-21-5349569.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("cb6cbe82e45ba284d5b01910e8e91a978701ffed3c2baf2c9a88baa4adc369f5")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
		and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
		and Bootstrap.serving([]) == Err(NotRecorded)
}
