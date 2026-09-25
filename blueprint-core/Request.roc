# Consumer-selected operations, independent of provider discovery or effects.
Request := [Generate, Shell(Str), Run(Str, List(Str)), Build(Str), Workflow(Str)].{
	is_eq : _
}
