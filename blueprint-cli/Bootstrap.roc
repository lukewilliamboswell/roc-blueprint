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
			tag: "nightly-2026-10-18-1df370f",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-18-1df370f/roc_nightly-linux_x86_64-2026-10-18-1df370f.tar.gz"],
				sha256: "0821ea1a9772f921f0b4eb1cd400238abb59b0247db2810f0ea865426f782e9d",
				size: 71984136,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-10-18-1df370f/roc",
			},
		},
		{
			tag: "nightly-2026-10-18-1df370f",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-18-1df370f/roc_nightly-linux_arm64-2026-10-18-1df370f.tar.gz"],
				sha256: "50058449e786bf9bded19ca3b851a1c030fea7fc8ac8aebed2c7c12a37505ac4",
				size: 69048229,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-10-18-1df370f/roc",
			},
		},
		{
			tag: "nightly-2026-10-18-1df370f",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-18-1df370f/roc_nightly-macos_apple_silicon-2026-10-18-1df370f.tar.gz"],
				sha256: "0f5fe1d12714bf5fcc906dd5b00fd0ccd31dfb96bb82737b9d6f6ccc0e93c147",
				size: 69262825,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-10-18-1df370f/roc",
			},
		},
		{
			tag: "nightly-2026-10-18-1df370f",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-18-1df370f/roc_nightly-macos_x86_64-2026-10-18-1df370f.tar.gz"],
				sha256: "3febd84c0ff274cf3da2fa71afafe4a8039a11c68d774d48406ab669627dce96",
				size: 72947953,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-10-18-1df370f/roc",
			},
		},
		{
			tag: "nightly-2026-10-18-1df370f",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-18-1df370f/roc_nightly-windows_x86_64-2026-10-18-1df370f.zip"],
				sha256: "7acbefc4440c4d7977c47fefb2d8d683b289062c08b4733b9acfc071cb5511b5",
				size: 69855403,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-10-18-1df370f/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-10-18-1df370f", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-10-18-1df370f/roc")
expect Bootstrap.compiler("nightly-2026-10-18-1df370f", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-18-1df370f/roc_nightly-linux_arm64-2026-10-18-1df370f.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("50058449e786bf9bded19ca3b851a1c030fea7fc8ac8aebed2c7c12a37505ac4")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
		and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
		and Bootstrap.serving([]) == Err(NotRecorded)
}
