(
	(name "roc-blueprint")
	(overlays ("github:roc-lang/roc-overlay"))
	(shells ((
		(name "default")
		(tools (("rocpkgs" "nightly") ("zig_0_16") ("git") ("python3") ("zstd") ("nixfmt")))) (
		(name "ci")
		(tools (("rocpkgs" "nightly") ("zig_0_16") ("git"))))))
	(systems (X86_64Linux))
	(tasks ())
	(version 2))
