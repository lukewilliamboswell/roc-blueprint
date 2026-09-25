# An example using every setting. CI runs blueprint against it, and
# scripts/bundle.sh swaps the platform path for a bundle URL to smoke-test
# the platform bundle.
app [config] { pf: platform "../../blueprint-platform/main.roc" }

config = [
	Name("fixture"),
	Systems(["x86_64-linux"]),
	Packages("default", Auto),
	Packages("stable", From(NixPackages("github:NixOS/nixpkgs/nixos-24.05"))),
	Input("utils", "github:numtide/flake-utils"),
	Overlay("roc", "github:roc-lang/roc-overlay"),
	Environment("base", [Tools(["git"])]),
	Environment(
		"dev",
		[
			Extend("base"),
			Tools(["python3Packages.requests", "stable#jq"]),
			Overlays(["roc"]),
		],
	),
	Shell("default", [Use("dev")]),
	Shell("ci", [Use("base")]),
	Task("hello", [Use("dev"), Run(["git", "--version"])]),
	Task("ci-hello", [Use("base"), Run(["git", "--version"])]),
	Raw(
		"nix",
		"shell:default",
		Attrs([
			("shellHook", Str("echo \"fixture shell ready\"")),
			("FIXTURE_MODE", Str("dev")),
		]),
	),
]
