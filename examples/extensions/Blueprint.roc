# Exercises `Custom` extensions and `Raw` values of every shape. Used only for
# IR output checks: `blueprint` rejects extension kinds it does not know.
app [config] { pf: platform "../../blueprint-ir-platform/main.roc" }

config = [
	Name("extensions"),
	Packages("default", From(NixPackages("github:NixOS/nixpkgs/nixos-24.05"))),
	Environment("dev", [Tools(["git", "llvmPackages.bintools"])]),
	Shell("default", [Use("dev")]),
	Custom(
		"services",
		"postgres",
		Attrs([
			("version", Int(16)),
			("enable", Bool(True)),
			("databases", List([Str("app"), Str("test")])),
		]),
	),
	Custom("services", "redis", Attrs([])),
	Raw("nix", "flake", Attrs([("formatter", Str("nixpkgs-fmt"))])),
]
