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
			tag: "nightly-2026-11-24-ff5e544",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-24-ff5e544/roc_nightly-linux_x86_64-2026-11-24-ff5e544.tar.gz"],
				sha256: "471d88b0af6747ac9654f2f7a0b426080bd4ec929a8ab519a111e8f54e98654e",
				size: 95075869,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-11-24-ff5e544/roc",
			},
		},
		{
			tag: "nightly-2026-11-24-ff5e544",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-24-ff5e544/roc_nightly-linux_arm64-2026-11-24-ff5e544.tar.gz"],
				sha256: "602536c4d6f06bf1b48c6ff47fb101a1a9fb4f8872480c95c9d317a1a3b4fee6",
				size: 91191491,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-11-24-ff5e544/roc",
			},
		},
		{
			tag: "nightly-2026-11-24-ff5e544",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-24-ff5e544/roc_nightly-macos_apple_silicon-2026-11-24-ff5e544.tar.gz"],
				sha256: "69d144fc4a89ac1b1f91a58eaf60616715a26d3b6b598eefe0bffc9724e60fa3",
				size: 92682232,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-11-24-ff5e544/roc",
			},
		},
		{
			tag: "nightly-2026-11-24-ff5e544",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-24-ff5e544/roc_nightly-macos_x86_64-2026-11-24-ff5e544.tar.gz"],
				sha256: "0cd7d7dc010b9ce6344cb8a73fd8e42f93586f48b4f81501c88bce954a8f3bdc",
				size: 98230341,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-11-24-ff5e544/roc",
			},
		},
		{
			tag: "nightly-2026-11-24-ff5e544",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-24-ff5e544/roc_nightly-windows_x86_64-2026-11-24-ff5e544.zip"],
				sha256: "bcd4efb3a668eb48bd61db7e69fdfd72d54d7d6b5f689bc4434ba0bb8cd068d1",
				size: 92997318,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-11-24-ff5e544/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-11-24-ff5e544", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-11-24-ff5e544/roc")
expect Bootstrap.compiler("nightly-2026-11-24-ff5e544", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-24-ff5e544/roc_nightly-linux_arm64-2026-11-24-ff5e544.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("602536c4d6f06bf1b48c6ff47fb101a1a9fb4f8872480c95c9d317a1a3b4fee6")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
		and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
		and Bootstrap.serving([]) == Err(NotRecorded)
}
