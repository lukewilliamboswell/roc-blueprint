app [config] { pf: platform "platform/main.roc" }

config = [
	Name("roc-blueprint"),
	Overlay("github:roc-lang/roc-overlay"),
	Systems([X86_64Linux]),
	Shell("default", [Tools(["rocpkgs.nightly", "zig_0_16", "git", "python3", "zstd", "nixfmt"])]),
	Shell("ci", [Tools(["rocpkgs.nightly", "zig_0_16", "git"])]),
	Task("test", [Run(["./ci/test.sh"])]),
	Task("bundle", [Run(["scripts/bundle.sh", "platform"])]),
]
