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
			Command("json-query", "stable#jq"),
			Overlays(["roc"]),
		],
	),
	# Roc programs run in `scripts` resolve this locked bundle without a download.
	Environment(
		"scripts",
		[
			Extend("dev"),
			RocPackages(["https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst"]),
		],
	),
	Shell("default", [Use("dev")]),
	Shell("ci", [Use("base")]),
	Shell("scripts", [Use("scripts")]),
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
