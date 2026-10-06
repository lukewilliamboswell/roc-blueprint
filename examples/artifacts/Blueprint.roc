# Two sandboxed artifacts, with locked sources separate from project files.
app [config] { pf: platform "../../blueprint-platform/main.roc" }

config = [
	Name("artifacts"),
	Systems(["x86_64-linux"]),
	Overlay("roc", "github:roc-lang/roc-overlay"),
	# The scripts are Roc programs. A build has no network, so the bundles
	# they name are locked here: basic-cli, and http, which basic-cli needs.
	Environment(
		"dev",
		[
			Overlays(["roc"]),
			Command("roc-stable", "rocpkgs.nightly-2026-10-04-130536d"),
			RocPackages([
				"https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst",
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
			Use("dev"),
			Run(["roc-stable", "scripts/build_library.roc"]),
			Output("dist/library.txt"),
		],
	),
	Build(
		"app",
		[
			Use("dev"),
			Inputs(["assets"]),
			Needs(["library"]),
			Run(["roc-stable", "scripts/build_app.roc"]),
			Output("dist/app.txt"),
		],
	),
	Workflow("ci", [RunTask("check", []), BuildArtifact("app")]),
]
