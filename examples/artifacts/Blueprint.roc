# Two sandboxed artifacts, with locked sources separate from project files.
app [config] { pf: platform "../../blueprint-platform/main.roc" }

config = [
	Executor("native", Nix("nix")),
	Name("artifacts"),
	Systems(["x86_64-linux"]),
	Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))),
	Input("roc", "github:roc-lang/roc-overlay/a9b461cd4df73ccb69a79a2bc7f58ab60e715619"),
	# The scripts are Roc programs. A build has no network, so the bundles
	# they name are locked here: basic-cli, and http, which basic-cli needs.
	Environment(
		"dev",
		[
			Overlays(["roc"]),
			Command("roc-stable", "nix#rocpkgs.nightly-2026-10-23-18478ff"),
			RocPackages([
				"https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst",
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
