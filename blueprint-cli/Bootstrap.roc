import core.Steps

## The compiler that reads a Blueprint.roc, as downloads this executable
## holds: a project has no Lock until it has been read, so the digests cannot
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
			tag: "nightly-2026-10-13-b17d287",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-13-b17d287/roc_nightly-linux_x86_64-2026-10-13-b17d287.tar.gz"],
				sha256: "3b613b155be6ea04c9a1ae4e315fb4cf911e2d0b7096708d07ef147647da578b",
				size: 73735347,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-10-13-b17d287/roc",
			},
		},
		{
			tag: "nightly-2026-10-13-b17d287",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-13-b17d287/roc_nightly-linux_arm64-2026-10-13-b17d287.tar.gz"],
				sha256: "44208d5598ec53cd23d4194bbbd63ac47e69293d5193acc318f816346b218030",
				size: 70761334,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-10-13-b17d287/roc",
			},
		},
		{
			tag: "nightly-2026-10-13-b17d287",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-13-b17d287/roc_nightly-macos_apple_silicon-2026-10-13-b17d287.tar.gz"],
				sha256: "2a3ccaa478e3ac0557c88bb880fec4381103dbd2ee586f30ac17b22d9c3be6f1",
				size: 70931823,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-10-13-b17d287/roc",
			},
		},
		{
			tag: "nightly-2026-10-13-b17d287",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-13-b17d287/roc_nightly-macos_x86_64-2026-10-13-b17d287.tar.gz"],
				sha256: "a98b60630f3772f21f22b92d3bf7a5ed6d03835c86a251455926f1a763987e22",
				size: 74732839,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-10-13-b17d287/roc",
			},
		},
		{
			tag: "nightly-2026-10-13-b17d287",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-13-b17d287/roc_nightly-windows_x86_64-2026-10-13-b17d287.zip"],
				sha256: "bccd61ff1aedd6635fb73e9f162656292a6d56aa1946d4942b99eb42e157f732",
				size: 71573917,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-10-13-b17d287/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-10-13-b17d287", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-10-13-b17d287/roc")
expect Bootstrap.compiler("nightly-2026-10-13-b17d287", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-13-b17d287/roc_nightly-linux_arm64-2026-10-13-b17d287.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("44208d5598ec53cd23d4194bbbd63ac47e69293d5193acc318f816346b218030")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
			and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
				and Bootstrap.serving([]) == Err(NotRecorded)
}
