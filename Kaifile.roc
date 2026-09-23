app [config] { pf: platform "platform/main.roc" }

config = [
	Name("roc-blueprint"),
	Shell("default", [Tools(["git", "python3", "zstd", "nixfmt"])]),
	Shell("ci", [Tools(["git", "python3"])]),
]
