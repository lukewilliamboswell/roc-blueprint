## An exact, portable tool identity.
Requirement :: { id : Str, display_name : Str }.{
	new : { id : Str, display_name : Str } -> Requirement
	new = |fields| Requirement.{ id: fields.id, display_name: fields.display_name }

	id : Requirement -> Str
	id = |requirement| requirement.id

	display_name : Requirement -> Str
	display_name = |requirement| requirement.display_name
}
