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

	## Resolve: what the Core must stage and run to produce a native lock.
	resolve : Spec, Str, Layout -> Try(Resolution, Str),

	## Resolve: turn the native lock the resolve command wrote into a Lock. The
	## Core records the Spec's intent in it before publishing.
	lock_from_native : Spec, Layout, Str -> Try(Lock, Str),
}.{

	## Inspection returns relative names; executable Steps files are absolute.
	File : { path : Str, contents : Str }

	## `files` are staged, `locals` are checked for safety, then `argv` runs and
	## writes `native_lock`, which `lock_from_native` converts.
	Resolution : {
		files : List(Steps.File),
		locals : List(Str),
		argv : List(Str),
		native_lock : Str,
	}
}
