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
			tag: "nightly-2026-11-25-d5a4f1e",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-25-d5a4f1e/roc_nightly-linux_x86_64-2026-11-25-d5a4f1e.tar.gz"],
				sha256: "e44074b96c0940f468c4cbf26622410aedf80b5c2e265f44b6e1f10c93360078",
				size: 95153025,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-11-25-d5a4f1e/roc",
			},
		},
		{
			tag: "nightly-2026-11-25-d5a4f1e",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-25-d5a4f1e/roc_nightly-linux_arm64-2026-11-25-d5a4f1e.tar.gz"],
				sha256: "e96a8293ec21a57682d8832f98881d37ac9404474cf7e5588c78b1a566efd3cb",
				size: 91257785,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-11-25-d5a4f1e/roc",
			},
		},
		{
			tag: "nightly-2026-11-25-d5a4f1e",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-25-d5a4f1e/roc_nightly-macos_apple_silicon-2026-11-25-d5a4f1e.tar.gz"],
				sha256: "e507ecde9a0249b67d4c08133aa9a4bf0b6594523d6d0e0247e31bd2df78301f",
				size: 92721942,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-11-25-d5a4f1e/roc",
			},
		},
		{
			tag: "nightly-2026-11-25-d5a4f1e",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-25-d5a4f1e/roc_nightly-macos_x86_64-2026-11-25-d5a4f1e.tar.gz"],
				sha256: "167cdee66dbff74a8c6c14ded1aa2c54688ca40aae6943820394643928188e5f",
				size: 98280725,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-11-25-d5a4f1e/roc",
			},
		},
		{
			tag: "nightly-2026-11-25-d5a4f1e",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-25-d5a4f1e/roc_nightly-windows_x86_64-2026-11-25-d5a4f1e.zip"],
				sha256: "75efcb30affc695015cb5dc31d4b5ad51fa16e0399e5d70eb87beb5526e34569",
				size: 93098474,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-11-25-d5a4f1e/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-11-25-d5a4f1e", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-11-25-d5a4f1e/roc")
expect Bootstrap.compiler("nightly-2026-11-25-d5a4f1e", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-11-25-d5a4f1e/roc_nightly-linux_arm64-2026-11-25-d5a4f1e.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("e96a8293ec21a57682d8832f98881d37ac9404474cf7e5588c78b1a566efd3cb")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
		and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
		and Bootstrap.serving([]) == Err(NotRecorded)
}
