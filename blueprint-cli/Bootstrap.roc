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
			tag: "nightly-2026-10-23-18478ff",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-23-18478ff/roc_nightly-linux_x86_64-2026-10-23-18478ff.tar.gz"],
				sha256: "c283ae01e758b9d64002d72b8e4ad776466e7e6e5f495fd466e274afbd25ce7f",
				size: 73616283,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-10-23-18478ff/roc",
			},
		},
		{
			tag: "nightly-2026-10-23-18478ff",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-23-18478ff/roc_nightly-linux_arm64-2026-10-23-18478ff.tar.gz"],
				sha256: "6dba8200968747570a8b26087aa07e1880433b2e776ebb901bff5812ee814fad",
				size: 70450002,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-10-23-18478ff/roc",
			},
		},
		{
			tag: "nightly-2026-10-23-18478ff",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-23-18478ff/roc_nightly-macos_apple_silicon-2026-10-23-18478ff.tar.gz"],
				sha256: "668b2731c62ac9054ecf5cd4d483638c237626517df6c076204870065a103b38",
				size: 70519866,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-10-23-18478ff/roc",
			},
		},
		{
			tag: "nightly-2026-10-23-18478ff",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-23-18478ff/roc_nightly-macos_x86_64-2026-10-23-18478ff.tar.gz"],
				sha256: "de555db1c8edb9ad7f244929015189080dd205c7e18a93fc9fa85e85250cc4fe",
				size: 74582641,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-10-23-18478ff/roc",
			},
		},
		{
			tag: "nightly-2026-10-23-18478ff",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-23-18478ff/roc_nightly-windows_x86_64-2026-10-23-18478ff.zip"],
				sha256: "b01b37648e9bb0ee08b0f762673d366af6c2574377c67d5e11baddcb8cb7ebe4",
				size: 71401324,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-10-23-18478ff/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-10-23-18478ff", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-10-23-18478ff/roc")
expect Bootstrap.compiler("nightly-2026-10-23-18478ff", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-23-18478ff/roc_nightly-linux_arm64-2026-10-23-18478ff.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("6dba8200968747570a8b26087aa07e1880433b2e776ebb901bff5812ee814fad")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
		and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
		and Bootstrap.serving([]) == Err(NotRecorded)
}
