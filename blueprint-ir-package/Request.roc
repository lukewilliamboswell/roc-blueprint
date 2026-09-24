# Consumer-selected operations, independent of backend discovery or effects.
Request := [Generate, Shell(Str), Run(Str, List(Str)), Build(Str)].{
	is_eq : _
}
