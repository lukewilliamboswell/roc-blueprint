import blueprint.Blueprint
import blueprint.Environment
import blueprint.Requirement
import blueprint.Target
import blueprint_nix.Nix

## The platform's internal builder for development shells.
##
## The platform folds a Kaifile's settings into a `Flake`. Each tool is a
## nixpkgs attribute path, such as `"git"` or `"python3Packages.ruff"`.
## Lowering creates the portable requirement and the exact Nix binding for
## every tool, then validates and renders through the ordinary `Blueprint` and
## `Nix` modules.
Flake :: {
	name : Str,
	systems : List([Aarch64Darwin, Aarch64Linux, X86_64Darwin, X86_64Linux]),
	envs : List({ name : Str, tools : List(Str) }),
	overlays : List(Str),
}.{

	## Failures from either validation phase, with their structured errors.
	Error : [BlueprintInvalid(List(Blueprint.Error)), NixInvalid(List(Nix.Error))]

	## Begins a flake for `x86_64-linux` and `aarch64-darwin` with no shells.
	new : Str -> Flake
	new = |name| Flake.{ name, systems: [X86_64Linux, Aarch64Darwin], envs: [], overlays: [] }

	## Replaces the flake's name.
	named : Flake, Str -> Flake
	named = |flake, name| Flake.{ name, systems: flake.systems, envs: flake.envs, overlays: flake.overlays }

	## Adds the `default` development shell.
	shell : Flake, List(Str) -> Flake
	shell = |flake, tools| flake.env("default", tools)

	## Adds a named development shell.
	env : Flake, Str, List(Str) -> Flake
	env = |flake, name, tools| Flake.{ name: flake.name, systems: flake.systems, envs: flake.envs.append({ name, tools }), overlays: flake.overlays }

	## Replaces the declared target systems.
	for_systems : Flake, List([Aarch64Darwin, Aarch64Linux, X86_64Darwin, X86_64Linux]) -> Flake
	for_systems = |flake, systems| Flake.{ name: flake.name, systems, envs: flake.envs, overlays: flake.overlays }

	## Applies a flake overlay, such as `"github:roc-lang/roc-overlay"`, to nixpkgs.
	overlay : Flake, Str -> Flake
	overlay = |flake, url| Flake.{ name: flake.name, systems: flake.systems, envs: flake.envs, overlays: flake.overlays.append(url) }

	## Lowers, validates, and renders a complete flake from nixpkgs unstable.
	render : Flake -> Try(Str, Error)
	render = |flake| {
		tools = unique_tools(flake.envs)
		draft = Blueprint.workspace({
			name: flake.name,
			target_systems: flake.systems.map(to_target),
			envs: flake.envs.map(
				|e| Environment.new({ name: e.name, requirements: e.tools.map(requirement) }),
			),
		})
		config = Nix.with_overlays(
			Nix.config({
				nixpkgs: Nix.github_input("nixpkgs", "NixOS", "nixpkgs", "nixos-unstable"),
				bindings: tools.map(|p| Nix.bind(requirement(p), "nixpkgs", p.split_on("."))),
			}),
			flake.overlays,
		)
		valid = Blueprint.validate(draft) ? |errors| BlueprintInvalid(errors)
		Nix.render(valid, config).map_err(|errors| NixInvalid(errors))
	}
}

requirement : Str -> Requirement
requirement = |tool| Requirement.new({ id: tool, display_name: tool })

to_target : [Aarch64Darwin, Aarch64Linux, X86_64Darwin, X86_64Linux] -> Target
to_target = |target|
	match target {
		Aarch64Darwin => Target.Aarch64Darwin
		Aarch64Linux => Target.Aarch64Linux
		X86_64Darwin => Target.X86_64Darwin
		X86_64Linux => Target.X86_64Linux
	}

unique_tools : List({ name : Str, tools : List(Str) }) -> List(Str)
unique_tools = |envs| {
	var $seen = []
	for e in envs {
		for p in e.tools {
			if !$seen.contains(p) {
				$seen = $seen.append(p)
			}
		}
	}
	$seen
}
