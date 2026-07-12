import EnvironmentId
import Requirement

## A named portable development environment.
Environment := { id : EnvironmentId, requirements : List(Requirement) }.{
	new : { name : Str, requirements : List(Requirement) } -> Environment
	new = |fields| Environment.{ id: EnvironmentId.new(fields.name), requirements: fields.requirements }

	name : Environment -> Str
	name = |environment| EnvironmentId.to_str(environment.id)
}
