# Exercises `Custom` extensions and `Raw` values of every shape. Used only for
# IR output checks: `blueprint` rejects extension kinds it does not know.
app [config] { pf: platform "../../blueprint-ir-platform/main.roc" }

config = [
	Name("extensions"),
	Packages("nixpkgs", "github:NixOS/nixpkgs/nixos-24.05"),
	Shell("default", [Tools(["git", "llvmPackages.bintools"])]),
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
