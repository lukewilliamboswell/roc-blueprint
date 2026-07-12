import blueprint.Plan

BlueprintNix := [].{

	## Render a plan as a small placeholder Nix-like attribute set.
	render : Plan -> Str
	render = |plan| "{ field1 = \"${plan.field1}\"; field2 = ${plan.field2.to_str()}; }"
}

expect BlueprintNix.render({ field1: "example", field2: 42 }) == "{ field1 = \"example\"; field2 = 42; }"
