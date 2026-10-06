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

	## One file to compile: its source, Roc's target and where it goes.
	File : { source : Str, target : Str, output : Str }

	## One program for every released system, as `<directory>/<name>-<system>`.
	files : Str, Str -> List(File)
	files = |name, directory|
		programs.keep_if(|program| program.name == name).fold(
			[],
			|listed, program| listed.concat(systems.map(|released| { source: program.source, target: released.target, output: "${directory}/${program.name}-${released.system}" })),
		)

	## The released file the build compiles a second time, to compare.
	twice = { source: "blueprint-cli/main.roc", target: "x64musl", name: "blueprint-x86_64-linux" }

	## The compiler that builds every target is the x86_64 Linux archive, with
	## the macOS sysroot of the Apple Silicon archive beside it.
	compiler_system = "x86_64-linux"
	sysroot_system = "aarch64-darwin"

	## The compiler archive the flake's locked roc-overlay names for a system:
	## its URL and the hash Nix checks it against.
	archive! : Str, Str => Try({ url : Str, hash : Str }, _)
	archive! = |root, system| {
		attribute = ".#packages.${system}.roc.src"
		url = Process.succeed!(Process.command("nix", ["eval", "--raw", "${attribute}.url"], root))?.stdout
		hash = Process.succeed!(Process.command("nix", ["eval", "--raw", "${attribute}.outputHash"], root))?.stdout
		Ok({ url, hash })
	}

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
	named = Release.archive!(root, system)?
	fetched = Process.succeed!(Process.command("nix", ["store", "prefetch-file", "--json", "--expected-hash", named.hash, named.url], root))?
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
	linux = fetch!(root, work, Release.compiler_system)?
	mac = fetch!(root, work, Release.sysroot_system)?
	Path.copy_dir!(Path.utf8("${mac}/darwin"), Path.utf8("${linux}/darwin"))?
	roc = "${linux}/roc"
	tag = Path.read_utf8!(Path.utf8("${root}/.roc-version"))?.split_on("\n").first() ?? ""
	version = Process.succeed!(Process.command(roc, ["version"], root))?.stdout.trim()
	Process.check!(version == "Roc compiler version ${tag}", "the assembled compiler is \"${version}\", not ${tag}")?

	Process.passthrough!(Process.command("zig", ["build"], "${root}/blueprint-platform"))?
	dist = "${root}/dist"
	Path.create_all!(Path.utf8(dist))?
	# Two rounds, so that at most three compilations of the CLI run at once.
	second = "${work}/${Release.twice.name}"
	compile_together!(roc, root, Release.files("blueprint", dist))?
	compile_together!(roc, root, Release.files("smoke", dist).append({ source: Release.twice.source, target: Release.twice.target, output: second }))?
	reproducible!("${dist}/${Release.twice.name}", second)?

	var $sums = ""
	for released in Release.systems {
		name = "blueprint-${released.system}"
		$sums = $sums.concat(Release.checksum_line(name, Path.read_bytes!(Path.utf8("${dist}/${name}"))?))
	}
	Path.write_utf8!(Path.utf8("${dist}/blueprint.sha256"), $sums)?
	Stdout.write!($sums)
}

## Build these files at the same time. A compilation of the CLI is
## single-threaded for most of its run and peaks at about 2.3 GB, so three fit
## a 4-core, 16 GB machine. `--no-cache` leaves them nothing to share: built
## together they are byte for byte what they are built one after another.
##
## The compiler occasionally fails with an unexplained internal error and
## succeeds unchanged when run again, so each failure is retried once, alone.
compile_together! : Str, Str, List(Release.File) => Try({}, _)
compile_together! = |roc, root, files| {
	jobs = files.map(|file| Process.command(roc, Release.build_args(file.source, file.target, file.output), root))
	for job in jobs {
		Script.info!("RUN ", job.label)?
	}
	finish_each!(files, jobs, Process.together!(jobs)?)
}

## Report each compilation in the order given, with its own output if it failed.
finish_each! : List(Release.File), List(Process.Job), List(Process.Outcome) => Try({}, _)
finish_each! = |files, jobs, outcomes|
	match (files, jobs, outcomes) {
		([], [], []) => Ok({})
		([file, .. as other_files], [job, .. as other_jobs], [outcome, .. as other_outcomes]) => {
			if outcome.code != 0 {
				Stdout.write!("${job.label} exited with code ${outcome.code.to_str()}:\n${outcome.stdout}${outcome.stderr}\nRetrying it once.\n")?
				_ = Process.succeed!(job)?
			}
			size = if Path.is_file!(Path.utf8(file.output))? Path.size_in_bytes!(Path.utf8(file.output))? else 0
			Process.check!(size > 0, "${file.output} was not built")?
			Script.info!("==>", file.output)?
			finish_each!(other_files, other_jobs, other_outcomes)
		}
		_ => Script.fail!("the compiler did not report every file")
	}

## Require a file compiled twice to be the same bytes: a release must be a
## function of its source and compiler.
reproducible! : Str, Str => Try({}, _)
reproducible! = |first, second| {
	name = first.split_on("/").last() ?? first
	once = Integrity.digest(Path.read_bytes!(Path.utf8(first))?)
	again = Integrity.digest(Path.read_bytes!(Path.utf8(second))?)
	Process.check!(once == again, "${name} is not reproducible: built twice from one source, its sha256 was ${once} and then ${again}")?
	Script.pass!("${name} built twice is byte-identical (sha256 ${once})")
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

# Each program is built for every released system, in the systems' order.
expect Release.files("blueprint", "dist").map(|file| file.output) == ["dist/blueprint-x86_64-linux", "dist/blueprint-aarch64-linux", "dist/blueprint-aarch64-darwin"]
expect Release.files("smoke", "/repo/dist") == [
	{ source: "scripts/smoke_binary.roc", target: "x64musl", output: "/repo/dist/smoke-x86_64-linux" },
	{ source: "scripts/smoke_binary.roc", target: "arm64musl", output: "/repo/dist/smoke-aarch64-linux" },
	{ source: "scripts/smoke_binary.roc", target: "arm64mac", output: "/repo/dist/smoke-aarch64-darwin" },
]
expect Release.programs.map(|program| program.name) == ["blueprint", "smoke"] and Release.files("other", "dist").is_empty()
