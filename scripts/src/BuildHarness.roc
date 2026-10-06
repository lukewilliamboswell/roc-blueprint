import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import cli.Stderr
import cli.Stdout
import cli.Tcp
import Integrity
import Script

## What the real-Nix build and workflow suites share: a temporary directory,
## the pinned inputs, a `nix` that records every call and adds `--offline`,
## numbered command logs, and the checks every `blueprint` command must pass.
##
## Nothing here is a fake. Every command is the real `./blueprint`, compiler,
## Nix, task or build. Every command also gets a private `XDG_CACHE_HOME`, so
## the Roc packages a task publishes never reach the user's own cache; only
## Nix's download cache inside it is the caller's, through a link.
BuildHarness := [].{

	## The committed pins: nixpkgs from `fixtures/consumer/inputs.lock`, the
	## rest from `fixtures/roc-inputs.lock.json`.
	Pins : { nixpkgs : Source, overlay : Source, compiler : Str, bundles : List(Source) }

	## A flake reference with no moving part and the hash of what it names.
	Source : { ref : Str, nar_hash : Str }

	Suite : {
		name : Str,
		root : Str,
		blueprint : Str,
		work : Str,
		caller : Str,
		logs : Str,
		events : Str,
		tools : Str,
		roc : Str,
		nix : Str,
		variables : List((OsStr, OsStr)),
		pins : Pins,
	}

	## Where one project keeps its files. The authority is always
	## `authority.lock` in the project, so a `Blueprint.lock` is a mistake.
	Layout : { project : Str, workspace : Str, generated : Str, lock : Str }

	## A finished command. `out` and `err` are the output as text.
	Outcome : { code : I32, stdout : List(U8), stderr : List(U8), out : Str, err : Str, requests : List(Str) }

	## What this process serves while a command runs: a loopback listener that
	## echoes a token, or one that serves the files of a directory over HTTP.
	Service : [NoService, Echo(Tcp.Listener, List(U8)), Http(Tcp.Listener, Str)]

	Invocation : { argv : List(Str), cwd : Str, extra : List((Str, Str)), stdin : List(U8), code : I32, service : Service }

	## One recorded call: `nix` with its arguments, or `task` with a workflow
	## fixture task's.
	Event : { kind : Str, argv : List(Str) }

	File : { name : Str, data : List(U8) }

	## Set to `1` to keep a passing run's temporary directory.
	keep_variable = "BLUEPRINT_TEST_KEEP_TMP"

	basic_cli = "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst"

	## `to` as seen from the directory `from`; both absolute. Roc refuses an
	## absolute platform path.
	relative : Str, Str -> Str
	relative = |from, to| {
		parts = |text| text.split_on("/").keep_if(|part| !part.is_empty())
		start = parts(from)
		end = parts(to)
		var $shared = 0
		while $shared < start.len() and $shared < end.len() and start.get($shared) == end.get($shared) {
			$shared = $shared + 1
		}
		Str.join_with(start.drop_first($shared).map(|_| "..").concat(end.drop_first($shared)), "/")
	}

	## Whether `inner` is `outer` or lies beneath it; both absolute.
	within : Str, Str -> Bool
	within = |inner, outer| inner == outer or inner.starts_with("${outer.drop_suffix("/")}/")

	## Byte order, which `Str` does not define.
	order : List(U8), List(U8) -> [Before, Same, After]
	order = |left, right|
		match (left, right) {
			([], []) => Same
			([], _) => Before
			(_, []) => After
			([first, .. as rest], [other, .. as others]) => if first < other Before else if first > other After else order(rest, others)
		}

	sorted : List(Str) -> List(Str)
	sorted = |names| names.sort_with(|left, right| order(left.to_utf8(), right.to_utf8()))

	hex : List(U8) -> Str
	hex = |bytes| Str.from_utf8_lossy(bytes.fold([], |out, byte| out.append(hex_digit(byte // 16)).append(hex_digit(byte % 16))))

	## The arguments of a record: each is followed by a NUL byte.
	arguments : List(U8) -> List(Str)
	arguments = |bytes| {
		var $found = []
		var $current = []
		for byte in bytes {
			if byte == 0 {
				$found = $found.append(Str.from_utf8_lossy($current))
				$current = []
			} else {
				$current = $current.append(byte)
			}
		}
		$found
	}

	## A rendered `Blueprint.roc.in`: `@NAME@` becomes the value given for NAME.
	render : Str, List((Str, Str)) -> Str
	render = |template, values| values.fold(template, |text, (name, value)| text.replace_each("@${name}@", value))

	## The values every fixture template takes from the pins.
	pinned_values : Pins -> List((Str, Str))
	pinned_values = |pins| [
		("PACKAGES", pins.nixpkgs.ref),
		("ROC_OVERLAY", pins.overlay.ref),
		("ROC_COMPILER", pins.compiler),
		("ROC_PACKAGES", Str.join_with(pins.bundles.map(|bundle| "\"${bundle.ref}\""), ", ")),
	]

	## Decode the two committed lock files.
	pins : Str, Str -> Try(Pins, [PinsInvalid(Str)])
	pins = |consumer_lock, roc_inputs| {
		consumer : Try({ nodes : { nixpkgs : { locked : { owner : Str, repo : Str, rev : Str, narHash : Str } } } }, _)
		consumer = Json.parse(consumer_lock)
		nixpkgs = consumer.map_err(|_| PinsInvalid("fixtures/consumer/inputs.lock does not pin nixpkgs by revision and hash"))?.nodes.nixpkgs.locked
		roc : Try({ compiler : Str, overlay : { owner : Str, repo : Str, rev : Str, nar_hash : Str }, bundles : List({ url : Str, nar_hash : Str }) }, _)
		roc = Json.parse(roc_inputs)
		decoded = roc.map_err(|_| PinsInvalid("fixtures/roc-inputs.lock.json is not a compiler, an overlay and bundles"))?
		if !decoded.bundles.any(|bundle| bundle.url == basic_cli) {
			return Err(PinsInvalid("fixtures/roc-inputs.lock.json does not pin the basic-cli release the fixture scripts name"))
		}
		Ok({
			nixpkgs: { ref: "github:${nixpkgs.owner}/${nixpkgs.repo}/${nixpkgs.rev}", nar_hash: nixpkgs.narHash },
			overlay: { ref: "github:${decoded.overlay.owner}/${decoded.overlay.repo}/${decoded.overlay.rev}", nar_hash: decoded.overlay.nar_hash },
			compiler: decoded.compiler,
			bundles: decoded.bundles.map(|bundle| { ref: bundle.url, nar_hash: bundle.nar_hash }),
		})
	}

	require! : Bool, Str => Try({}, _)
	require! = |holds, message| if holds Ok({}) else Script.fail!(message)

	## Run a suite from the repository root in a new temporary directory. A
	## failure keeps the directory and says where it is.
	run! : Path, Str, (Suite => Try({}, _)) => Try({}, _)
	run! = |root, name, gates!| {
		suite = start!(root, name)?
		match gates!(suite) {
			Ok({}) => {
				if (Env.var_str!(OsStr.from_str(keep_variable)) ?? "") == "1" {
					Script.info!("KEPT", "${name} fixture and logs: ${suite.work}")
				} else {
					# The authority and some fixture directories are read-only.
					_ = Cmd.new("chmod").args(["-R", "u+w", "--", OsStr.from_str(suite.work)]).exec_cmd!()
					_ = Path.delete_all!(Path.utf8(suite.work))
					Ok({})
				}
			}
			Err(reason) => {
				_ = Stderr.line!("${name} FAILED; retained fixture and logs: ${suite.work}")
				Err(reason)
			}
		}
	}

	## Fetch and realise every pinned input, with the network, through the real
	## Nix. This is the only step that may download: every later call goes
	## through the recording `nix`, which adds `--offline`. Each reference is the
	## one the fixtures use, and must still name the bytes the pins record.
	warm! : Suite => Try({}, _)
	warm! = |suite| {
		Stdout.line!("RUN  nix build --no-link --file fixtures/warm.nix")?
		built = real_nix!(suite, ["build", "--no-link", "--file", "${suite.root}/fixtures/warm.nix"])?
		if built.code != 0 {
			return Script.fail!("could not fetch and realise the pinned fixture inputs:\n${built.err}")
		}
		for source in [suite.pins.nixpkgs, suite.pins.overlay].concat(suite.pins.bundles) {
			fetched = real_nix!(suite, ["flake", "prefetch", "--json", source.ref])?
			if fetched.code != 0 {
				return Script.fail!("could not fetch ${source.ref}:\n${fetched.err}")
			}
			observed : Try({ hash : Str }, _)
			observed = Json.parse(fetched.out)
			require!(
				observed.map_ok(|value| value.hash) == Ok(source.nar_hash),
				"${source.ref} no longer has the pinned hash ${source.nar_hash}: ${fetched.out}",
			)?
		}
		Script.pass!("pinned inputs fetched and realised: nixpkgs, the Roc overlay, Roc ${suite.pins.compiler} and ${suite.pins.bundles.len().to_str()} Roc bundles")
	}

	## Compile one of the suite's own Roc programs into the temporary directory.
	build_tool! : Suite, Str, Str => Try({}, _)
	build_tool! = |suite, source, output| {
		Stdout.line!("RUN  roc build ${source}")?
		built = Cmd.new_str(suite.roc).args_str(["build", "${suite.root}/${source}", "--output=${output}"])
			.cwd(Path.utf8(suite.root))
			.run!()
		match built {
			Ok({ status: Exited(0), .. }) => Ok({})
			Ok({ stderr_bytes, stdout_bytes, .. }) => Script.fail!("could not build ${source}:\n${Str.from_utf8_lossy(stdout_bytes)}${Str.from_utf8_lossy(stderr_bytes)}")
			Err(_) => Script.fail!("could not run ${suite.roc} to build ${source}")
		}
	}

	layout : Str -> Layout
	layout = |project| { project, workspace: "${project}/work", generated: "${project}/generated", lock: "${project}/authority.lock" }

	## Run a command with the suite's environment, keep its numbered argv,
	## stdout and stderr, and insist on its exit code.
	command! : Suite, Invocation => Try(Outcome, _)
	command! = |suite, invocation| {
		number = Path.list!(Path.utf8(suite.logs))?.keep_if(|entry| Path.display(entry).ends_with(".argv")).len() + 1
		stem = "${suite.logs}/${padded(number)}"
		Path.write_utf8!(Path.utf8("${stem}.argv"), "${Str.inspect(invocation.argv)}\n")?
		Stdout.line!("RUN  ${shown(invocation.argv)}")?
		ran = serve_while!(prepared(suite, invocation), invocation.service)?
		Path.write_bytes!(Path.utf8("${stem}.out"), ran.stdout)?
		Path.write_bytes!(Path.utf8("${stem}.err"), ran.stderr)?
		require!(
			ran.code == invocation.code,
			"${Str.inspect(invocation.argv)}: exit ${ran.code.to_str()}, expected ${invocation.code.to_str()}; logs ${stem}.*\n${ran.err}",
		)?
		Ok(ran)
	}

	## Run `./blueprint` in a project and insist that it left the authority
	## alone, asked Nix for no lock change, kept Nix from changing one itself,
	## made no second authority and let no argument reach a shell. Only `update`
	## may write the authority.
	blueprint! : Suite, Layout, List(Str), { code : I32, stdin : List(U8), service : Service } => Try(Outcome, _)
	blueprint! = |suite, place, args, options| {
		before = authority!(place)?
		start = events!(suite)?.len()
		ran = command!(
			suite,
			{
				argv: [suite.blueprint].concat(args),
				cwd: suite.caller,
				extra: [
					("BLUEPRINT_ROOT", place.project),
					("BLUEPRINT_WORKSPACE", place.workspace),
					("BLUEPRINT_GENERATED_ROOT", place.generated),
					("BLUEPRINT_LOCK", "authority.lock"),
				],
				stdin: options.stdin,
				code: options.code,
				service: options.service,
			},
		)?
		if args.first() != Ok("update") {
			require!(authority!(place)? == before, "${Str.inspect(args)} changed the authoritative lock")?
			for event in events!(suite)?.drop_first(start).keep_if(|entry| entry.kind == "nix") {
				require!(!locks(event.argv), "implicit locking: ${Str.inspect(event.argv)}")?
				require!(!enters(event.argv) or read_only(event.argv), "Nix could have changed a lock: ${Str.inspect(event.argv)}")?
			}
		}
		require!(!exists!("${place.project}/Blueprint.lock"), "second authority")?
		require!(!exists!("${place.project}/INJECTED"), "argv injection")?
		Ok(ran)
	}

	## A `blueprint` command that must succeed.
	ok! : Suite, Layout, List(Str) => Try(Outcome, _)
	ok! = |suite, place, args| blueprint!(suite, place, args, { code: 0, stdin: [], service: NoService })

	## A `blueprint` command that must exit 1 and say `text` on stderr.
	refused! : Suite, Layout, List(Str), Str => Try(Outcome, _)
	refused! = |suite, place, args, text| {
		ran = blueprint!(suite, place, args, { code: 1, stdin: [], service: NoService })?
		require!(ran.err.contains(text), "${Str.inspect(args)} did not say \"${text}\":\n${ran.err}")?
		Ok(ran)
	}

	## Every recorded call so far, in order.
	events! : Suite => Try(List(Event), _)
	events! = |suite| {
		var $events = []
		for name in sorted(names!(suite.events)?) {
			kind = name.split_on(".").last() ?? ""
			$events = $events.append({ kind, argv: arguments(Path.read_bytes!(Path.utf8("${suite.events}/${name}"))?) })
		}
		Ok($events)
	}

	## The authority's bytes, inode, modification time and mode, or `absent`.
	authority! : Layout => Try(Str, _)
	authority! = |place|
		if exists!(place.lock) {
			Ok("${Integrity.digest(Path.read_bytes!(Path.utf8(place.lock))?)} ${Str.join_with(stat!([place.lock])?, "")}")
		} else {
			Ok("absent")
		}

	## The regular files beneath a directory with their bytes, ordered by name.
	## Bytes, not times, so that a comparison detects a staging mutation and
	## nothing else. A missing directory has none.
	tree! : Str => Try(List(File), _)
	tree! = |directory| {
		if !(Path.is_dir!(Path.utf8(directory)) ?? Bool.False) {
			return Ok([])
		}
		var $files = []
		for name in sorted(walk!(directory, "")?) {
			file = Path.utf8("${directory}/${name}")
			if Path.is_file!(file)? {
				$files = $files.append({ name, data: Path.read_bytes!(file)? })
			}
		}
		Ok($files)
	}

	## A directory, every entry beneath it and the directory itself: bytes,
	## inode, modification time and mode. A missing directory has none.
	snapshot! : Str => Try(List(Str), _)
	snapshot! = |directory| {
		if !exists!(directory) {
			return Ok([])
		}
		names = sorted(walk!(directory, "")?)
		paths = [directory].concat(names.map(|name| "${directory}/${name}"))
		stats = stat!(paths)?
		var $lines = []
		var $index = 0
		for entry in paths {
			file = Path.utf8(entry)
			contents = if Path.is_file!(file)? Integrity.digest(Path.read_bytes!(file)?) else "-"
			$lines = $lines.append("${entry} ${contents} ${stats.get($index) ?? "?"}")
			$index = $index + 1
		}
		Ok($lines)
	}

	## The entry names of a directory, or none when it does not exist.
	names! : Str => Try(List(Str), _)
	names! = |directory| {
		if !(Path.is_dir!(Path.utf8(directory)) ?? Bool.False) {
			return Ok([])
		}
		Ok(Path.list!(Path.utf8(directory))?.map(|entry| Str.from_utf8_lossy(base(Path.to_os_str(entry).to_bytes()))))
	}

	## Whether anything, a dangling link included, has this name.
	exists! : Str => Bool
	exists! = |target| Path.type!(Path.utf8(target)).is_ok()

	## basic-cli cannot make a link, a FIFO or change a mode, and reports no
	## inode: coreutils does, by argv.
	link! : Str, Str => Try({}, _)
	link! = |target, name| tool!("ln", ["-s", "--", target, name])

	fifo! : Str => Try({}, _)
	fifo! = |name| tool!("mkfifo", ["--", name])

	mode! : Str, Path => Try({}, _)
	mode! = |bits, file|
		Cmd.new("chmod").args([OsStr.from_str(bits), "--", Path.to_os_str(file)]).exec_cmd!().map_err(|_| ToolFailed("chmod ${bits} ${Path.display(file)}"))

	tool! : Str, List(Str) => Try({}, _)
	tool! = |program, args|
		Cmd.new_str(program).args_str(args).exec_cmd!().map_err(|_| ToolFailed("${program} ${Str.join_with(args, " ")}"))

	## Where a program is, searching `PATH` as a shell would.
	which! : Str => Try(Str, _)
	which! = |program| {
		for directory in (Env.var_str!("PATH") ?? "").split_on(":").keep_if(|part| !part.is_empty()) {
			candidate = Path.utf8("${directory}/${program}")
			if (Path.is_file!(Path.canonicalize!(candidate) ?? candidate) ?? Bool.False) and (Path.is_executable!(candidate) ?? Bool.False) {
				return Ok("${directory}/${program}")
			}
		}
		Script.fail!("${program} is required and is not on PATH")
	}

	## A loopback listener on a port the operating system chooses.
	listen! : () => Try({ listener : Tcp.Listener, port : U16 }, _)
	listen! = || {
		listener = Tcp.listen!("127.0.0.1", 0, 5_000)?
		Ok({ listener, port: listener.local_port!()? })
	}
}

## A command on one line: the program's name, and each argument that is not
## a plain word quoted.
shown : List(Str) -> Str
shown = |argv| {
	plain = |arg| !arg.is_empty() and arg.to_utf8().all(|byte| byte > ' ' and byte < 127 and byte != '"' and byte != '\\' and byte != '\'')
	program = Str.from_utf8_lossy(base((argv.first() ?? "").to_utf8()))
	Str.join_with([program].concat(argv.drop_first(1).map(|arg| if plain(arg) arg else Json.to_str(arg))), " ")
}

## Three digits, so that log names sort in the order the commands ran.
padded : U64 -> Str
padded = |number| if number < 10 "00${number.to_str()}" else if number < 100 "0${number.to_str()}" else number.to_str()

hex_digit : U8 -> U8
hex_digit = |nibble| if nibble < 10 '0' + nibble else 'a' + (nibble - 10)

base : List(U8) -> List(U8)
base = |bytes| bytes.fold([], |name, byte| if byte == '/' [] else name.append(byte))

## `nix flake update` and `nix flake lock` write a lock.
locks : List(Str) -> Bool
locks = |argv| argv.take_first(2) == ["flake", "update"] or argv.take_first(2) == ["flake", "lock"]

## `nix develop` and `nix build` would update a stale lock unless told not to.
enters : List(Str) -> Bool
enters = |argv| argv.first() == Ok("develop") or argv.first() == Ok("build")

read_only : List(Str) -> Bool
read_only = |argv| argv.contains("--no-update-lock-file") and argv.contains("--no-write-lock-file")

## Every name beneath a directory, relative to it.
walk! : Str, Str => Try(List(Str), _)
walk! = |directory, prefix| {
	var $found = []
	for entry in Path.list!(Path.utf8(if prefix.is_empty() directory else "${directory}/${prefix}"))? {
		leaf = Str.from_utf8_lossy(base(Path.to_os_str(entry).to_bytes()))
		name = if prefix.is_empty() leaf else "${prefix}/${leaf}"
		$found = $found.append(name)
		if Path.type!(entry)? == IsDir {
			$found = $found.concat(walk!(directory, name)?)
		}
	}
	Ok($found)
}

## Inode, modification time to the nanosecond and mode of each file, in order.
stat! : List(Str) => Try(List(Str), _)
stat! = |paths| {
	output = Cmd.new("stat").args(["-c", "%i %.9Y %f", "--"]).args_str(paths).exec_output!()
		.map_err(|_| ToolFailed("stat ${Str.join_with(paths, " ")}"))?
	Ok(output.stdout_utf8.split_on("\n").keep_if(|line| !line.is_empty()))
}

## The real Nix, unrecorded and with the network, for `warm!` alone.
real_nix! : BuildHarness.Suite, List(Str) => Try(BuildHarness.Outcome, _)
real_nix! = |suite, args| {
	ran = Cmd.new_str(suite.nix).args_str(args).cwd(Path.utf8(suite.caller)).clear_envs().envs(suite.variables).timeout_ms(1_800_000).run!()
	match ran {
		Ok(output) => Ok(outcome(output, []))
		Err(_) => Script.fail!("could not run ${suite.nix} ${Str.join_with(args, " ")}")
	}
}

outcome : Cmd.RunOutput, List(Str) -> BuildHarness.Outcome
outcome = |output, requests| {
	code = match output.status {
		Exited(exit_code) => exit_code
		Signaled(signal) => 128 + signal
	}
	{ code, stdout: output.stdout_bytes, stderr: output.stderr_bytes, out: Str.from_utf8_lossy(output.stdout_bytes), err: Str.from_utf8_lossy(output.stderr_bytes), requests }
}

## The suite's variables with the invocation's own replacing any of that name.
prepared : BuildHarness.Suite, BuildHarness.Invocation -> Cmd
prepared = |suite, invocation| {
	replaced = invocation.extra.map(|(name, _)| OsStr.from_str(name))
	kept = suite.variables.keep_if(|(name, _)| !replaced.contains(name))
	(program, rest) = match invocation.argv {
		[first, .. as others] => (first, others)
		[] => ("", [])
	}
	command = Cmd.new_str(program).args_str(rest)
		.cwd(Path.utf8(invocation.cwd))
		.clear_envs()
		.envs(kept)
		.envs_str(invocation.extra)
		.stdout(Capture)
		.stderr(Capture)
		.timeout_ms(300_000)
	if invocation.stdin.is_empty() command.stdin(Null) else command.stdin(Bytes(invocation.stdin))
}

## Run a command to completion. With a service, this process also answers
## connections while the command runs: basic-cli has no threads, so it takes
## turns between asking whether the command has finished and accepting.
serve_while! : Cmd, BuildHarness.Service => Try(BuildHarness.Outcome, _)
serve_while! = |command, service| {
	if service == NoService {
		return match command.run!() {
			Ok(output) => Ok(outcome(output, []))
			Err(Timeout(_)) => Script.fail!("timed out: ${Cmd.to_str(command)}")
			Err(_) => Script.fail!("could not run: ${Cmd.to_str(command)}")
		}
	}
	child = command.spawn!().map_err(|_| SpawnFailed(Cmd.to_str(command)))?
	var $requests = []
	var $finished = []
	while $finished.is_empty() {
		$finished = child.try_wait!().map_err(|_| WaitFailed(Cmd.to_str(command)))?
		if $finished.is_empty() {
			$requests = $requests.concat(serve_once!(service)?)
		}
	}
	match $finished {
		[output, ..] => Ok(outcome(output, $requests))
		[] => Script.fail!("lost the command: ${Cmd.to_str(command)}")
	}
}

## Accept at most one connection, waiting briefly, and answer it. Returns the
## paths an HTTP client asked for with GET.
serve_once! : BuildHarness.Service => Try(List(Str), _)
serve_once! = |service|
	match service {
		NoService => Ok([])
		Echo(listener, token) =>
			match listener.accept!(100) {
				Ok(stream) => {
					# Return the token only to a peer that already holds it.
					if stream.read_exactly!(token.len(), 5_000) == Ok(token) {
						_ = stream.write!(token, 5_000)
					}
					Ok([])
				}
				Err(TcpListenErr(TimedOut)) => Ok([])
				Err(_) => Script.fail!("the echo listener failed")
			}

		Http(listener, directory) =>
			match listener.accept!(100) {
				Ok(stream) => serve_file!(stream, directory)
				Err(TcpListenErr(TimedOut)) => Ok([])
				Err(_) => Script.fail!("the HTTP listener failed")
			}
	}

## Answer one HTTP request for a file of `directory`, then close.
serve_file! : Tcp.Stream, Str => Try(List(Str), _)
serve_file! = |stream, directory| {
	request = stream.read_line!(8_192, 5_000) ?? ""
	var $header = request
	while $header.trim() != "" {
		$header = stream.read_line!(8_192, 5_000) ?? ""
	}
	(method, target) = match request.trim().split_on(" ") {
		[first, second, ..] => (first, second)
		_ => ("", "")
	}
	name = target.drop_prefix("/")
	file = Path.utf8("${directory}/${name}")
	plain = !name.is_empty() and !name.contains("/") and !name.starts_with(".")
	if plain and (method == "GET" or method == "HEAD") and (Path.is_file!(file) ?? Bool.False) {
		body = Path.read_bytes!(file)?
		_ = stream.write_utf8!(http_head("200 OK", body.len()), 5_000)
		if method == "GET" {
			_ = stream.write!(body, 30_000)
			return Ok([target])
		}
		Ok([])
	} else {
		_ = stream.write_utf8!(http_head("404 Not Found", 0), 5_000)
		Ok([])
	}
}

## HTTP separates header lines with CRLF.
http_head : Str, U64 -> Str
http_head = |status, length|
	Str.join_with(["HTTP/1.1 ${status}", "Content-Type: application/octet-stream", "Content-Length: ${length.to_str()}", "Connection: close", "", ""], "\r\n")

## Check the host, create the temporary directory, find the tools and install
## the recording `nix`.
start! : Path, Str => Try(BuildHarness.Suite, _)
start! = |root_path, name| {
	if Env.platform!() != { arch: X64, os: LINUX } {
		return Script.fail!("${name} requires x86_64 Linux; unsupported is not a pass")
	}
	root = Path.to_str(Path.canonicalize!(root_path)?)?
	blueprint = "${root}/blueprint"
	if !(Path.is_file!(Path.utf8(blueprint)) ?? Bool.False) {
		return Script.fail!("./blueprint is missing; build it with `roc build blueprint-cli/main.roc --output=./blueprint`")
	}
	consumer_lock = Path.read_utf8!(Path.utf8("${root}/fixtures/consumer/inputs.lock"))?
	roc_inputs = Path.read_utf8!(Path.utf8("${root}/fixtures/roc-inputs.lock.json"))?
	pinned = match BuildHarness.pins(consumer_lock, roc_inputs) {
		Ok(decoded) => decoded
		Err(PinsInvalid(reason)) => return Script.fail!(reason)
	}
	# Respect the caller's TMPDIR: a project can be large.
	work = Path.to_str(Path.canonicalize!(Env.create_temp_dir_with_prefix!("blueprint-${name}-")?)?)?
	caller = "${work}/unrelated-cwd"
	logs = "${work}/logs"
	events = "${work}/events"
	tools = "${work}/tools"
	cache = "${work}/cache"
	for directory in [caller, logs, events, tools, cache, "${work}/bin"] {
		Path.create_dir!(Path.utf8(directory))?
	}
	requested = Env.var_str!("ROC") ?? "roc"
	found = if requested.contains("/") requested else BuildHarness.which!(requested)?
	roc = Path.to_str(Path.canonicalize!(Path.utf8(found)).map_err(|_| NoCompiler(found))?)?
	nix = BuildHarness.which!("nix")?

	# Roc's caches are private to this run. Nix's download cache is the
	# caller's, so a source fetched once is not fetched again by every run.
	home = Env.var_str!("HOME") ?? ""
	caller_cache = Env.var_str!("XDG_CACHE_HOME") ?? "${home}/.cache"
	if BuildHarness.within(cache, "${home}/.cache") or BuildHarness.within(cache, caller_cache) {
		return Script.fail!("refusing to run: the test cache ${cache} is inside the caller's cache; set TMPDIR elsewhere")
	}
	Path.create_all!(Path.utf8("${caller_cache}/nix"))?
	BuildHarness.link!("${caller_cache}/nix", "${cache}/nix")?

	search = Env.var!("PATH") ?? OsStr.from_str("")
	replaced = ["NO_COLOR", "NIX_CONFIG", "ROC", "PATH", "XDG_CACHE_HOME", "NIX_RECORDER_EVENTS", "NIX_RECORDER_REAL"].map(OsStr.from_str)
	inherited = Env.dict!().keep_if(|(variable, _)| !OsStr.display(variable).starts_with("BLUEPRINT_") and !replaced.contains(variable))
	# Remote builders would invalidate a host-local isolation proof.
	nix_config = "${Env.var_str!("NIX_CONFIG") ?? ""}\nbuilders =\n"
	variables = inherited.concat([
		(OsStr.from_str("NO_COLOR"), OsStr.from_str("1")),
		(OsStr.from_str("NIX_CONFIG"), OsStr.from_str(nix_config)),
		(OsStr.from_str("ROC"), OsStr.from_str(roc)),
		(OsStr.from_str("PATH"), OsStr.unix_bytes("${work}/bin:".to_utf8().concat(search.to_bytes()))),
		(OsStr.from_str("XDG_CACHE_HOME"), OsStr.from_str(cache)),
		(OsStr.from_str("NIX_RECORDER_EVENTS"), OsStr.from_str(events)),
		(OsStr.from_str("NIX_RECORDER_REAL"), OsStr.from_str(nix)),
	])
	suite = { name, root, blueprint, work, caller, logs, events, tools, roc, nix, variables, pins: pinned }
	Script.info!("INFO", "${name} in ${work}; Roc ${roc}; Nix ${nix}")?
	# Transparent recorder, never a fake backend: every call runs Nix.
	BuildHarness.build_tool!(suite, "fixtures/recording-nix/main.roc", "${work}/bin/nix")?
	Ok(suite)
}

expect BuildHarness.relative("/tmp/work/project", "/home/me/repo/blueprint-platform/main.roc") == "../../../home/me/repo/blueprint-platform/main.roc"
expect BuildHarness.relative("/repo", "/repo/blueprint-platform/main.roc") == "blueprint-platform/main.roc"
expect BuildHarness.within("/home/me/.cache/tmp/work/cache", "/home/me/.cache") and !BuildHarness.within("/home/me/.cache-other", "/home/me/.cache")
expect BuildHarness.hex([0, 255, 16, 'a']) == "00ff1061"
expect BuildHarness.sorted(["b", "a", "", "aa", "B"]) == ["", "B", "a", "aa", "b"]
expect BuildHarness.arguments("build".to_utf8().append(0).append(0).concat("a b".to_utf8()).append(0)) == ["build", "", "a b"]
expect BuildHarness.arguments([]) == []
expect BuildHarness.render("a @X@ b @Y@ @X@", [("X", "1"), ("Y", "2")]) == "a 1 b 2 1"
expect locks(["flake", "update", "--flake", "x"]) and locks(["flake", "lock"]) and !locks(["flake", "metadata"]) and !locks(["build"])
expect enters(["develop", "x"]) and enters(["build"]) and !enters(["eval"]) and !enters([])
expect read_only(["build", "--no-update-lock-file", "--no-write-lock-file"]) and !read_only(["build", "--no-write-lock-file"])
expect http_head("200 OK", 3) == "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 3\r\nConnection: close\r\n\r\n"
expect shown(["/repo/blueprint", "run", "args", "--", "", "two words", "line\nbreak"]) == "blueprint run args -- \"\" \"two words\" \"line\\nbreak\""
expect padded(7) == "007" and padded(42) == "042" and padded(123) == "123"
expect base("/work/logs/001.argv".to_utf8()) == "001.argv".to_utf8()

expect {
	consumer = "{\"nodes\":{\"nixpkgs\":{\"locked\":{\"owner\":\"NixOS\",\"repo\":\"nixpkgs\",\"rev\":\"abc\",\"narHash\":\"sha256-n\",\"type\":\"github\"}}}}"
	roc = "{\"compiler\":\"nightly-1\",\"overlay\":{\"owner\":\"roc-lang\",\"repo\":\"roc-overlay\",\"rev\":\"def\",\"nar_hash\":\"sha256-o\"},\"bundles\":[{\"url\":\"${BuildHarness.basic_cli}\",\"nar_hash\":\"sha256-b\"}]}"
	BuildHarness.pins(consumer, roc) == Ok({
		nixpkgs: { ref: "github:NixOS/nixpkgs/abc", nar_hash: "sha256-n" },
		overlay: { ref: "github:roc-lang/roc-overlay/def", nar_hash: "sha256-o" },
		compiler: "nightly-1",
		bundles: [{ ref: BuildHarness.basic_cli, nar_hash: "sha256-b" }],
	})
}

# The fixture scripts name basic-cli; a lock without it cannot serve them.
expect {
	consumer = "{\"nodes\":{\"nixpkgs\":{\"locked\":{\"owner\":\"NixOS\",\"repo\":\"nixpkgs\",\"rev\":\"abc\",\"narHash\":\"sha256-n\"}}}}"
	roc = "{\"compiler\":\"nightly-1\",\"overlay\":{\"owner\":\"o\",\"repo\":\"r\",\"rev\":\"def\",\"nar_hash\":\"sha256-o\"},\"bundles\":[]}"
	BuildHarness.pins(consumer, roc).is_err() and BuildHarness.pins("{}", roc).is_err() and BuildHarness.pins(consumer, "{}").is_err()
}
