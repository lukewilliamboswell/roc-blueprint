# Two sandboxed artifacts, with locked sources separate from project files.
app [config] { pf: platform "../../blueprint-platform/main.roc" }

config = [
	Name("artifacts"),
	Systems(["x86_64-linux"]),
	Environment("dev", [Tools(["python3"])]),
	Shell("default", [Use("dev")]),
	Task("check", [Use("dev"), Run(["python3", "scripts/check.py"])]),
	Source("assets", "path:./assets"),
	Build(
		"library",
		[
			Use("dev"),
			Run(["python3", "scripts/build_library.py"]),
			Output("dist/library.txt"),
		],
	),
	Build(
		"app",
		[
			Use("dev"),
			Inputs(["assets"]),
			Needs(["library"]),
			Run(["python3", "scripts/build_app.py"]),
			Output("dist/app.txt"),
		],
	),
	Workflow("ci", [RunTask("check", []), BuildArtifact("app")]),
]
