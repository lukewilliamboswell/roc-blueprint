# Everything the build and workflow fixtures take from outside the repository,
# at the pins committed in `consumer/inputs.lock` (nixpkgs) and
# `roc-inputs.lock.json` (the Roc overlay, compiler and bundles). The suites
# build this once, with the network, before they install the recording `nix`
# that adds `--offline` to every later call. Nix refuses a source whose bytes
# differ from its pinned hash.
let
  consumer = builtins.fromJSON (builtins.readFile ./consumer/inputs.lock);
  pins = builtins.fromJSON (builtins.readFile ./roc-inputs.lock.json);
  nixpkgs = builtins.fetchTree consumer.nodes.nixpkgs.locked;
  overlay = builtins.getFlake "github:${pins.overlay.owner}/${pins.overlay.repo}/${pins.overlay.rev}?narHash=${pins.overlay.nar_hash}";
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    overlays = [ overlay.overlays.default ];
  };
  bundle =
    pin:
    builtins.fetchTree {
      type = "tarball";
      inherit (pin) url;
      narHash = pin.nar_hash;
    };
in
pkgs.linkFarm "blueprint-fixture-inputs" (
  [
    {
      name = "roc";
      path = pkgs.rocpkgs.${pins.compiler};
    }
    {
      name = "roc-stable";
      path = pkgs.writeShellScriptBin "roc-stable" "exit";
    }
    {
      name = "shell";
      path = (pkgs.mkShell { packages = [ pkgs.coreutils ]; }).inputDerivation;
    }
    {
      name = "bash";
      path = pkgs.bashInteractive;
    }
  ]
  ++ builtins.genList (index: {
    name = "bundle-${toString index}";
    path = bundle (builtins.elemAt pins.bundles index);
  }) (builtins.length pins.bundles)
)
