# Small inspection interface. Executable operations use NixProvider.plan instead.
import core.Spec

Provider := {
	name : Str,
	features : List(Str),
	render : Spec -> Try(List(File), Str),
}.{

	## Inspection returns relative names; executable Steps files are absolute.
	File : { path : Str, contents : Str }
}
