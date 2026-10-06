import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Random
import cli.Sleep
import CliHarness
import Integrity
import Script

## `blueprint update` against a stubbed compiler and Nix: what it refuses to
## read before any effect, and that it publishes the authority only when the
## bytes it observed before resolving are still there. A `python3` that
## records and fails is first on `PATH` throughout.
CliUpdateTest := [].{

	## Run every case from the repository root, in a temporary directory that is
	## removed afterwards.
	run! : Path => Try({}, _)
	run! = |repository| {
		bench = CliHarness.open!(repository, "blueprint-update-", ["roc-wire", "nix", "python3"])?
		result = cases!(bench)
		CliHarness.close!(bench)
		result
	}

	## The Spec the stub compiler prints: one environment and its shell.
	wire : Str
	wire =
		\\((format ((major 2) (minor 0))) (name "wire")
		\\(systems ("x86_64-linux"))
		\\(sources (((name "default") (provider Auto))))
		\\(environments (((name "ci") (parents ()) (tools ()) (overlays ()))))
		\\(shells (((name "default") (environment "ci")))))

	## `wire` with a local path as each kind of provider input.
	local_inputs : List({ kind : Str, wire : Str })
	local_inputs = [
		{ kind: "build-source", wire: "${wire.drop_suffix(")")}(build_sources (((name \"assets\") (ref \"path:./outer/assets\")))) (requires (\"sources\")))" },
		{ kind: "package-source", wire: wire.replace_each("(provider Auto)", "(provider (NixPackages \"path:./outer/assets\"))") },
		{ kind: "overlay", wire: "${wire.drop_suffix(")")}(inputs (((name \"assets\") (url \"path:./outer/assets\") (kind Overlay)))))" },
	]

	## `size` bytes that are not text, different for every seed: the authority
	## is observed as bytes, in chunks smaller than this.
	noise : U64, U64 -> List(U8)
	noise = |seed, size| {
		var $bytes = [0xff, 0x00]
		var $block = 0
		while $bytes.len() < size {
			$bytes = $bytes.concat(Integrity.digest("${seed.to_str()}/${$block.to_str()}".to_utf8()).to_utf8())
			$block = $block + 1
		}
		$bytes.take_first(size)
	}

	## The same bytes with the last one changed.
	last_changed : List(U8) -> List(U8)
	last_changed = |bytes|
		match bytes.last() {
			Ok(byte) => bytes.drop_last(1).append(if byte == '0' '1' else '0')
			Err(_) => bytes
		}

	## The entries an interrupted publication would leave beside the authority.
	leftovers : List(Str) -> List(Str)
	leftovers = |names| names.keep_if(|name| name.starts_with(".blueprint-write-") or name.contains("writer"))
}

Test : { bench : CliHarness.Bench, env : List((OsStr, OsStr)) }

## A project whose configuration is whatever the stub compiler prints.
project! : Test, Str, Str => Try(Str, _)
project! = |test, name, text| {
	root = "${test.bench.work}/${name}"
	Path.create_dir!(Path.utf8(root))?
	Path.write_utf8!(Path.utf8("${root}/Blueprint.roc"), "")?
	Path.write_utf8!(Path.utf8("${root}/wire.scm"), text)?
	Ok(root)
}

run! : Test, Str, List(Str), List((Str, Str)) => Try(CliHarness.Outcome, _)
run! = |test, root, args, extra|
	CliHarness.blueprint!(test.bench, root, args, CliHarness.setting(test.env, extra))

## Start `blueprint update` with a stub Nix that stops at `barrier` before it
## writes anything, and return once it has stopped there.
paused_update! : Test, Str, Str, List((Str, Str)) => Try(Cmd.Child, _)
paused_update! = |test, root, barrier, extra| {
	Script.info!("RUN ", "blueprint update, pausing in the provider at ${barrier}")?
	child = CliHarness.start!({
		program: test.bench.blueprint,
		args: ["update"],
		cwd: root,
		env: CliHarness.setting(test.env, extra.append(("STUB_NIX_PAUSE", barrier))),
	})?
	var $waited = 0
	while !CliHarness.present!("${barrier}.ready") {
		if $waited >= 20000 {
			return Script.fail!("blueprint update did not reach the provider within 20 seconds")
		}
		Sleep.millis!(10)
		$waited = $waited + 10
	}
	Ok(child)
}

