{
  description = "roc-blueprint: describe dev environments in Blueprint.roc, get Nix dev shells";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc-overlay.url = "github:roc-lang/roc-overlay";
    roc-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      roc-overlay,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forSystem =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;

          # The Roc nightly pinned in .roc-version, from roc-overlay.
          rocTag = lib.trim (builtins.readFile ./.roc-version);
          roc = roc-overlay.packages.${system}.${rocTag};

          # Roc packages blueprint-cli/main.roc downloads. Fetched here and unpacked into
          # Roc's package cache so the sandboxed build needs no network.
          # These are the `pf:` and `weaver:` URLs in blueprint-cli/main.roc plus
          # transitive dependencies (http, roc-ansi, path). A missing one shows
          # up as "package download failed" in `nix build .#blueprint`.
          rocPackages = [
            {
              url = "https://github.com/roc-lang/basic-cli/releases/download/0.24.0/AEjfyaMFFbh8FJrkkHJy68riVNPr3Qp6c6PawWQjBwMH.tar.zst";
              hash = "sha256-UN3FXbkwjWFcgDSif53HGC1ml2SEsdHEbi2ea82cFgw=";
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
            version = "0.4.0-rc2";
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./blueprint-cli
                ./.roc-version
                ./blueprint-nix
                ./blueprint-core/main.roc
                ./blueprint-core/Spec.roc
                ./blueprint-core/Project.roc
                ./blueprint-core/Request.roc
                ./blueprint-core/Steps.roc
                ./blueprint-core/Layout.roc
                ./blueprint-core/Sexpr.roc
                ./blueprint-core/Value.roc
                ./blueprint-core/Provider.roc
                ./blueprint-core/Lock.roc
                ./blueprint-core/Tree.roc
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
              # Builds run readlink; the host's own comes first.
              wrapProgram "$out/bin/blueprint" \
                --set-default ROC ${lib.getExe roc} \
                --suffix PATH : ${lib.makeBinPath [ pkgs.coreutils ]}
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
            inherit blueprint roc;
            default = blueprint;
          };

          apps.default = {
            type = "app";
            program = lib.getExe blueprint;
          };

          # The one definition of the development toolchain: contributors and
          # every CI job run the scripts through `nix develop -c`. It holds the
          # pinned Roc, Zig for the platform host, and the programs the scripts
          # in scripts/ start. `blueprint` itself is not here, so entering the
          # shell never compiles the CLI; `nix run` and `nix build` provide it.
          devShells.default = pkgs.mkShellNoCC {
            packages = [
              roc
              pkgs.zig_0_16
              pkgs.coreutils
              pkgs.gitMinimal
              pkgs.curl
              pkgs.gnutar
              pkgs.gzip
              # Remove with the last Python test (scripts/*.py).
              pkgs.python3
            ];
          };
        };
      outputs = nixpkgs.lib.genAttrs systems forSystem;
    in
    {
      packages = nixpkgs.lib.mapAttrs (_: o: o.packages) outputs;
      apps = nixpkgs.lib.mapAttrs (_: o: o.apps) outputs;
      devShells = nixpkgs.lib.mapAttrs (_: o: o.devShells) outputs;
    };
}
