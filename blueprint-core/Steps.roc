# Pure provider results; only the consumer executes these constrained operations.
Steps := { steps : List(Step) }.{

	## A complete ordered sequence, not a scheduler or artifact-name cache.
	## Execute operations and stage files before dispatching the action. Builds
	## prepare an exact provider recipe, then execute that captured recipe.
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
		provider : Str,
		name : Str,
		installable : Str,
		output : Str,
		dependencies : List(Str),
	}

	## SourceFile fetches and verifies original bytes by their flat SHA-256,
	## then substitutes @blueprint-source-file-<sha256>@ in staged files with
	## their JSON-encoded artifact path. Providers stage this marker as a whole
	## JSON value, not inside executable syntax. It never unpacks the file or adds a command to PATH.
	## Verify all locked local trees before staging files.
	## Isolation writes the current mount/network namespace identities as two
	## lines to `directory/witness`, and replaces `placeholder` in the step's
	## argv with that directory. Authorization is runtime data, never staged
	## recipe data. The provider owns how its sandbox mounts the witness.
	## LocalSystem requires a local executor on that system before any effects.
	## RocBundles: the step's command runs Roc programs that depend on these
	## released bundles, each named by the hash of its bytes. Before the
	## step's argv, for each bundle whose `<name>/main.roc` is missing from
	## Roc's package cache, make a fresh directory in the cache directory,
	## download `url` there as `<name>.tar.zst`, and run the compiler the Core
	## evaluates the configuration with as `roc unbundle <name>.tar.zst` in
	## it. That must succeed, which is the check that those bytes are the
	## bundle the name is the hash of, and leave `<name>/main.roc`. Publish
	## that tree: copy it into a fresh directory beside `<name>`, then rename
	## that to `<name>`. Never touch a bundle that is already complete, fetch
	## nothing when none is missing, and delete the fresh directories
	## whatever happened. The same holds whether or not a provider enters the
	## step's environment.
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
		SourceFile({ name : Str, url : Str, sha256 : Str }),
		VerifyTree({ path : Str, digest : Str }),
		Isolation({ directory : Str, placeholder : Str }),
		LocalSystem(Str),
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
