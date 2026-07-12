app [main!] {
	pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst",
	blueprint: "../../packages/blueprint/main.roc",
	blueprint_nix: "../../packages/blueprint-nix/main.roc",
}

import pf.Stdout
import blueprint.Blueprint
import blueprint.Environment
import blueprint.Requirement
import blueprint.Target
import blueprint_nix.Nix

rust_compiler : Requirement
rust_compiler = Requirement.new({ id: "rust-compiler", display_name: "Rust compiler" })

cargo : Requirement
cargo = Requirement.new({ id: "cargo", display_name: "Cargo" })

git : Requirement
git = Requirement.new({ id: "git", display_name: "Git" })

workspace : Blueprint.Draft
workspace = Blueprint.workspace(
	{
		name: "rust-tooling",
		target_systems: [Target.X86_64Linux],
		envs: [
			Environment.new(
				{
					name: "default",
					requirements: [rust_compiler, cargo, git],
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
			Nix.bind(rust_compiler, "nixpkgs", ["rustc"]),
			Nix.bind(cargo, "nixpkgs", ["cargo"]),
			Nix.bind(git, "nixpkgs", ["git"]),
		],
	},
)

main! : List(Str) => Try({}, _)
main! = |_args| {
	valid = Blueprint.validate(workspace) ? |errors| BlueprintInvalid(errors)
	source = Nix.render(valid, nix_config) ? |errors| NixInvalid(errors)
	without_final_newline = Str.from_utf8(source.to_utf8().drop_last(1)) ? |_| GeneratedSourceInvalidUtf8
	Stdout.line!(without_final_newline)?
	Ok({})
}
