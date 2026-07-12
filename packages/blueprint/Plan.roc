## A placeholder plan that will grow with the blueprint implementation.
Plan := { field1 : Str, field2 : I64 }

example : Plan
example = { field1: "example", field2: 42 }

expect example.field1 == "example"
expect example.field2 == 42
