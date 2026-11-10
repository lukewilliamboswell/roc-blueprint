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
			tag: "nightly-2026-11-10-f7d1f19",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-10-f7d1f19/roc_nightly-linux_x86_64-2026-11-10-f7d1f19.tar.gz"],
				sha256: "891f1e05d15494cb7f2a6e4b747e4ce161f4587e6677bac062aefd6738ab58b9",
				size: 80365025,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-11-10-f7d1f19/roc",
			},
		},
		{
			tag: "nightly-2026-11-10-f7d1f19",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-10-f7d1f19/roc_nightly-linux_arm64-2026-11-10-f7d1f19.tar.gz"],
				sha256: "5ec95f5e19bf4f5afd5fd7244631c39c91fb89bd865c29c8ccac98734ea020cf",
				size: 77021349,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-11-10-f7d1f19/roc",
			},
		},
		{
			tag: "nightly-2026-11-10-f7d1f19",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-10-f7d1f19/roc_nightly-macos_apple_silicon-2026-11-10-f7d1f19.tar.gz"],
				sha256: "68dcc906c8bd9b984a67467258d7cebc3d64e14be4a473b0614887d0eec99c4a",
				size: 76802942,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-11-10-f7d1f19/roc",
			},
		},
		{
			tag: "nightly-2026-11-10-f7d1f19",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-10-f7d1f19/roc_nightly-macos_x86_64-2026-11-10-f7d1f19.tar.gz"],
				sha256: "a5878d3ffb6bc3716caf1a66119191af3a25d47f2a262b6fdfe1be1c4c2d3f6b",
				size: 81211703,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-11-10-f7d1f19/roc",
			},
		},
		{
			tag: "nightly-2026-11-10-f7d1f19",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-10-f7d1f19/roc_nightly-windows_x86_64-2026-11-10-f7d1f19.zip"],
				sha256: "a3fa20ff851093673d19eee4c98ce40ff7a98911b33c522f8afb49da7cf28b00",
				size: 77972939,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-11-10-f7d1f19/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-11-10-f7d1f19", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-11-10-f7d1f19/roc")
expect Bootstrap.compiler("nightly-2026-11-10-f7d1f19", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-10-f7d1f19/roc_nightly-linux_arm64-2026-11-10-f7d1f19.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("5ec95f5e19bf4f5afd5fd7244631c39c91fb89bd865c29c8ccac98734ea020cf")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
			and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
				and Bootstrap.serving([]) == Err(NotRecorded)
}
