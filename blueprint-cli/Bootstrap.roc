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
			tag: "nightly-2026-10-04-130536d",
			system: "x86_64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_x86_64-2026-10-04-130536d.tar.gz"],
				sha256: "893c86d2da0a4c390cbdbd4258ce45d686e5ec15b42eeeb811fd1ac44537714f",
				size: 69614310,
				unpack: TarGz,
				path: "roc_nightly-linux_x86_64-2026-10-04-130536d/roc",
			},
		},
		{
			tag: "nightly-2026-10-04-130536d",
			system: "aarch64-linux",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_arm64-2026-10-04-130536d.tar.gz"],
				sha256: "f4532d290c83920d23f191da4650b19aa8302743ed35cab4e9adc83beaf0c1db",
				size: 66679849,
				unpack: TarGz,
				path: "roc_nightly-linux_arm64-2026-10-04-130536d/roc",
			},
		},
		{
			tag: "nightly-2026-10-04-130536d",
			system: "aarch64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-macos_apple_silicon-2026-10-04-130536d.tar.gz"],
				sha256: "e0147f62f072a309519cbc2a6ebfa11e4bb8bac7903d5febaf7a112d1fc2842f",
				size: 66810227,
				unpack: TarGz,
				path: "roc_nightly-macos_apple_silicon-2026-10-04-130536d/roc",
			},
		},
		{
			tag: "nightly-2026-10-04-130536d",
			system: "x86_64-darwin",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-macos_x86_64-2026-10-04-130536d.tar.gz"],
				sha256: "cd8df0772cc1d831acea9ebe000340d244297e37393e4d0a8b581f8300422fd4",
				size: 70601701,
				unpack: TarGz,
				path: "roc_nightly-macos_x86_64-2026-10-04-130536d/roc",
			},
		},
		{
			tag: "nightly-2026-10-04-130536d",
			system: "x86_64-windows",
			program: {
				name: "roc",
				urls: ["https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-windows_x86_64-2026-10-04-130536d.zip"],
				sha256: "1f5ac14286ebea19f884176c6ab1eabe29f1ad58c10d8f490a9c282e0411033f",
				size: 67310620,
				unpack: Zip,
				path: "roc_nightly-windows_x86_64-2026-10-04-130536d/roc.exe",
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

expect Bootstrap.compiler("nightly-2026-10-04-130536d", "aarch64-darwin").map_ok(|program| program.path) == Ok("roc_nightly-macos_apple_silicon-2026-10-04-130536d/roc")
expect Bootstrap.compiler("nightly-2026-10-04-130536d", "riscv64-linux") == Err(NotRecorded) and Bootstrap.compiler("nightly-2026-10-03-c507926", "x86_64-linux") == Err(NotRecorded)

# A program whose first URL is a compiler's download is that download; a
# mirror first, another URL or no URL is not.
expect {
	url = "https://github.com/roc-lang/nightlies/releases/download/nightly-2026-10-04-130536d/roc_nightly-linux_arm64-2026-10-04-130536d.tar.gz"
	Bootstrap.serving([url, "https://mirror.example.org/roc.tar.gz"]).map_ok(|program| program.sha256) == Ok("f4532d290c83920d23f191da4650b19aa8302743ed35cab4e9adc83beaf0c1db")
		and Bootstrap.serving(["https://mirror.example.org/roc.tar.gz", url]) == Err(NotRecorded)
			and Bootstrap.serving(["${url}.sig"]) == Err(NotRecorded)
				and Bootstrap.serving([]) == Err(NotRecorded)
}