release! : Str => Try({}, _)
release! = |barrier| Path.write_utf8!(Path.utf8("${barrier}.release"), "")

## No provider ran and nothing was generated.
no_effects! : Str, Str => Try({}, _)
no_effects! = |root, what| {
	CliHarness.check!(!CliHarness.present!("${root}/.blueprint"), "${what}: ${root}/.blueprint was created")?
	CliHarness.same_calls!(CliHarness.calls!("${root}/nix-calls")?, [], "${what}: the provider ran")
}

refused! : CliHarness.Outcome, Str, Str => Try({}, _)
refused! = |outcome, expected, what|
	CliHarness.check!(
		outcome.code != 0 and outcome.stderr.contains(expected),
		"${what} exited with code ${outcome.code.to_str()} and did not say ${Str.inspect(expected)}:\n${outcome.stderr}",
	)

## The revision the authority pins the `default` input to.
pinned_rev! : Str => Try(Str, _)
pinned_rev! = |lock| {
	text = Str.from_utf8_lossy(Path.read_bytes!(Path.utf8(lock))?)
	graph = CliHarness.authority_graph(text)
	match graph {
		Ok(pins) =>
			match CliHarness.locked_rev(pins, "default") {
				Ok(rev) => Ok(rev)
				Err(message) => Script.fail!("${lock}: ${message}")
			}

		Err(message) => Script.fail!("${lock}: ${message}")
	}
}

## While an update waits in the provider, replace the authority as a competing
## publisher would, by rename, so it is a new file even with the same bytes.
## `initial` and `replacement` hold the bytes, or nothing for an absent file.
observed! : Test, { name : Str, initial : List(List(U8)), replacement : List(List(U8)), publishes : Bool } => Try({}, _)
observed! = |test, case| {
	root = project!(test, "observed-${case.name}", CliUpdateTest.wire)?
	lock = "${root}/Blueprint.lock"
	for bytes in case.initial {
		Path.write_bytes!(Path.utf8(lock), bytes)?
	}
	barrier = "${test.bench.work}/observed-${case.name}-barrier"
	update = paused_update!(test, root, barrier, [])?
	if CliHarness.present!(lock) {
		Path.delete!(Path.utf8(lock))?
	}
	for bytes in case.replacement {
		Path.write_bytes!(Path.utf8("${root}/competing-authority"), bytes)?
		Path.rename!(Path.utf8("${root}/competing-authority"), Path.utf8(lock))?
	}
	release!(barrier)?
	outcome = CliHarness.finish!(update, "blueprint update (${case.name})")?
	what = "update whose authority was ${case.name} meanwhile"
	if case.publishes {
		CliHarness.exited!(outcome, 0, what)?
		CliHarness.check!(pinned_rev!(lock)? == "cccccccccccccccccccccccccccccccccccccccc", "${what} did not publish its pins")?
	} else {
		CliHarness.exited!(outcome, 1, what)?
		CliHarness.contains!(outcome.stderr, "authority changed during update", what)?
		now = if CliHarness.present!(lock) [Path.read_bytes!(Path.utf8(lock))?] else []
		CliHarness.check!(now == case.replacement, "${what} did not leave the competing authority as it was")?
	}
	left = CliUpdateTest.leftovers(CliHarness.names!(root)?)
	CliHarness.check!(left.is_empty(), "${what} left ${Str.join_with(left, " ")}")
}

