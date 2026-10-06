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
	## Serialize workspace use; stop on any failed materialization operation.
	Operation : [
		VerifyTree({ path : Str, digest : Str }),
		Isolation({ mnt : Str, net : Str }),
		Runner({ executable : Str, system : Str }),
		RocPackages({ names : List(Str), locate : List(Str) }),
	]
}
