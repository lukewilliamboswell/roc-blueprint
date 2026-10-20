# The Core <-> Provider contract: pure functions only. The Core (a consumer
# such as the blueprint CLI) performs every effect these results describe.
# See docs/architecture.adoc, invariant 7.
import Spec
import Request
import Layout
import Steps
import Lock
import Value

Provider := {
	## Short name, e.g. "nix". Spec `raw` entries naming it are for this provider.
	name : Str,

	## The Spec `requires` features this provider implements.
	features : List(Str),

	## Whether this provider supplies the tools of a package source with this
	## intent. The Core asks a provider to realise an environment only when
	## the environment has a tool from such a source; what an environment
	## fetches or expects of the machine is the Core's own.
	realises : Spec.Provider -> Bool,

	## Inspect: the files this provider would generate for the whole Spec.
	render : Spec -> Try(List(File), Str),

	## Read committed authority without a Spec, filesystem, host or effects.
	## Entries carry content identities and provider metadata for external
	## consumers. The provider validates its private hints before projecting.
	inspect_lock : Lock -> Try(List(LockedSource), Str),

	## Reject a request this provider cannot realise, before any effect.
	preflight : Spec, Request, Str, Layout -> Try({}, Str),

	## Fetch + Realise + Activate: the ordered steps for one request, from the
	## Lock only. Never resolves or changes pins. The Core has already rejected
	## a stale Lock.
	realise : Spec, Request, Str, Layout, Lock -> Try(Steps, [InvalidLock(Str), Unrealisable(Str)]),

	## Resolve: what the Core must stage and run to produce a native lock, for
	## every input or for the named ones alone. The Core asks only a provider
	## that has something to resolve (see `Realise.resolvers`).
	resolve : Spec, Str, Layout, Update -> Try(Resolution, Str),

	## Resolve: turn the native lock the resolve command wrote into a Lock. The
	## Core supplies its own tree digests for `Resolution.locals` (by path) and
	## records the Spec's intent in the result before publishing.
	lock_from_native : Spec, Layout, Str, List({ path : Str, digest : Str }) -> Try(Lock, Str),
}.{

	## Inspection returns relative names; executable Steps files are absolute.
	File : { path : Str, contents : Str }

	LockedSource : { name : Str, identity : Str, metadata : List({ name : Str, value : Value }) }

	## Which pins an update resolves again. `Named` moves only the inputs with
	## these names and keeps every other pin of the Lock, which the Core has
	## already found current for the Spec. Local inputs hold no remote pin and
	## are read again either way.
	Update : [All, Named(List(Str), Lock)]

	## `present` are programs the machine must already have for `argv`, each
	## with why: the Core looks them up on PATH, as for a step's `Present`,
	## before any other effect of the update, and reports all that are
	## missing together. Then `files` are staged, `locals` are checked for
	## safety and hashed by the Core, and `argv` runs and writes
	## `native_lock`, which `lock_from_native` converts.
	Resolution : {
		present : List({ program : Str, because : Str }),
		files : List(Steps.File),
		locals : List(Str),
		argv : List(Str),
		native_lock : Str,
	}
}