cases! : CliHarness.Bench => Try({}, _)
cases! = |bench| {
	search = Env.var_str!(OsStr.from_str("PATH")) ?? ""
	python_log = "${bench.work}/python3-was-used"
	test = {
		bench,
		env: CliHarness.setting(
			bench.env,
			[
				("PATH", "${bench.bin}:${search}"),
				("ROC", "${bench.bin}/roc-wire"),
				("STUB_ROC_VERSION", bench.roc_version),
				("STUB_NIX_FIXTURE", "${bench.root}/blueprint-nix/tests/local.nix-lock.json"),
				("STUB_NIX_MODE", "local"),
				("STUB_PYTHON_LOG", python_log),
			],
		),
	}
	work = bench.work
	old = "old authority".to_utf8().concat([0xff, 0x00])

	# Preflight must inspect ancestor links for every provider input category.
	outside = "${work}/outside"
	Path.create_all!(Path.utf8("${outside}/assets"))?
	for form in CliUpdateTest.local_inputs {
		root = project!(test, "ancestor-${form.kind}", form.wire)?
		CliHarness.tool!(["ln", "-s", "--", outside, "${root}/outer"])?
		lock = "${root}/Blueprint.lock"
		Path.write_bytes!(Path.utf8(lock), old)?
		before = CliHarness.identity!(lock)?
		what = "update with a ${form.kind} below a symlinked directory"
		refused!(run!(test, root, ["update"], [])?, "unsafe", what)?
		no_effects!(root, what)?
		CliHarness.check!(CliHarness.identity!(lock)? == before, "${what} rewrote the authority")?
	}
	Script.pass!("a local build source, package source or overlay below a symlinked directory: refused as unsafe, authority not rewritten")?

	# Nested links, missing source roots and special files fail before effects.
	build_source = CliUpdateTest.local_inputs.first().map_ok(|form| form.wire) ?? ""
	for kind in ["nested", "missing", "fifo"] {
		root = project!(test, kind, build_source)?
		source = "${root}/outer/assets"
		if kind != "missing" {
			Path.create_all!(Path.utf8(source))?
		}
		if kind == "nested" {
			CliHarness.tool!(["ln", "-s", "--", outside, "${source}/escape"])?
		}
		if kind == "fifo" {
			CliHarness.tool!(["mkfifo", "--", "${source}/fifo"])?
		}
		what = "update with a ${kind} local source"
		outcome = run!(test, root, ["update"], [])?
		CliHarness.check!(outcome.code != 0, "${what} succeeded")?
		no_effects!(root, what)?
		CliHarness.check!(!CliHarness.present!("${root}/Blueprint.lock"), "${what} published an authority")?
	}
	Script.pass!("a local source holding a link or a fifo, or missing: update fails before any effect")?

	# Older, paused resolution cannot overwrite a newer completed update.
	race = project!(test, "race-existing", CliUpdateTest.wire)?
	race_lock = "${race}/Blueprint.lock"
	Path.write_bytes!(Path.utf8(race_lock), "invalid ".to_utf8().concat(old))?
	race_barrier = "${work}/race-existing-barrier"
	older = paused_update!(test, race, race_barrier, [("BLUEPRINT_GENERATED_ROOT", "${work}/race-existing-a"), ("STUB_NIX_REV", "a")])?
	newer = run!(test, race, ["update"], [("BLUEPRINT_GENERATED_ROOT", "${work}/race-existing-b"), ("STUB_NIX_REV", "b")])?
	CliHarness.exited!(newer, 0, "the newer update")?
	winner = Path.read_bytes!(Path.utf8(race_lock))?
	CliHarness.check!(pinned_rev!(race_lock)? == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "the newer update did not publish its pins")?
	release!(race_barrier)?
	lost = CliHarness.finish!(older, "the older blueprint update")?
	refused!(lost, "authority changed during update", "the older update")?
	CliHarness.check!(Path.read_bytes!(Path.utf8(race_lock))? == winner, "the older update overwrote the newer authority")?
	race_left = CliUpdateTest.leftovers(CliHarness.names!(race)?)
	CliHarness.check!(race_left.is_empty(), "the lost update left ${Str.join_with(race_left, " ")}")?
	published = CliHarness.identity!(race_lock)?
	CliHarness.exited!(run!(test, race, ["gen"], [])?, 0, "gen after the race")?
	CliHarness.check!(CliHarness.identity!(race_lock)? == published, "gen rewrote the authority")?
	# The conflict did not poison a subsequent explicit update.
	CliHarness.exited!(run!(test, race, ["update"], [])?, 0, "an update after the race")?
	Script.pass!("two updates at once: the one that resolved first but published last fails, the newer authority stays, gen does not rewrite it, update works again")?

	# The authority is observed by its raw bytes, in bounded chunks: while an
	# update is paused, any change to them is a conflict, including one past
	# the first chunk, removal and creation. Identical bytes are no change.
	large = CliUpdateTest.noise(Random.seed_u64!()?, 200000)
	observed!(test, { name: "last-byte", initial: [large], replacement: [CliUpdateTest.last_changed(large)], publishes: False })?
	observed!(test, { name: "removed", initial: [old], replacement: [], publishes: False })?
	observed!(test, { name: "created", initial: [], replacement: [[]], publishes: False })?
	observed!(test, { name: "same-bytes", initial: [large], replacement: [large], publishes: True })?
	Script.pass!("authority changed during an update (last of 200000 bytes, removed, created): conflict; the same bytes in a new file: published")?

	# A symlinked authority, or one below a symlinked directory, is refused
	# before it is read: nothing is fetched and the link target is untouched.
	elsewhere = "elsewhere".to_utf8().concat([0xff, 0x00])
	for kind in ["file", "dangling", "parent"] {
		root = project!(test, "linked-authority-${kind}", CliUpdateTest.wire)?
		target = "${work}/linked-authority-${kind}-target"
		Path.create_dir!(Path.utf8(target))?
		Path.write_bytes!(Path.utf8("${target}/Blueprint.lock"), elsewhere)?
		extra = if kind == "parent" [("BLUEPRINT_LOCK", "locks/Blueprint.lock")] else []
		link = if kind == "parent" {
			["ln", "-s", "--", target, "${root}/locks"]
		} else if kind == "file" {
			["ln", "-s", "--", "${target}/Blueprint.lock", "${root}/Blueprint.lock"]
		} else {
			["ln", "-s", "--", "${target}/absent", "${root}/Blueprint.lock"]
		}
		CliHarness.tool!(link)?
		what = "an authority that is a link (${kind})"
		refused!(run!(test, root, ["update"], extra)?, "unsafe", "update with ${what}")?
		refused!(run!(test, root, ["gen"], extra)?, "unsafe", "gen with ${what}")?
		CliHarness.check!(Path.read_bytes!(Path.utf8("${target}/Blueprint.lock"))? == elsewhere, "${what}: the link target was rewritten")?
		CliHarness.check!(CliHarness.names!(target)? == ["Blueprint.lock"], "${what}: something was written beside the link target")?
		no_effects!(root, what)?
	}
	Script.pass!("an authority that is a link, a dangling link or below a linked directory: update and gen refuse it as unsafe, the target is untouched")?

	# A special-file authority must fail, not block inside a file read.
	special = project!(test, "fifo-authority", CliUpdateTest.wire)?
	CliHarness.tool!(["mkfifo", "--", "${special}/Blueprint.lock"])?
	refused!(run!(test, special, ["gen"], [])?, "unsafe", "gen with a fifo authority")?
	refused!(run!(test, special, ["shell", "default"], [])?, "unsafe", "shell with a fifo authority")?
	refused!(run!(test, special, ["update"], [])?, "authority is not a regular file", "update with a fifo authority")?
	no_effects!(special, "a fifo authority")?
	special_left = CliUpdateTest.leftovers(CliHarness.names!(special)?)
	CliHarness.check!(special_left.is_empty(), "a fifo authority left ${Str.join_with(special_left, " ")}")?
	Script.pass!("an authority that is a fifo: gen, shell and update fail without reading it")?

	used = CliHarness.calls!(python_log)?
	CliHarness.check!(used.is_empty(), "blueprint ran a host python3: ${Str.inspect(used)}")?
	Script.pass!("Update preflight, concurrent authority CAS and immutable gen tests passed without a host Python (stubbed Nix/compiler)")
}

