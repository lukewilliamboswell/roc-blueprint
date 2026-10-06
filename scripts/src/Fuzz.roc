import cli.Env
import cli.OsStr
import cli.Path
import cli.Stdout
import Process
import Script

## Build each roc-fuzz target in `blueprint-core/fuzz/` with coverage
## instrumentation and run it. A crash fails the script; libFuzzer prints the
## reproducing input and writes it under the artifacts directory.
##
## A target runs on a copy of its corpus, so inputs libFuzzer finds do not
## land in the repository. To keep them, run the target binary yourself on
## `blueprint-core/fuzz/<target>/corpus`.
Fuzz := [].{

	## `Replay` runs each committed corpus input once, which takes seconds and
	## is the same every time. `Timed` fuzzes each target for that many seconds.
	Mode : [Replay, Timed(U64)]

	targets_dir = "blueprint-core/fuzz"

	## A target that generates its own inputs has no corpus to replay. It
	## gets this many inputs from a fixed seed instead, so the run is repeatable.
	generated_runs : U64
	generated_runs = 20_000

	mode : List(Str) -> Try(Mode, [BadArguments])
	mode = |args|
		match args {
			[] => Ok(Replay)
			[seconds] =>
				match U64.from_str(seconds) {
					Ok(count) => if count > 0 Ok(Timed(count)) else Err(BadArguments)
					Err(_) => Err(BadArguments)
				}
			_ => Err(BadArguments)
		}

	## libFuzzer's arguments before the corpus directory.
	flags : Mode, Bool, Str, List(Str) -> List(Str)
	flags = |how, has_corpus, artifact_prefix, dictionaries| {
		length = match how {
			Replay => if has_corpus ["-runs=0"] else ["-runs=${generated_runs.to_str()}", "-seed=1"]
			Timed(seconds) => ["-max_total_time=${seconds.to_str()}"]
		}
		length.concat(["-print_final_stats=1", "-artifact_prefix=${artifact_prefix}"]).concat(dictionaries.map(|dictionary| "-dict=${dictionary}"))
	}

	describe : Mode -> Str
	describe = |how|
		match how {
			Replay => "corpus replay"
			Timed(seconds) => "${seconds.to_str()}s"
		}

	## The last `count` lines of `text`.
	tail : Str, U64 -> Str
	tail = |text, count| {
		lines = text.split_on("\n")
		Str.join_with(lines.drop_first(if lines.len() > count lines.len() - count else 0), "\n")
	}

	## Build and run every target, from the repository root.
	run! : Str, Mode => Try({}, _)
	run! = |root, how| {
		# Crashing inputs go here, not the working directory; CI uploads them.
		artifacts = Env.var_str!(OsStr.from_str("FUZZ_ARTIFACTS")) ?? "${root}/fuzz-artifacts"
		Path.create_all!(Path.utf8(artifacts))?
		work = Path.to_str(Env.create_temp_dir_with_prefix!("blueprint-fuzz-")?)?
		result = all!(root, how, Path.to_str(Path.canonicalize!(Path.utf8(artifacts))?)?, work)
		_ = Path.delete_all!(Path.utf8(work))
		result
	}
}

names! : Str => Try(List(Str), _)
names! = |directory| {
	var $names = []
	for entry in Path.list!(Path.utf8(directory))? {
		$names = $names.append(Path.to_str(entry)?.split_on("/").last() ?? "")
	}
	Ok($names)
}

all! : Str, Fuzz.Mode, Str, Str => Try({}, _)
all! = |root, how, artifacts, work| {
	directory = "${root}/${Fuzz.targets_dir}"
	var $fuzzers = []
	for name in names!(directory)? {
		if Path.is_file!(Path.utf8("${directory}/${name}/main.roc")) ?? False {
			$fuzzers = $fuzzers.append(name)
		}
	}
	fuzzers = Process.sorted($fuzzers)
	if fuzzers.is_empty() {
		return Script.fail!("no fuzz targets in ${Fuzz.targets_dir}")
	}
	roc = Process.roc!()
	# A fuzz binary built after a type error would hold runtime-error
	# placeholders, so every target must check and build cleanly first.
	Script.info!("==>", "Checking and building ${fuzzers.len().to_str()} fuzz targets")?
	checks = Process.together!(fuzzers.map(|target| Process.command(roc, ["check", "${directory}/${target}/main.roc"], root)))?
	clean!(fuzzers, checks, "roc check")?
	builds = Process.together!(fuzzers.map(|target| Process.command(roc, ["build", "--fuzz", "${directory}/${target}/main.roc", "--output=${work}/${target}"], root)))?
	clean!(fuzzers, builds, "roc build --fuzz")?
	each!(fuzzers, directory, how, artifacts, work)
}

