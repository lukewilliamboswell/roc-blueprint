import ir.Ir

## The contract between the `blueprint` CLI and a build backend (Nix today;
## Guix or others later).
##
## A backend is pure data and pure functions: it renders the IR into files
## and says which commands to run. `main.roc` does every effect: it writes
## the files into `.blueprint/`, keeps `Blueprint.lock` in sync with the
## backend's `lock_file`, and runs the commands. Every command is an argv
## (program first) and receives the generated directory, e.g. `.blueprint`.
Backend := {

	## Short name, e.g. "nix". `raw` IR entries whose `backend` equals it
	## are for this backend; others are ignored.
	name : Str,

	## The IR `requires` features this backend implements, e.g. ["raw"].
	features : List(Str),

	## The files to write into the generated directory, or a message saying
	## why this IR can't be rendered.
	render : Ir -> Try(List(File), Str),

	## The lock file inside the generated directory that mirrors
	## `Blueprint.lock`.
	lock_file : Str,

	## dir -> argv that (re)creates the lock file without upgrading inputs.
	lock : Str -> List(Str),

	## dir -> argv that upgrades every input in the lock file.
	update : Str -> List(Str),

	## dir, shell -> argv that enters a shell interactively.
	enter_shell : Str, Str -> List(Str),

	## dir, shell, command -> argv that runs command inside a shell.
	run_in_shell : Str, Str, List(Str) -> List(Str),
}.{

	## A generated file. `backend.render` returns relative paths;
	## `NixBackend.render_files` returns absolute, caller-layout paths.
	File : { path : Str, contents : Str }

	## Caller-owned paths. The renderer never reads these locations.
	Layout : { project_root : Str, workspace : Str, generated_root : Str, lock_path : Str }

	## Already-resolved Nix lock bytes; obtaining them is the caller's job.
	LockedInputs : { contents : Str }
}
