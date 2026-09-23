# An example using every setting. CI runs blueprint against it, and
# scripts/bundle.sh swaps the platform path for a bundle URL to smoke-test
# the platform bundle.
app [config] { pf: platform "../blueprint-ir-platform/main.roc" }

config = [
	Name("fixture"),
	Systems(["x86_64-linux"]),
	Packages("stable", "github:NixOS/nixpkgs/nixos-24.05"),
	Input("utils", "github:numtide/flake-utils"),
	Overlay("github:roc-lang/roc-overlay"),
	Shell("default", [Tools(["git", "python3Packages.requests", "stable#jq"])]),
	Shell("ci", [Tools(["git"])]),
	Task("hello", [Run(["git", "--version"])]),
	Task("ci-hello", [Run(["git", "--version"]), In("ci")]),
	Raw(
		"nix",
		"shell:default",
		Attrs([
			("shellHook", Str("echo \"fixture shell ready\"")),
			("FIXTURE_MODE", Str("dev")),
		]),
	),
]
