import cli.Env
import cli.Path
import Process
import Script

## The platform host's Zig bindings, `blueprint-platform/host/roc_platform_abi.zig`,
## are what `roc glue` writes for the platform with the product compiler. The
## file is committed, so it can fall behind the compiler or the platform's
## hosted functions without anything failing until the host misbehaves.
##
## The specification `roc glue` runs is not in the compiler archive. The flake
## package `roc-glue-spec` takes it from the source archive of the same
## nightly, by hash.
Glue := [].{

	## The flake package holding the specification, and the file in it.
	spec_package = "roc-glue-spec"
	specification = "ZigGlue.roc"

	## The platform the bindings are for and the committed file.
	platform_file = "blueprint-platform/main.roc"
	bindings = "blueprint-platform/host/roc_platform_abi.zig"

	## What `roc glue` names its one output.
	generated = "roc_platform_abi.zig"

	## `Check` compares the committed bindings with fresh ones; `Update`
	## replaces them.
	Mode : [Check, Update]

	mode : List(Str) -> Try(Mode, [BadArguments])
	mode = |args|
		match args {
			[] => Ok(Check)
			["--update"] => Ok(Update)
			_ => Err(BadArguments)
		}

	## The compiler's arguments: the specification, where to write, and the platform.
	glue_args : Str, Str -> List(Str)
	glue_args = |spec, output| ["glue", spec, output, platform_file]

	## Regenerate the bindings in a temporary directory, from the repository
	## root, and compare or install them.
	run! : Str, Mode => Try({}, _)
	run! = |root, how| {
		built = Process.succeed!(Process.command("nix", ["build", "--no-link", "--print-out-paths", ".#${spec_package}"], root))?
		work = Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-glue-")?)?)?
		result = regenerate!(root, how, "${built.stdout.trim()}/${specification}", work)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

regenerate! : Str, Glue.Mode, Str, Str => Try({}, _)
regenerate! = |root, how, packaged, work| {
	# The compiler writes beside the specification it compiles, and the store
	# is read-only.
	spec = "${work}/${Glue.specification}"
	Path.write_utf8!(Path.utf8(spec), Path.read_utf8!(Path.utf8(packaged))?)?
	output = "${work}/out"
	Path.create_all!(Path.utf8(output))?
	_ = Process.succeed!(Process.command(Process.roc!(), Glue.glue_args(spec, output), root))?
	fresh = "${output}/${Glue.generated}"
	committed = "${root}/${Glue.bindings}"
	match how {
		Update => {
			Path.write_utf8!(Path.utf8(committed), Path.read_utf8!(Path.utf8(fresh))?)?
			Script.pass!("wrote ${Glue.bindings}")
		}
		Check =>
			if Path.read_utf8!(Path.utf8(fresh))? == Path.read_utf8!(Path.utf8(committed))? {
				Script.pass!("${Glue.bindings} is what roc glue writes for ${Glue.platform_file}")
			} else {
				# git diff exits 1 when the files differ.
				difference = Process.capture!(Process.command("git", ["diff", "--no-index", "--", committed, fresh], root))?
				Script.fail!("${difference.stdout}\n${Glue.bindings} is not what roc glue writes; run scripts/check_glue.roc --update")
			}
	}
}

expect Glue.mode([]) == Ok(Check)
expect Glue.mode(["--update"]) == Ok(Update)
expect Glue.mode(["--check"]) == Err(BadArguments) and Glue.mode(["--update", "more"]) == Err(BadArguments)
expect Glue.glue_args("/tmp/spec.roc", "/tmp/out") == ["glue", "/tmp/spec.roc", "/tmp/out", "blueprint-platform/main.roc"]
