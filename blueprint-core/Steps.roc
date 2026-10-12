# Pure provider results; only the consumer executes these constrained operations.
Steps := { steps : List(Step) }.{

	## A complete ordered sequence, not a scheduler or artifact-name cache.
	## Execute each step's operations, then stage its files, then run its argv
	## (`RocPackages` needs the staged files; see `Operation`).
	## Stop immediately on failure. Each explicit build repeats materialization.
	Step : {
		action : [Generate, Shell(Str), Run(Str), Build(Str)],
		files : List(File),
		argv : List(Str),
		artifacts : List(Artifact),
		operations : List(Operation),
	}

	File : { path : Str, contents : Str }

	## Installables are resolved by the provider, never guessed store paths.
	Artifact : {
		name : Str,
		installable : Str,
		output : Str,
		dependencies : List(Str),
	}

	## Verify all locked local trees before staging files.
	## Isolation names two placeholder texts in this step's files. Before
	## staging, replace each with the caller's /proc/self/ns/{mnt,net} readlink
	## identity (`mnt:[digits]`, `net:[digits]`), observed for this step.
	## Runner: the step's command runs the executor's own executable on
	## `system`. Refuse every step before the first unless the executor runs on
	## that System; then replace the `executable` placeholder text with its
	## absolute path, refusing one holding `"`, `\`, `$` or a control character.
	## RocPackages: the step's command runs Roc programs that depend on these
	## released bundles, named by content hash. Unlike the others, this happens
	## after the step's files are staged and before its argv. For each name
	## whose `<name>/main.roc` is missing from Roc's package cache, publish the
	## bundle there: copy its tree into a fresh directory beside it, then
	## rename that to `<name>`. Never touch one that is already complete. The
	## `locate` argv says where the trees are: it prints a JSON list of
	## `{ "name": ..., "path": ... }`, each path an unpacked bundle the provider
	## has already verified against the Lock. Skip `locate` when nothing is
	## missing.
	## RocBundles: as RocPackages, for a provider that has no unpacked tree to
	## point at. For each bundle whose `<name>/main.roc` is missing from Roc's
	## package cache, make a fresh directory in the cache directory and run
	## `download` and then `unbundle` there, as their working directory, with
	## the text `compiler` replaced by the compiler the Core evaluates the
	## configuration with. `download` writes `<name>.tar.zst`; `unbundle` must
	## succeed, which is the check that those bytes are the bundle the name is
	## the hash of, and leave `<name>/main.roc`. Publish that tree as
	## RocPackages does, and delete the fresh directory whatever happened.
	## Fetch: the step's command needs a released archive unpacked; see
	## `Archive`.
	## Require: the step's command needs programs the host must already have.
	## Run each `probe` with the caller's PATH. One that cannot be started or
	## fails is missing; one that prints something other than `version` asks
	## for, on its first line, is the wrong version. Report every failure
	## together, each by its `tool`, and run nothing further.
	## Search: the step's argv runs with these directories ahead of the
	## caller's PATH, first to last, and may name a program in one of them.
	## Present: the step's command needs programs the machine must already
	## have. Look each `program` up on the caller's PATH, without starting
	## it. Do so for every step of the sequence before the first effect of
	## any of them, and report all that are missing together, each with its
	## `because`; then run nothing.
	## Programs: the step's argv runs with these downloaded programs ahead of
	## the caller's PATH, each under its `name`, and may name one of them; see
	## `Program`. Fetch what every step needs after all `Present` checks and
	## before the first step's command.
	## Serialize workspace use; stop on any failed materialization operation.
	Operation : [
		VerifyTree({ path : Str, digest : Str }),
		Isolation({ mnt : Str, net : Str }),
		Runner({ executable : Str, system : Str }),
		RocPackages({ names : List(Str), locate : List(Str) }),
		RocBundles(
			{
				compiler : Str,
				bundles : List({ name : Str, download : List(Str), unbundle : List(Str) }),
			},
		),
		Fetch(Archive),
		Search(List(Str)),
		Require(List(Probe)),
		Present(List({ program : Str, because : Str })),
		Programs(List(Program)),
	]

	## A download to have on PATH as `name`. Its bytes are those whose SHA-256
	## is `sha256`, in hex, which the Lock recorded: bytes from a cache, a
	## mirror or an earlier run are hashed again before every use and are
	## never trusted. `urls` serve the same bytes; try them in order and take
	## the first that yields that digest. For `File` the bytes are the
	## program. Otherwise they are an archive to unpack whole, and the
	## program is the file at `path` inside it: the tree stays together and
	## `name` refers into it, because a program may find its own files beside
	## its real path.
	Program : { name : Str, urls : List(Str), sha256 : Str, unpack : [File, TarGz, TarXz, Zip], path : Str }

	## `tool` is the declaration being checked, as its author wrote it. `Is`
	## and `Starts` compare the first line the probe prints, trimmed.
	Probe : { tool : Str, probe : List(Str), version : [Any, Is(Str), Starts(Str)] }

	## A released archive to keep unpacked at `directory`. It is there when
	## `<directory>/<program>` is a file; then do nothing, not even learn the
	## digest. Otherwise make a fresh directory beside `directory` and, in
	## every argv here, replace the text `archive` with a new file's path in it
	## and the text `tree` with a new directory's. Then, in order: learn the
	## digest; run `download`; refuse the archive unless its SHA-256 is the
	## digest; run `unpack`; rename each of `moves` within the tree, creating
	## the directory it moves to; rename the tree to `directory`. Losing that
	## rename to another process is success. Delete the fresh directory
	## whatever happened.
	Archive : {
		directory : Str,
		program : Str,
		archive : Str,
		tree : Str,
		download : List(Str),
		unpack : List(Str),
		moves : List({ from : Str, to : Str }),
		digest : Digest,
	}

	## `Recorded` is the SHA-256, in hex, that the provider holds for the
	## archive. `Published` is what the release says when the step runs: `ask`
	## prints JSON holding `assets`, a list of `{ "name": ..., "digest":
	## "sha256:<hex>" }`, and the digest is that of the asset called `asset`.
	## When the caller's environment sets one of `token.variables`, run
	## `authorized` instead and write `token.input` to its standard input,
	## with the text `token.text` replaced by the first such value. The value
	## is a secret: it goes nowhere else, not into an argv, where every process
	## on the host could read it. Refuse one holding `"`, `\` or a control
	## character, which `input` could not carry.
	Digest : [
		Recorded(Str),
		Published(
			{
				asset : Str,
				ask : List(Str),
				authorized : List(Str),
				token : { text : Str, input : Str, variables : List(Str) },
			},
		),
	]
}
