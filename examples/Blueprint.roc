# An example using every setting. CI runs blueprint against it, and
# scripts/bundle.sh swaps the platform path for a bundle URL to smoke-test
# the platform bundle.
app [config] { pf: platform "../blueprint-ir-platform/main.roc" }

config = [
	Name("fixture"),
	Overlay("github:roc-lang/roc-overlay"),
	Systems([X86_64Linux]),
	Shell("default", [Tools(["git", "python3Packages.requests"])]),
	Shell("ci", [Tools(["git"])]),
	Task("hello", [Run(["git", "--version"])]),
	Task("ci-hello", [Run(["git", "--version"]), In("ci")]),
]
