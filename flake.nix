{
  description = "roc-blueprint: describe dev environments in Blueprint.roc, get Nix dev shells";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc-overlay.url = "github:roc-lang/roc-overlay";
    roc-overlay.inputs.nixpkgs.follows = "nixpkgs";
    basic-cli-src = {
      url = "github:roc-lang/basic-cli/473caa2cc4f3fe9ce4e4682158bb80ebc2e19169";
      flake = false;
    };
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      roc-overlay,
      basic-cli-src,
      rust-overlay,
    }:
    let
      # Each system builds basic-cli's host for its own Roc target.
      hostTargets = {
        x86_64-linux = {
          roc = "x64musl";
          rust = "x86_64-unknown-linux-musl";
        };
        aarch64-darwin = {
          roc = "arm64mac";
          rust = "aarch64-apple-darwin";
        };
      };
      forSystem =
        system:
        let
          host = hostTargets.${system};
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
          lib = pkgs.lib;

          # The Roc nightly pinned in .roc-version, from roc-overlay.
          rocTag = lib.trim (builtins.readFile ./.roc-version);
          roc = roc-overlay.packages.${system}.${rocTag};

          # Temporary source pin to basic-cli PR #499 until a compatible release.
          rustToolchain = pkgs.rust-bin.fromRustupToolchain {
            channel =
              (builtins.fromTOML (builtins.readFile "${basic-cli-src}/rust-toolchain.toml")).toolchain.channel;
            components = [ "llvm-tools-preview" ];
            targets = [ host.rust ];
          };
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };
          basic-cli = rustPlatform.buildRustPackage {
            pname = "basic-cli-platform";
            version = "0.23.0-pr499";
            src = basic-cli-src;
            cargoLock.lockFile = "${basic-cli-src}/Cargo.lock";
            nativeBuildInputs = [
              pkgs.python3
              pkgs.zig_0_16
            ];
            postPatch = ''
              patchShebangs ci scripts
            '';
            # Keep Cargo's build helpers native; upstream uses Zig for musl C code.
            buildPhase = ''
              runHook preBuild
              export CARGO_NET_OFFLINE=true
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              python3 scripts/build.py --target ${host.roc}
              runHook postBuild
            '';
            # Roc supplies the host's unresolved symbols when linking an app.
            doCheck = false;
            dontStrip = true;
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -R platform/. "$out/"
              # build.py leaves arm64mac in platform/; the musl host is copied from Cargo.
              ${lib.optionalString (host.roc == "x64musl") ''
                cp target/${host.rust}/release/libhost.a "$out/targets/${host.roc}/libhost.a"
              ''}
              runHook postInstall
            '';
          };

          # Roc packages blueprint-cli/main.roc downloads. Fetched here and unpacked into
          # Roc's package cache so the sandboxed build needs no network.
          # These are the `weaver:` URL in blueprint-cli/main.roc plus transitive
          # dependencies (http, roc-ansi, path). A missing one shows up as
          # "package download failed" in `nix build .#blueprint`.
          rocPackages = [
            {
              url = "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst";
              hash = "sha256-6e+qlQ5y9vds326vAEJFcvppsEumEnMjV6wEU2ePArQ=";
            }
            {
              url = "https://github.com/lukewilliamboswell/weaver/releases/download/0.9.0/7j6KBFBEZ8pNMLQHkx9xiwyZ2PmwQPgKNDPUih6gKe77.tar.zst";
              hash = "sha256-GjWtVaxW7tYwwcd8ZNTogTmyKshRC4YE8IksP6ty+Wg=";
            }
            {
              url = "https://github.com/lukewilliamboswell/roc-ansi/releases/download/0.13.0/JXLM47L6CzrLXB5HBfqc27VnU6CD4jMm5Mk6dgbbovL.tar.zst";
              hash = "sha256-g1Um8JrYgyBSP+3TWkdXVp3hSN29ENPxtXnev5f8vqQ=";
            }
            {
              url = "https://github.com/roc-lang/path/releases/download/4.0.0/7YfABZPwJAXtLBY2vm8FqMyGAtNxncCJ65HdNKHFGNnE.tar.zst";
              hash = "sha256-Q1SZx/+081fSlW47soAqgSZPby9QyJbJkT+4b3vHUrs=";
            }
          ];

          unpackRocPackage =
            p:
            let
              name = lib.removeSuffix ".tar.zst" (baseNameOf p.url);
              archive = pkgs.fetchurl { inherit (p) url hash; };
            in
            ''
              mkdir -p "$XDG_CACHE_HOME/roc/packages/${name}"
              zstd -dc ${archive} | tar -x -C "$XDG_CACHE_HOME/roc/packages/${name}"
            '';

          blueprint = pkgs.stdenv.mkDerivation {
            pname = "blueprint";
            version = "0.2.0";
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./blueprint-cli
                ./blueprint-nix-package
                ./blueprint-ir-package/main.roc
                ./blueprint-ir-package/Ir.roc
                ./blueprint-ir-package/Sexpr.roc
                ./blueprint-ir-package/Value.roc
              ];
            };
            nativeBuildInputs = [
              roc
              pkgs.zstd
              pkgs.makeWrapper
            ];
            dontConfigure = true;
            # roc links a static executable; there is nothing to patch.
            dontPatchELF = true;
            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR" XDG_CACHE_HOME="$TMPDIR/cache"
              ${lib.concatMapStrings unpackRocPackage rocPackages}
              cp -R ${basic-cli} .basic-cli
              roc build blueprint-cli/main.roc --output=blueprint
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm755 blueprint "$out/bin/blueprint"
              # Default to the pinned Roc; ROC in the environment still wins.
              wrapProgram "$out/bin/blueprint" --set-default ROC ${lib.getExe roc}
              runHook postInstall
            '';
            meta = {
              description = "Turn a Blueprint.roc into a Nix dev shell";
              mainProgram = "blueprint";
              platforms = [ system ];
            };
          };
        in
        {
          packages = {
            inherit blueprint roc basic-cli;
            default = blueprint;
          };

          apps.default = {
            type = "app";
            program = lib.getExe blueprint;
          };

          # `nix develop github:lukewilliamboswell/roc-blueprint` gives `blueprint`
          # and the Roc it was built with.
          devShells = {
            default = pkgs.mkShell {
              packages = [
                blueprint
                roc
              ];
            };

            # For working on roc-blueprint itself; see CONTRIBUTING.md.
            contributor = pkgs.mkShell {
              packages = [
                blueprint
                roc
                pkgs.zig_0_16
                pkgs.python3
                pkgs.zstd
                pkgs.git
                pkgs.curl
              ];
            };
          };
        };
      systems = builtins.attrNames hostTargets;
      outputs = nixpkgs.lib.genAttrs systems forSystem;
    in
    {
      packages = nixpkgs.lib.mapAttrs (_: o: o.packages) outputs;
      apps = nixpkgs.lib.mapAttrs (_: o: o.apps) outputs;
      devShells = nixpkgs.lib.mapAttrs (_: o: o.devShells) outputs;
    };
}
