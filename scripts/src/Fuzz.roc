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
## land in the repository. A timed run keeps them instead when `FUZZ_CORPUS`
## names a directory: each target then adds what it finds to
## `<FUZZ_CORPUS>/<target>` and reads the committed corpus as seeds, so the
## next run starts from what this one reached.
Fuzz := [].{

	## `Replay` runs each committed corpus input once, which takes seconds and
	## is the same every time. `Timed` fuzzes each target for that many seconds.
	Mode : [Replay, Timed(U64)]

	targets_dir = "blueprint-core/fuzz"

	## A target that generates its own inputs has no corpus to replay. It
	## gets this many inputs from a fixed seed instead, so the run is repeatable.
	generated_runs : U64
	generated_runs = 20_000

	## What a command line asks for: how to run, and which targets. No
	## target named means every one.
	Request : { how : Mode, only : List(Str) }

	request : List(Str) -> Try(Request, [BadArguments])
	request = |args|
		match args {
			[] => Ok({ how: Replay, only: [] })
			[seconds, .. as only] =>
				match U64.from_str(seconds) {
					Ok(count) => if count > 0 Ok({ how: Timed(count), only }) else Err(BadArguments)
					Err(_) => Err(BadArguments)
				}
		}

	## The targets to run among those in the repository, or the first name
	## asked for that is not one.
	chosen : List(Str), List(Str) -> Try(List(Str), [NoTarget(Str)])
	chosen = |present, only|
		match only.find_first(|name| !present.contains(name)) {
			Ok(name) => Err(NoTarget(name))
			Err(_) => Ok(if only.is_empty() present else present.keep_if(|name| only.contains(name)))
		}

	## Where a target's inputs live for one run. `Scratch` is a copy of the
	## committed corpus, deleted afterwards. `Kept` is a directory that
	## outlives the run: libFuzzer writes what it finds to the first corpus
	## directory it is given and only reads the others. `persistent` is
	## `FUZZ_CORPUS`, or "". A replay never uses it, so CI stays the same
	## every time.
	Corpus : [Scratch, Kept(Str)]

	corpus : Mode, Str, Str -> Corpus
	corpus = |how, persistent, target|
		match how {
			Replay => Scratch
			Timed(_) => if persistent.is_empty() Scratch else Kept("${persistent}/${target}")
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

	## Build and run the requested targets, from the repository root.
	run! : Str, Request => Try({}, _)
	run! = |root, asked| {
		# Crashing inputs go here, not the working directory; CI uploads them.
		artifacts = Env.var_str!(OsStr.from_str("FUZZ_ARTIFACTS")) ?? "${root}/fuzz-artifacts"
		Path.create_all!(Path.utf8(artifacts))?
		work = Path.to_str(Env.create_temp_dir_with_prefix!("blueprint-fuzz-")?)?
		persistent = match Env.var_str!(OsStr.from_str("FUZZ_CORPUS")) {
			Ok(directory) if !directory.is_empty() => {
				Path.create_all!(Path.utf8(directory))?
				Path.to_str(Path.canonicalize!(Path.utf8(directory))?)?
			}
			_ => ""
		}
		result = all!(root, asked, { artifacts: Path.to_str(Path.canonicalize!(Path.utf8(artifacts))?)?, persistent, work })
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

## Where a run writes: crashing inputs, corpora that are kept ("" for none)
## and everything deleted afterwards.
Places : { artifacts : Str, persistent : Str, work : Str }

all! : Str, Fuzz.Request, Places => Try({}, _)
all! = |root, asked, places| {
	directory = "${root}/${Fuzz.targets_dir}"
	var $fuzzers = []
	for name in names!(directory)? {
		if Path.is_file!(Path.utf8("${directory}/${name}/main.roc")) ?? False {
			$fuzzers = $fuzzers.append(name)
		}
	}
	if $fuzzers.is_empty() {
		return Script.fail!("no fuzz targets in ${Fuzz.targets_dir}")
	}
	fuzzers = match Fuzz.chosen(Process.sorted($fuzzers), asked.only) {
		Ok(names) => names
		Err(NoTarget(name)) => return Script.fail!("no fuzz target named ${name} in ${Fuzz.targets_dir}")
	}
	work = places.work
	roc = Process.roc!()
	# A fuzz binary built after a type error would hold runtime-error
	# placeholders, so every target must check and build cleanly first.
	Script.info!("==>", "Checking and building ${fuzzers.len().to_str()} fuzz targets")?
	checks = Process.together!(fuzzers.map(|target| Process.command(roc, ["check", "${directory}/${target}/main.roc"], root)))?
	clean!(fuzzers, checks, "roc check")?
	builds = Process.together!(fuzzers.map(|target| Process.command(roc, ["build", "--fuzz", "${directory}/${target}/main.roc", "--output=${work}/${target}"], root)))?
	clean!(fuzzers, builds, "roc build --fuzz")?
	each!(fuzzers, directory, asked.how, places)
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

each! : List(Str), Str, Fuzz.Mode, Places => Try({}, _)
each! = |fuzzers, directory, how, places|
	match fuzzers {
		[] => Ok({})
		[target, .. as rest] => {
			one!(target, "${directory}/${target}", how, places)?
			each!(rest, directory, how, places)
		}
	}

one! : Str, Str, Fuzz.Mode, Places => Try({}, _)
one! = |target, source, how, places| {
	artifacts = places.artifacts
	work = places.work
	Script.info!("==>", "${target} (${Fuzz.describe(how)})")?
	binary = "${work}/${target}"
	if !(Path.is_file!(Path.utf8(binary)) ?? False) {
		return Script.fail!("roc build --fuzz did not write ${binary}")
	}
	scratch = "${work}/${target}-corpus"
	has_corpus = Path.is_dir!(Path.utf8("${source}/corpus")) ?? False
	corpora = match Fuzz.corpus(how, places.persistent, target) {
		Scratch => {
			if has_corpus {
				Path.copy_dir!(Path.utf8("${source}/corpus"), Path.utf8(scratch))?
			} else {
				Path.create_all!(Path.utf8(scratch))?
			}
			[scratch]
		}
		Kept(directory) => {
			Path.create_all!(Path.utf8(directory))?
			if has_corpus [directory, "${source}/corpus"] else [directory]
		}
	}
	dictionaries = names!(source)?.keep_if(|name| name.ends_with(".dict")).map(|name| "${source}/${name}")
	arguments = Fuzz.flags(how, has_corpus, "${artifacts}/${target}-", dictionaries).concat(corpora)
	outcome = Process.capture!(Process.command(binary, arguments, work))?
	# libFuzzer reports on standard error.
	if outcome.code != 0 {
		return Script.fail!("${Fuzz.tail(outcome.stderr, 40)}\n${target} failed (exit ${outcome.code.to_str()}); crashing input in ${artifacts}/")
	}
	done = outcome.stderr.split_on("\n").keep_if(|line| line.starts_with("Done "))
	Process.check!(!done.is_empty(), "${Fuzz.tail(outcome.stderr, 40)}\n${target} did not report its runs")?
	Stdout.line!(Str.join_with(done, "\n"))
}

expect Fuzz.request([]) == Ok({ how: Replay, only: [] })
expect Fuzz.request(["300"]) == Ok({ how: Timed(300), only: [] })
expect Fuzz.request(["300", "spec-parse"]) == Ok({ how: Timed(300), only: ["spec-parse"] })
expect Fuzz.request(["0"]) == Err(BadArguments) and Fuzz.request(["soon"]) == Err(BadArguments) and Fuzz.request(["spec-parse", "300"]) == Err(BadArguments)

expect Fuzz.chosen(["a", "b", "c"], []) == Ok(["a", "b", "c"])
expect Fuzz.chosen(["a", "b", "c"], ["c", "a"]) == Ok(["a", "c"])
expect Fuzz.chosen(["a", "b"], ["a", "z"]) == Err(NoTarget("z"))

# Only a timed run with a directory to keep inputs in leaves the scratch copy.
expect Fuzz.corpus(Timed(30), "/kept", "spec-parse") == Kept("/kept/spec-parse")
expect Fuzz.corpus(Timed(30), "", "spec-parse") == Scratch
expect Fuzz.corpus(Replay, "/kept", "spec-parse") == Scratch

expect Fuzz.flags(Replay, True, "/a/spec-parse-", ["/t/sexpr.dict"]) == ["-runs=0", "-print_final_stats=1", "-artifact_prefix=/a/spec-parse-", "-dict=/t/sexpr.dict"]
expect Fuzz.flags(Replay, False, "/a/t-", []) == ["-runs=20000", "-seed=1", "-print_final_stats=1", "-artifact_prefix=/a/t-"]
expect Fuzz.flags(Timed(30), True, "/a/t-", []) == ["-max_total_time=30", "-print_final_stats=1", "-artifact_prefix=/a/t-"]
expect Fuzz.flags(Timed(30), False, "/a/t-", []) == Fuzz.flags(Timed(30), True, "/a/t-", [])

expect Fuzz.tail("a\nb\nc", 2) == "b\nc" and Fuzz.tail("a\nb", 5) == "a\nb"
