{
  description = "roc-blueprint: describe dev environments in Blueprint.roc, get Nix dev shells";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc-overlay.url = "github:roc-lang/roc-overlay";
    roc-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, roc-overlay }:
    let
      # Only x86_64 Linux for now: the platform targets x64musl only.
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;

      # The Roc nightly pinned in .roc-version, from roc-overlay.
      rocTag = lib.trim (builtins.readFile ./.roc-version);
      roc = roc-overlay.packages.${system}.${rocTag};

      # Roc packages blueprint-cli/main.roc downloads. Fetched here and unpacked into
      # Roc's package cache so the sandboxed build needs no network.
      # These are the `pf:` and `weaver:` URLs in blueprint-cli/main.roc plus their own
      # dependencies (http, roc-ansi, path). A missing one shows up as
      # "package download failed" in `nix build .#blueprint`.
      rocPackages = [
        {
          url = "https://github.com/roc-lang/basic-cli/releases/download/0.23.0-rc1/3hT3SoHZ6qbEsa9qVFLUW3547U5LeoNd1KbpqLpz4r1i.tar.zst";
          hash = "sha256-3vjAUtcCdgS1DWfyCanTOzqDHhcoEdPjHqHzqHMiMBg=";
        }
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
        version = "0.1.0";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./blueprint-cli
            ./blueprint-ir-package/main.roc
            ./blueprint-ir-package/Ir.roc
            ./blueprint-ir-package/Sexpr.roc
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
      packages.${system} = {
        inherit blueprint roc;
        default = blueprint;
      };

      apps.${system}.default = {
        type = "app";
        program = lib.getExe blueprint;
      };

      # `nix develop github:lukewilliamboswell/roc-blueprint` gives `blueprint`
      # and the Roc it was built with.
      devShells.${system} = {
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
}
