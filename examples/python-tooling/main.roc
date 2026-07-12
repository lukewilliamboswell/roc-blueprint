app [main!] {
	pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst",
	blueprint: "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.0.3-blueprint/HmTRQhvSpRQsj78WCR7j5y3anhqMVB4zuMejydrdAGeV.tar.zst",
	blueprint_nix: "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.0.3-blueprint-nix/5stkC8nuQYzCjQueDhBLQrFPvfk6MP1byVq8nR3ET72h.tar.zst",
}

import pf.Stdout
import blueprint.Blueprint
import blueprint.Environment
import blueprint.Requirement
import blueprint.Target
import blueprint_nix.Nix

python3 : Requirement
python3 = Requirement.new({ id: "python3", display_name: "Python" })

git : Requirement
git = Requirement.new({ id: "git", display_name: "Git" })

workspace : Blueprint.Draft
workspace = Blueprint.workspace(
	{
		name: "python-tooling",
		target_systems: [Target.X86_64Linux],
		envs: [
			Environment.new(
				{
					name: "default",
					requirements: [python3, git],
				},
			),
		],
	},
)

nix_config : Nix.Config
nix_config = Nix.config(
	{
		nixpkgs: Nix.github_input("nixpkgs", "NixOS", "nixpkgs", "nixos-unstable"),
		bindings: [
			Nix.bind(python3, "nixpkgs", ["python3"]),
			Nix.bind(git, "nixpkgs", ["git"]),
		],
	},
)

main! : List(Str) => Try({}, _)
main! = |_args| {
	valid = Blueprint.validate(workspace) ? |errors| BlueprintInvalid(errors)
	source = Nix.render(valid, nix_config) ? |errors| NixInvalid(errors)
	Stdout.line!(source)?
	Ok({})
}
