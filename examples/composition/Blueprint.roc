# Imported pure functions compose ordinary settings, without a plugin registry.
app [config] { pf: platform "../../blueprint-platform/main.roc" }

import ProjectTasks
import Releases

config = [
	Name("composed"),
	Systems(["x86_64-linux"]),
	Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))),
	Environment("base", [Tools(["nix#git"])]),
	Environment("dev", [Extend("base"), Tools(["nix#python3", "nix#git"])]),
	Environment("release", [Extend("dev"), Programs([Fetch("blueprint", Releases.blueprint("0.5.0"))])]),
	Shell("default", [Use("dev")]),
].concat(ProjectTasks.settings("dev"))