clean! : List(Str), List(Process.Outcome), Str => Try({}, _)
clean! = |fuzzers, outcomes, step|
	match (fuzzers, outcomes) {
		([], []) => Ok({})
		([target, .. as other_targets], [outcome, .. as other_outcomes]) => {
			if outcome.code != 0 {
				return Script.fail!("${outcome.stdout}${outcome.stderr}\n${step} of ${target} exited with code ${outcome.code.to_str()}")
			}
			clean!(other_targets, other_outcomes, step)
		}
		_ => Script.fail!("${step} did not report every target")
	}

each! : List(Str), Str, Fuzz.Mode, Str, Str => Try({}, _)
each! = |fuzzers, directory, how, artifacts, work|
	match fuzzers {
		[] => Ok({})
		[target, .. as rest] => {
			one!(target, "${directory}/${target}", how, artifacts, work)?
			each!(rest, directory, how, artifacts, work)
		}
	}

one! : Str, Str, Fuzz.Mode, Str, Str => Try({}, _)
one! = |target, source, how, artifacts, work| {
	Script.info!("==>", "${target} (${Fuzz.describe(how)})")?
	binary = "${work}/${target}"
	if !(Path.is_file!(Path.utf8(binary)) ?? False) {
		return Script.fail!("roc build --fuzz did not write ${binary}")
	}
	corpus = "${work}/${target}-corpus"
	has_corpus = Path.is_dir!(Path.utf8("${source}/corpus")) ?? False
	if has_corpus {
		Path.copy_dir!(Path.utf8("${source}/corpus"), Path.utf8(corpus))?
	} else {
		Path.create_all!(Path.utf8(corpus))?
	}
	dictionaries = names!(source)?.keep_if(|name| name.ends_with(".dict")).map(|name| "${source}/${name}")
	arguments = Fuzz.flags(how, has_corpus, "${artifacts}/${target}-", dictionaries).concat([corpus])
	outcome = Process.capture!(Process.command(binary, arguments, work))?
	# libFuzzer reports on standard error.
	if outcome.code != 0 {
		return Script.fail!("${Fuzz.tail(outcome.stderr, 40)}\n${target} failed (exit ${outcome.code.to_str()}); crashing input in ${artifacts}/")
	}
	done = outcome.stderr.split_on("\n").keep_if(|line| line.starts_with("Done "))
	Process.check!(!done.is_empty(), "${Fuzz.tail(outcome.stderr, 40)}\n${target} did not report its runs")?
	Stdout.line!(Str.join_with(done, "\n"))
}

expect Fuzz.mode([]) == Ok(Replay)
expect Fuzz.mode(["300"]) == Ok(Timed(300))
expect Fuzz.mode(["0"]) == Err(BadArguments) and Fuzz.mode(["soon"]) == Err(BadArguments) and Fuzz.mode(["1", "2"]) == Err(BadArguments)

expect Fuzz.flags(Replay, True, "/a/spec-parse-", ["/t/sexpr.dict"]) == ["-runs=0", "-print_final_stats=1", "-artifact_prefix=/a/spec-parse-", "-dict=/t/sexpr.dict"]
expect Fuzz.flags(Replay, False, "/a/t-", []) == ["-runs=20000", "-seed=1", "-print_final_stats=1", "-artifact_prefix=/a/t-"]
expect Fuzz.flags(Timed(30), True, "/a/t-", []) == ["-max_total_time=30", "-print_final_stats=1", "-artifact_prefix=/a/t-"]
expect Fuzz.flags(Timed(30), False, "/a/t-", []) == Fuzz.flags(Timed(30), True, "/a/t-", [])

expect Fuzz.tail("a\nb\nc", 2) == "b\nc" and Fuzz.tail("a\nb", 5) == "a\nb"