expect CliUpdateTest.local_inputs.map(|form| form.kind) == ["build-source", "package-source", "overlay"]
expect CliUpdateTest.local_inputs.all(|form| form.wire.contains("path:./outer/assets") and form.wire.ends_with(")") and form.wire != CliUpdateTest.wire)

expect CliUpdateTest.noise(7, 200000).len() == 200000
expect CliUpdateTest.noise(7, 100) == CliUpdateTest.noise(7, 100) and CliUpdateTest.noise(7, 100) != CliUpdateTest.noise(8, 100)
expect Str.from_utf8(CliUpdateTest.noise(7, 100)).is_err()

expect CliUpdateTest.last_changed([1, 2, '0']) == [1, 2, '1'] and CliUpdateTest.last_changed([1, 2, 3]) == [1, 2, '0']
expect {
	bytes = CliUpdateTest.noise(7, 70000)
	changed = CliUpdateTest.last_changed(bytes)
	changed.len() == bytes.len() and changed != bytes and changed.drop_last(1) == bytes.drop_last(1)
}

expect CliUpdateTest.leftovers(["Blueprint.lock", ".blueprint-write-ab12", "wire.scm", "lock-writer.tmp", ".blueprint"]) == [".blueprint-write-ab12", "lock-writer.tmp"]
