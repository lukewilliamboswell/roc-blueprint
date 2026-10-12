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
	## Fetch: the step's command needs a released archive unpacked; see
	## `Archive`.
	## Serialize workspace use; stop on any failed materialization operation.
	Operation : [
		VerifyTree({ path : Str, digest : Str }),
		Isolation({ mnt : Str, net : Str }),
		Runner({ executable : Str, system : Str }),
		RocPackages({ names : List(Str), locate : List(Str) }),
		Fetch(Archive),
	]

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
