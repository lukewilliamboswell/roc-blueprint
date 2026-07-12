## An exact environment identity, distinct from requirement identities.
EnvironmentId :: { value : Str }.{
	new : Str -> EnvironmentId
	new = |value| EnvironmentId.{ value }

	to_str : EnvironmentId -> Str
	to_str = |id| id.value
}
