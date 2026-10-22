(
	(fetched ())
	(format (
		(major 2)
		(minor 0)))
	(hints ((
		(provider "nix")
		(value (Attrs ((
			(name "identity")
			(value (Attrs ((
				(name "inputs")
				(value (Attrs ((
					(name "default")
					(value (Attrs ((
						(name "ref")
						(value (Str "github:NixOS/nixpkgs/nixos-unstable"))) (
						(name "kind")
						(value (Str "packages"))) (
						(name "flake")
						(value (Bool true))))))) (
					(name "assets")
					(value (Attrs ((
						(name "ref")
						(value (Str "path:assets"))) (
						(name "kind")
						(value (Str "source"))) (
						(name "flake")
						(value (Bool false))))))))))) (
				(name "overlays")
				(value (Attrs ()))))))) (
			(name "graph")
			(value (Attrs ((
				(name "root")
				(value (Str "root"))) (
				(name "version")
				(value (Int 7))) (
				(name "nodes")
				(value (Attrs ((
					(name "assets")
					(value (Attrs ((
						(name "flake")
						(value (Bool false))) (
						(name "original")
						(value (Attrs ((
							(name "type")
							(value (Str "path"))) (
							(name "path")
							(value (Str "assets"))))))) (
						(name "locked")
						(value (Attrs ((
							(name "lastModified")
							(value (Int 1790281077))) (
							(name "narHash")
							(value (Str "sha256-mhO52EWOvxHOyTFt0V1hM6Oo6mlpNo2PFlxQtcmCJBc="))) (
							(name "type")
							(value (Str "path"))) (
							(name "path")
							(value (Str "assets"))))))))))) (
					(name "default")
					(value (Attrs ((
						(name "locked")
						(value (Attrs ((
							(name "lastModified")
							(value (Int 1790185690))) (
							(name "narHash")
							(value (Str "sha256-xJ+X4hBtOcAFGBOe5nAMyMUeF9foJBmIOu3NjBqBycU="))) (
							(name "owner")
							(value (Str "NixOS"))) (
							(name "repo")
							(value (Str "nixpkgs"))) (
							(name "rev")
							(value (Str "4975466d324710c576dc11ad614684e6bd8cad8e"))) (
							(name "type")
							(value (Str "github"))))))) (
						(name "original")
						(value (Attrs ((
							(name "owner")
							(value (Str "NixOS"))) (
							(name "ref")
							(value (Str "nixos-unstable"))) (
							(name "repo")
							(value (Str "nixpkgs"))) (
							(name "type")
							(value (Str "github"))))))))))) (
					(name "root")
					(value (Attrs ((
						(name "inputs")
						(value (Attrs ((
							(name "assets")
							(value (Str "assets"))) (
							(name "default")
							(value (Str "default")))))))))))))))))))))))))
	(intent (
		(build_sources ())
		(inputs ())
		(overlays ())
		(resolvers ())
		(sources ())))
	(sources ((
		(digest "sha256:c49f97e2106d39c00518139ee6700cc8c51e17d7e82419883aedcd8c1a81c9c5")
		(name "default")
		(provider "nix")
		(ref "github:NixOS/nixpkgs/nixos-unstable")
		(rev "4975466d324710c576dc11ad614684e6bd8cad8e")) (
		(digest "sha256:1111111111111111111111111111111111111111111111111111111111111111")
		(name "assets")
		(provider "nix")
		(ref "path:assets")
		(rev "")))))
