# Pure backend results; only the consumer executes these constrained operations.
Plan := {
	files : List(File),
	argv : List(Str),
	artifacts : List(Artifact),
	operations : List(Operation),
}.{
	File : { path : Str, contents : Str }

	## Installables are resolved by the backend, never guessed store paths.
	Artifact : {
		name : Str,
		installable : Str,
		output : Str,
		dependencies : List(Str),
	}

	## Verify all locked local trees before snapshotting or staging files.
	## Snapshot exclusions are absolute paths or VCS metadata basenames.
	## The Nix executor also publishes destination + ".isolation.json": caller
	## /proc/self/ns/{mnt,net} readlink identities, separate from source bytes.
	## Serialize workspace use; stop on any failed materialization operation.
	Operation : [
		VerifyLocal({ path : Str, nar_hash : Str }),
		Snapshot({ root : Str, destination : Str, exclude : List(Str) }),
	]
}
