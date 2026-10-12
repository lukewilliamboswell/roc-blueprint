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
	## RocBundles: as RocPackages, with no unpacked tree to point at. For each
	## bundle whose `<name>/main.roc` is missing from Roc's package cache,
	## make a fresh directory in the cache directory, download `url` there as
	## `<name>.tar.zst`, and run the compiler the Core evaluates the
	## configuration with as `roc unbundle <name>.tar.zst` in it. That must
	## succeed, which is the check that those bytes are the bundle the name is
	## the hash of, and leave `<name>/main.roc`. Publish that tree as
	## RocPackages does, and delete the fresh directory whatever happened.
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
		RocBundles(List({ name : Str, url : Str })),
		Present(List({ program : Str, because : Str })),
		Programs(List(Program)),
	]

	## A download to have on PATH as `name`. Its bytes are those whose SHA-256
	## is `sha256`, in hex, which the Lock recorded: bytes from a cache, a
	## mirror or an earlier run are hashed again before every use and are
	## never trusted. `urls` serve the same bytes; try them in order and take
	## the first that yields that digest. `size` is their length when one is
	## recorded and 0 when none is: a download of another length is refused
	## as that, before its digest is computed. For `File` the bytes are the
	## program. Otherwise they are an archive to unpack whole, and the
	## program is the file at `path` inside it: the tree stays together and
	## `name` refers into it, because a program may find its own files beside
	## its real path.
	Program : { name : Str, urls : List(Str), sha256 : Str, size : U64, unpack : [File, TarGz, TarXz, Zip], path : Str }
}
