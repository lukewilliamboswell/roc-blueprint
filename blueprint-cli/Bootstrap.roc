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
			tag: "nightly-2026-11-01-48d3369",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-01-48d3369/roc_nightly-linux_x86_64-2026-11-01-48d3369.tar.gz"],
				sha256: "110ade54087cabc3102bb1b4a749312fa01422e442f3249b695d7133347d70c5",
				size: 80249287,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-11-01-48d3369/roc",
			},
		},
		{
			tag: "nightly-2026-11-01-48d3369",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-01-48d3369/roc_nightly-linux_arm64-2026-11-01-48d3369.tar.gz"],
				sha256: "7d0279aeab475fe6c25bf653154da315bfe63e580b82d6a0c271592948d0fdbe",
				size: 76988483,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-11-01-48d3369/roc",
			},
		},
		{
			tag: "nightly-2026-11-01-48d3369",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-01-48d3369/roc_nightly-macos_apple_silicon-2026-11-01-48d3369.tar.gz"],
				sha256: "cc2e88b05e130bd27d61df6d63f32351b42d70fb41b39d103eeb148a56d3a16f",
				size: 77071423,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-11-01-48d3369/roc",
			},
		},
		{
			tag: "nightly-2026-11-01-48d3369",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-01-48d3369/roc_nightly-macos_x86_64-2026-11-01-48d3369.tar.gz"],
				sha256: "99681a092d50e738b5f4f60269ecaf00482c2f7529caed55d4d2e26146fdb440",
				size: 81212748,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-11-01-48d3369/roc",
			},
		},
		{
			tag: "nightly-2026-11-01-48d3369",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-01-48d3369/roc_nightly-windows_x86_64-2026-11-01-48d3369.zip"],
				sha256: "ebf091589b61854cf3f0a92a484918b6f31961d1e957f002c230edeac6a9f14d",
				size: 77924383,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-11-01-48d3369/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-11-01-48d3369", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-11-01-48d3369/roc")
expect Bootstrap.compiler("nightly-2026-11-01-48d3369", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-01-48d3369/roc_nightly-linux_arm64-2026-11-01-48d3369.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("7d0279aeab475fe6c25bf653154da315bfe63e580b82d6a0c271592948d0fdbe")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
		and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
		and Bootstrap.serving([]) == Err(NotRecorded)
}
