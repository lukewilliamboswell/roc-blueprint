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

shell_tools : Requirement
shell_tools = Requirement.new({ id: "shell-tools", display_name: "Shell tools" })

workspace : Blueprint.Draft
workspace = Blueprint.workspace(
	{
		name: "multi-platform-shell",
		target_systems: [Target.X86_64Linux, Target.Aarch64Darwin],
		envs: [
			Environment.new(
				{
					name: "default",
					requirements: [shell_tools],
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
			Nix.bind(shell_tools, "nixpkgs", ["git"]),
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
