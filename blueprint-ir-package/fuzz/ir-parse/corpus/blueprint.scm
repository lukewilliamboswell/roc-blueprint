(
	(format (
		(major 1)
		(minor 0)))
	(inputs ((
		(kind Packages)
		(name "nixpkgs")
		(url "github:NixOS/nixpkgs/nixos-unstable")) (
		(kind Overlay)
		(name "roc")
		(url "github:roc-lang/roc-overlay"))))
	(name "roc-blueprint")
	(requires ())
	(shells ((
		(name "default")
		(packages ((
			(path ("rocpkgs" "nightly"))
			(source "nixpkgs")) (
			(path ("zig_0_16"))
			(source "nixpkgs")) (
			(path ("git"))
			(source "nixpkgs")))))))
	(systems ("x86_64-linux"))
	(tasks ()))
