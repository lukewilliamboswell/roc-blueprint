import cli.Env
import cli.Path
import cli.Stdout
import Integrity
import Process
import Script

## Cross-build the `blueprint` CLI, and the program that smoke-tests it, for
## every host the configuration platform supports, from one Linux machine.
##
## Roc links macOS programs against a minimal sysroot it expects beside its own
## executable. Only the macOS compiler archive ships that sysroot, so this
## assembles a toolchain from both archives. Their URLs and hashes come from
## the flake's locked roc-overlay, for the nightly in `.roc-version`.
Release := [].{

	## A released system: Nix's name for it and Roc's target.
	System : { system : Str, target : Str }

	systems : List(System)
	systems = [
		{ system: "x86_64-linux", target: "x64musl" },
		{ system: "aarch64-linux", target: "arm64musl" },
		{ system: "aarch64-darwin", target: "arm64mac" },
	]

	## The program each system's binary is built from, and its name in `dist/`.
	programs = [{ source: "blueprint-cli/main.roc", name: "blueprint" }, { source: "scripts/smoke_binary.roc", name: "smoke" }]

	## The compiler's arguments for one released file. `--no-cache`: with Roc's
	## compile cache the same source and target gave different bytes depending
	## on what the cache already held, so a released file is always compiled
	## from nothing. It costs no time: a cached build of the CLI is no faster.
	build_args : Str, Str, Str -> List(Str)
	build_args = |source, target, output| ["build", source, "--target=${target}", "--no-cache", "--output=${output}"]

	## The released file the build compiles a second time, to compare.
	twice = { source: "blueprint-cli/main.roc", target: "x64musl", name: "blueprint-x86_64-linux" }

	## Where `nix store prefetch-file --json` says it put the file.
	store_path : Str -> Try(Str, [NoStorePath])
	store_path = |json| {
		decoded : Try({ hash : Str, store_path : Str }, _)
		decoded = Json.parse(json.replace_each("\"storePath\"", "\"store_path\""))
		match decoded {
			Ok(fetched) => if fetched.store_path.starts_with("/nix/store/") Ok(fetched.store_path) else Err(NoStorePath)
			Err(_) => Err(NoStorePath)
		}
	}

	## A line `sha256sum -c` accepts for a file read in binary mode.
	checksum_line : Str, List(U8) -> Str
	checksum_line = |name, bytes| "${Integrity.digest(bytes)}  ${name}\n"

	## Build everything into `dist/`, from the repository root.
	run! : Str => Try({}, _)
	run! = |root| {
		work = Path.to_str(Env.create_temp_dir_with_prefix!("blueprint-release-")?)?
		result = build!(root, work)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

## Fetch and unpack the compiler archive the flake locks for a system.
fetch! : Str, Str, Str => Try(Str, _)
fetch! = |root, work, system| {
	attribute = ".#packages.${system}.roc.src"
	url = Process.succeed!(Process.command("nix", ["eval", "--raw", "${attribute}.url"], root))?.stdout
	hash = Process.succeed!(Process.command("nix", ["eval", "--raw", "${attribute}.outputHash"], root))?.stdout
	fetched = Process.succeed!(Process.command("nix", ["store", "prefetch-file", "--json", "--expected-hash", hash, url], root))?
	archive = match Release.store_path(fetched.stdout) {
		Ok(path) => path
		Err(NoStorePath) => return Script.fail!("nix store prefetch-file did not name a store path: ${fetched.stdout}")
	}
	directory = "${work}/${system}"
	Path.create_all!(Path.utf8(directory))?
	_ = Process.succeed!(Process.command("tar", ["-xzf", archive, "-C", directory, "--strip-components=1"], root))?
	Ok(directory)
}

build! : Str, Str => Try({}, _)
build! = |root, work| {
	linux = fetch!(root, work, "x86_64-linux")?
	mac = fetch!(root, work, "aarch64-darwin")?
	Path.copy_dir!(Path.utf8("${mac}/darwin"), Path.utf8("${linux}/darwin"))?
	roc = "${linux}/roc"
	tag = Path.read_utf8!(Path.utf8("${root}/.roc-version"))?.split_on("\n").first() ?? ""
	version = Process.succeed!(Process.command(roc, ["version"], root))?.stdout.trim()
	Process.check!(version == "Roc compiler version ${tag}", "the assembled compiler is \"${version}\", not ${tag}")?

	Process.passthrough!(Process.command("zig", ["build"], "${root}/blueprint-platform"))?
	dist = "${root}/dist"
	Path.create_all!(Path.utf8(dist))?
	for program in Release.programs {
		for released in Release.systems {
			output = "${dist}/${program.name}-${released.system}"
			compile!(roc, root, program.source, released.target, output)?
			Script.info!("==>", output)?
		}
	}
	reproducible!(roc, root, work, dist)?

	var $sums = ""
	for released in Release.systems {
		name = "blueprint-${released.system}"
		$sums = $sums.concat(Release.checksum_line(name, Path.read_bytes!(Path.utf8("${dist}/${name}"))?))
	}
	Path.write_utf8!(Path.utf8("${dist}/blueprint.sha256"), $sums)?
	Stdout.write!($sums)
}

## Build one program for one target. The compiler occasionally fails with an
## unexplained internal error and succeeds unchanged when run again, so a
## failure is retried once.
compile! : Str, Str, Str, Str, Str => Try({}, _)
compile! = |roc, root, source, target, output| {
	job = Process.command(roc, Release.build_args(source, target, output), root)
	first = Process.traced!(job)?
	if first.code != 0 {
		Stdout.write!("${first.stdout}${first.stderr}")?
		_ = Process.succeed!(job)?
	}
	size = if Path.is_file!(Path.utf8(output))? Path.size_in_bytes!(Path.utf8(output))? else 0
	Process.check!(size > 0, "${output} was not built")
}

## Build the x86_64 Linux CLI a second time and require the bytes that were
## just built: a release must be a function of its source and compiler.
reproducible! : Str, Str, Str, Str => Try({}, _)
reproducible! = |roc, root, work, dist| {
	checked = Release.twice
	again = "${work}/${checked.name}"
	compile!(roc, root, checked.source, checked.target, again)?
	first = Integrity.digest(Path.read_bytes!(Path.utf8("${dist}/${checked.name}"))?)
	second = Integrity.digest(Path.read_bytes!(Path.utf8(again))?)
	Process.check!(first == second, "${checked.name} is not reproducible: built twice from one source, its sha256 was ${first} and then ${second}")?
	Script.pass!("${checked.name} built twice is byte-identical (sha256 ${first})")
}

expect Release.store_path("{\"hash\":\"sha256-abc=\",\"storePath\":\"/nix/store/abc-roc.tar.gz\"}\n") == Ok("/nix/store/abc-roc.tar.gz")
expect Release.store_path("{\"hash\":\"sha256-abc=\",\"storePath\":\"/elsewhere\"}") == Err(NoStorePath)
expect Release.store_path("error: hash mismatch") == Err(NoStorePath)

# The format of `sha256sum`: digest, two spaces, name.
expect Release.checksum_line("blueprint-x86_64-linux", "abc".to_utf8()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  blueprint-x86_64-linux\n"
expect Release.systems.map(|released| released.system) == ["x86_64-linux", "aarch64-linux", "aarch64-darwin"]

# Every released file is compiled without the compile cache.
expect Release.build_args("blueprint-cli/main.roc", "x64musl", "dist/blueprint-x86_64-linux") == ["build", "blueprint-cli/main.roc", "--target=x64musl", "--no-cache", "--output=dist/blueprint-x86_64-linux"]

# The file built twice is one of the released files, named as `dist/` names it.
expect Release.programs.any(|program| program.source == Release.twice.source and Release.systems.any(|released| released.target == Release.twice.target and "${program.name}-${released.system}" == Release.twice.name))
