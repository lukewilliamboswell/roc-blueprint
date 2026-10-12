# The Core <-> Provider contract: pure functions only. The Core (a consumer
# such as the blueprint CLI) performs every effect these results describe.
# See docs/architecture.adoc, invariant 7.
import Spec
import Request
import Layout
import Steps
import Lock

Provider := {
	## Short name, e.g. "nix". Spec `raw` entries naming it are for this provider.
	name : Str,

	## The Spec `requires` features this provider implements.
	features : List(Str),

	## Inspect: the files this provider would generate for the whole Spec.
	render : Spec -> Try(List(File), Str),

	## Reject a request this provider cannot realise, before any effect.
	preflight : Spec, Request, Str, Layout -> Try({}, Str),

	## Fetch + Realise + Activate: the ordered steps for one request, from the
	## Lock only. Never resolves or changes pins. The Core has already rejected
	## a stale Lock.
	realise : Spec, Request, Str, Layout, Lock -> Try(Steps, [InvalidLock(Str), Unrealisable(Str)]),

	## Resolve: what the Core must stage and run to produce a native lock, for
	## every input or for the named ones alone.
	resolve : Spec, Str, Layout, Update -> Try(Resolution, Str),

	## Resolve: turn the native lock the resolve command wrote into a Lock. The
	## Core supplies its own tree digests for `Resolution.locals` (by path) and
	## records the Spec's intent in the result before publishing.
	lock_from_native : Spec, Layout, Str, List({ path : Str, digest : Str }) -> Try(Lock, Str),

	## How to obtain the Roc release with this tag on a System, under a
	## Layout. The Core does so when no compatible compiler is at hand to
	## evaluate the configuration.
	compiler : Str, Str, Layout -> Try(Compiler, Str),
}.{

	## `Printed`: run the argv; it prints a directory whose `bin/roc` is the
	## compiler. `Fetched`: keep the archive as `Steps.Archive` says; the
	## compiler is its `<directory>/<program>`.
	Compiler : [Printed(List(Str)), Fetched(Steps.Archive)]

	## Inspection returns relative names; executable Steps files are absolute.
	File : { path : Str, contents : Str }

	## Which pins an update resolves again. `Named` moves only the inputs with
	## these names and keeps every other pin of the Lock, which the Core has
	## already found current for the Spec. Local inputs hold no remote pin and
	## are read again either way.
	Update : [All, Named(List(Str), Lock)]

	## `files` are staged, `locals` are checked for safety and hashed by the
	## Core, then `argv` runs and writes `native_lock`, which `lock_from_native`
	## converts.
	Resolution : {
		files : List(Steps.File),
		locals : List(Str),
		argv : List(Str),
		native_lock : Str,
	}
}
