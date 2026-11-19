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
			tag: "nightly-2026-11-18-a520eed",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-18-a520eed/roc_nightly-linux_x86_64-2026-11-18-a520eed.tar.gz"],
				sha256: "d9395495f9dd07c39629c33f156f7fee68e8d22f8a764522e5cdd1cc30879b51",
				size: 95010092,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-11-18-a520eed/roc",
			},
		},
		{
			tag: "nightly-2026-11-18-a520eed",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-18-a520eed/roc_nightly-linux_arm64-2026-11-18-a520eed.tar.gz"],
				sha256: "16fb2bd5ace8cd78e3485436398064d2cbe5e28d3c84e155b2460d32101722c3",
				size: 91178961,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-11-18-a520eed/roc",
			},
		},
		{
			tag: "nightly-2026-11-18-a520eed",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-18-a520eed/roc_nightly-macos_apple_silicon-2026-11-18-a520eed.tar.gz"],
				sha256: "3b9ba3cc7357e47916f03689979be6c35c1986a1fd5a54bf0d06ea609fe0648d",
				size: 91000550,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-11-18-a520eed/roc",
			},
		},
		{
			tag: "nightly-2026-11-18-a520eed",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-18-a520eed/roc_nightly-macos_x86_64-2026-11-18-a520eed.tar.gz"],
				sha256: "af59b7611d53b97e0f95d46035de192eb615e589f5dd06d7048718be57b5358b",
				size: 95780566,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-11-18-a520eed/roc",
			},
		},
		{
			tag: "nightly-2026-11-18-a520eed",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-18-a520eed/roc_nightly-windows_x86_64-2026-11-18-a520eed.zip"],
				sha256: "3044248465e2cd72fd565643664d9da17decc27dc885a600b613d793aec20d16",
				size: 92976908,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-11-18-a520eed/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-11-18-a520eed", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-11-18-a520eed/roc")
expect Bootstrap.compiler("nightly-2026-11-18-a520eed", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-18-a520eed/roc_nightly-linux_arm64-2026-11-18-a520eed.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("16fb2bd5ace8cd78e3485436398064d2cbe5e28d3c84e155b2460d32101722c3")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
		and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
		and Bootstrap.serving([]) == Err(NotRecorded)
}
