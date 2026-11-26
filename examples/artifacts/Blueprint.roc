# Two sandboxed artifacts, with locked sources separate from project files.
app [config] { pf: platform "../../blueprint-platform/main.roc" }

config = [
	Executor("native", Nix("nix")),
	Name("artifacts"),
	Systems(["x86_64-linux"]),
	Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))),
	Input("roc", "github:roc-lang/roc-overlay/1302f9d1a99237c7fe0f4edff0660be5c3a5b368"),
	# The scripts are Roc programs. A build has no network, so the bundles
	# they name are locked here: basic-cli, and http, which basic-cli needs.
	Environment(
		"dev",
		[
			Overlays(["roc"]),
			Command("roc-stable", "nix#rocpkgs.nightly-2026-11-24-ff5e544"),
			RocPackages([
				"https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
				"https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
			]),
		],
	),
	Shell("default", [Use("dev")]),
	Task("check", [Use("dev"), Run(["roc-stable", "scripts/check.roc"])]),
	Source("assets", "path:./assets"),
	Build(
		"library",
		[
			Execute("native"),
			Use("dev"),
			Files(["scripts/build_library.roc", "src/message.txt"]),
			Run(["roc-stable", "scripts/build_library.roc"]),
			Output("dist/library.txt"),
		],
	),
	Build(
		"app",
		[
			Execute("native"),
			Use("dev"),
			Files(["scripts/build_app.roc"]),
			Inputs(["assets"]),
			Needs(["library"]),
			Run(["roc-stable", "scripts/build_app.roc"]),
			Output("dist/app.txt"),
		],
	),
	Workflow("ci", [RunTask("check", []), BuildArtifact("app")]),
]
