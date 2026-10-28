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
			tag: "nightly-2026-10-28-bad769b",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-28-bad769b/roc_nightly-linux_x86_64-2026-10-28-bad769b.tar.gz"],
				sha256: "aeacbeb60f273ea85657a003e2ec39461595f3261bb69c9e16ea18a6563ae8d9",
				size: 74712401,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-10-28-bad769b/roc",
			},
		},
		{
			tag: "nightly-2026-10-28-bad769b",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-28-bad769b/roc_nightly-linux_arm64-2026-10-28-bad769b.tar.gz"],
				sha256: "0f51a80492b70b4c282f0b9577d74d29ead4000024bc7db04a308d6102e82aef",
				size: 71511095,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-10-28-bad769b/roc",
			},
		},
		{
			tag: "nightly-2026-10-28-bad769b",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-28-bad769b/roc_nightly-macos_apple_silicon-2026-10-28-bad769b.tar.gz"],
				sha256: "69939f3535b2977465379e806a196affedbc65310545479d5a638ef6d15304c7",
				size: 71588923,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-10-28-bad769b/roc",
			},
		},
		{
			tag: "nightly-2026-10-28-bad769b",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-28-bad769b/roc_nightly-macos_x86_64-2026-10-28-bad769b.tar.gz"],
				sha256: "292c8059591819468ba07dc694c8248685ddd76e259d031cbd07e7c6c9dea16a",
				size: 75658583,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-10-28-bad769b/roc",
			},
		},
		{
			tag: "nightly-2026-10-28-bad769b",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-28-bad769b/roc_nightly-windows_x86_64-2026-10-28-bad769b.zip"],
				sha256: "1edc79e8366939d1d981e0608dfdfa42dd32183270656b57cc50f2c73ba96828",
				size: 72464557,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-10-28-bad769b/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-10-28-bad769b", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-10-28-bad769b/roc")
expect Bootstrap.compiler("nightly-2026-10-28-bad769b", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-28-bad769b/roc_nightly-linux_arm64-2026-10-28-bad769b.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("0f51a80492b70b4c282f0b9577d74d29ead4000024bc7db04a308d6102e82aef")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
		and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
		and Bootstrap.serving([]) == Err(NotRecorded)
}
