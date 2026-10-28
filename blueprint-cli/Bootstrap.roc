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
			tag: "nightly-2026-10-27-de79a0f",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-27-de79a0f/roc_nightly-linux_x86_64-2026-10-27-de79a0f.tar.gz"],
				sha256: "1efa0bf74d93964c270e60761ed6148f2e132c3adfcc5361149b518ef8488649",
				size: 73792574,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-10-27-de79a0f/roc",
			},
		},
		{
			tag: "nightly-2026-10-27-de79a0f",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-27-de79a0f/roc_nightly-linux_arm64-2026-10-27-de79a0f.tar.gz"],
				sha256: "99d3fe58a7995e61a672a8b19ff82c6f9edfa5b1d099f1bccf8418121ebef62c",
				size: 70585724,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-10-27-de79a0f/roc",
			},
		},
		{
			tag: "nightly-2026-10-27-de79a0f",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-27-de79a0f/roc_nightly-macos_apple_silicon-2026-10-27-de79a0f.tar.gz"],
				sha256: "7dee228e7024472b240401fb669f30a8e13c37286e1bb7102772114fe5a4c094",
				size: 70666135,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-10-27-de79a0f/roc",
			},
		},
		{
			tag: "nightly-2026-10-27-de79a0f",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-27-de79a0f/roc_nightly-macos_x86_64-2026-10-27-de79a0f.tar.gz"],
				sha256: "d8ae1184e7ffdff225b90aaa94399d4c1f97500a20e46c389c4a8b02eb03d87f",
				size: 74745000,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-10-27-de79a0f/roc",
			},
		},
		{
			tag: "nightly-2026-10-27-de79a0f",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-27-de79a0f/roc_nightly-windows_x86_64-2026-10-27-de79a0f.zip"],
				sha256: "2ab7593ec81fd3281084accef0d1a6215159bc9bbb7cd0e58e069fcb9ee673a2",
				size: 71563793,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-10-27-de79a0f/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-10-27-de79a0f", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-10-27-de79a0f/roc")
expect Bootstrap.compiler("nightly-2026-10-27-de79a0f", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-27-de79a0f/roc_nightly-linux_arm64-2026-10-27-de79a0f.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("99d3fe58a7995e61a672a8b19ff82c6f9edfa5b1d099f1bccf8418121ebef62c")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
		and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
		and Bootstrap.serving([]) == Err(NotRecorded)
}
