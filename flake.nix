{
  description = "roc-blueprint: describe dev environments in Blueprint.roc, get Nix dev shells";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    roc-overlay.url = "github:roc-lang/roc-overlay";
    roc-overlay.inputs.nixpkgs.follows = "nixpkgs";
    # roc-overlay uses this only for x86_64-darwin, which this flake does not
    # expose; following nixpkgs keeps a second nixpkgs out of flake.lock.
    roc-overlay.inputs.nixpkgs-darwin.follows = "nixpkgs";
    # The official prebuilt Zig. nixpkgs builds its own against LLVM, which
    # makes the development shell several times larger.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      roc-overlay,
      zig-overlay,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forSystem =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;

          # The compiler the product is built with and that a released
          # `blueprint` embeds: the nightly in blueprint-cli/compiler-version,
          # from roc-overlay.
          rocTag = lib.trim (builtins.readFile ./blueprint-cli/compiler-version);
          roc = roc-overlay.packages.${system}.${rocTag};

          # The compiler the scripts in scripts/ run on, under the command name
          # `roc-stable` alone. It moves only by a reviewed edit here, so the
          # scripts keep working while the product moves to a newer nightly.
          rocStableTag = "nightly-2026-10-13-b17d287";
          rocStable = pkgs.runCommand "roc-stable-${rocStableTag}" { } ''
            mkdir -p "$out/bin"
            ln -s ${lib.getExe roc-overlay.packages.${system}.${rocStableTag}} "$out/bin/roc-stable"
          '';

          # The compiler scripts/build_release.roc cross-builds every released
          # binary with: the x86_64 Linux archive unpacked as it is, with the
          # `darwin/` sysroot of the Apple Silicon archive beside it. Roc links
          # macOS programs against that sysroot and looks for it next to its own
          # executable, so `roc` is not wrapped or moved. Only the macOS archive
          # ships the sysroot. Each archive's URL and hash are the ones
          # roc-overlay records for the tag; they are fetched again here because
          # the overlay's own macOS source is a derivation for a Darwin builder.
          rocArchive =
            archiveSystem:
            let
              src = roc-overlay.packages.${archiveSystem}.${rocTag}.src;
            in
            pkgs.fetchurl {
              inherit (src) url;
              hash = src.outputHash;
            };
          rocCross = pkgs.runCommand "roc-cross-${rocTag}" { } ''
            mkdir -p "$out" sysroot
            tar -xzf ${rocArchive "x86_64-linux"} -C "$out" --strip-components=1
            tar -xzf ${rocArchive "aarch64-darwin"} -C sysroot --strip-components=1
            cp -r sysroot/darwin "$out/darwin"
          '';

          # Released native documentation renderer, paired with the shared
          # build-docs action at the tools-0.1.0-rc.1 release commit. Never
          # patch its bytes: these hashes identify the published executables.
          rocDocsVersion = "0.1.0-rc.1";
          rocDocsHashes = {
            "x86_64-linux" = "sha256-lpuU3rMVjp3yMbmJmF6HIlV4h56bb3+59KtGsor01YY=";
            "aarch64-linux" = "sha256-AIQ4qz/ON3zXw7Vy2nLQKz9y/nk0W8Fx0iG8DwVKcLI=";
            "aarch64-darwin" = "sha256-gGiXT38sIgM/EspTfiv1ZYr7RVTuL1G3XS4OQ3ZJWho=";
          };
          rocDocsArchive = pkgs.fetchurl {
            url = "https://github.com/lukewilliamboswell/roc-automation/releases/download/tools-${rocDocsVersion}/roc-docs-${system}";
            hash = rocDocsHashes.${system};
          };
          rocDocs = pkgs.runCommand "roc-docs-${rocDocsVersion}" {
            meta.mainProgram = "roc-docs";
          } ''
            install -Dm755 ${rocDocsArchive} "$out/bin/roc-docs"
          '';

          # The specification `roc glue` writes the platform host's Zig
          # bindings from. The compiler archives do not ship it, so it comes
          # from the same nightly's source archive, of which this is the one
          # file needed. The hash is that archive's: it must change with
          # blueprint-cli/compiler-version, and the fetch fails until it does.
          rocGlueSpec =
            pkgs.runCommand "roc-glue-spec-${rocTag}"
              {
                src = pkgs.fetchurl {
                  url = "https://github.com/roc-lang/nightlies/releases/download/${rocTag}/roc_nightly-source-${lib.removePrefix "nightly-" rocTag}.tar.gz";
                  hash = "sha256-9LrWinfmGefwNpse6GaCnyQAOjml42x8RMxBkCNUoCQ=";
                };
              }
              ''
                mkdir -p "$out"
                tar -xzf "$src" --wildcards --strip-components=4 -C "$out" '*/src/glue/src/ZigGlue.roc'
              '';

          # Roc packages blueprint-cli/main.roc downloads. Fetched here and unpacked into
          # Roc's package cache so the sandboxed build needs no network.
          # These are the `pf:` and `weaver:` URLs in blueprint-cli/main.roc plus
          # transitive dependencies (http, roc-ansi, path). A missing one shows
          # up as "package download failed" in `nix build .#blueprint`.
          rocPackages = [
            {
              url = "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst";
              hash = "sha256-V3jm3ANU1ef7Wwcl7/jgTaPI1lYEnGO0PjzCdevvr4s=";
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
            version = "0.7.0";
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./blueprint-cli
                ./blueprint-nix
                ./fixtures/consumer/authority.lock
                ./blueprint-core/JsonData.roc
                ./blueprint-core/LockSnapshot.roc
                ./blueprint-core/main.roc
                ./blueprint-core/Spec.roc
                ./blueprint-core/Project.roc
                ./blueprint-core/Request.roc
                ./blueprint-core/Steps.roc
                ./blueprint-core/Layout.roc
                ./blueprint-core/Sexpr.roc
                ./blueprint-core/Value.roc
                ./blueprint-core/Provider.roc
                ./blueprint-core/Realise.roc
                ./blueprint-core/Lock.roc
                ./blueprint-core/Tree.roc
                ./blueprint-core/Sbom.roc
                ./blueprint-core/SbomLicenses.roc
                ./blueprint-core/Sidecar.roc
                ./blueprint-core/CycloneDx.roc
                ./blueprint-core/JsonTree.roc
                ./blueprint-core/Lookup.roc
                ./blueprint-core/Spdx2.roc
                ./blueprint-core/Spdx3.roc
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
              cp ${rocArchive system} blueprint-cli/compiler-archive
              roc build blueprint-cli/main.roc --output=blueprint
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm755 blueprint "$out/bin/blueprint"
              # Bootstrap unpacks the embedded compiler with tar/gzip; builds
              # observe namespaces with readlink and publish readable witnesses
              # with chmod. Host tools still come first.
              wrapProgram "$out/bin/blueprint" \
                --suffix PATH : ${lib.makeBinPath [
                  pkgs.coreutils
                  pkgs.gnutar
                  pkgs.gzip
                ]}
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
            roc-glue-spec = rocGlueSpec;
            roc-docs = rocDocs;
            lock-snapshot-validator = pkgs.writeShellApplication {
              name = "validate-lock-snapshot";
              runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.jsonschema ])) ];
              text = ''
                exec python3 -I ${./scripts/validate_lock_snapshot.py} --schema ${./blueprint-core/lock-snapshot-v1.schema.json} "$@"
              '';
            };
          }
          # Not in the development shell: only a release build needs it, and
          # with it the macOS archive.
          // lib.optionalAttrs (system == "x86_64-linux") { roc-cross = rocCross; };

          apps.default = {
            type = "app";
            program = lib.getExe blueprint;
          };

          # The one definition of the development toolchain: contributors and
          # every CI job run the scripts through `nix develop -c`. It holds the
          # product compiler as `roc`, the scripts' compiler as `roc-stable`,
          # Zig for the platform host, and the programs the scripts in scripts/
          # start. `blueprint` itself is not here, so entering the
          # shell never compiles the CLI; `nix run` and `nix build` provide it.
          devShells.default = pkgs.mkShellNoCC {
            # Ignored build input: every local CLI build embeds this host's archive.
            shellHook = ''
              cp ${rocArchive system} blueprint-cli/.compiler-archive.$$
              chmod u+w blueprint-cli/.compiler-archive.$$
              mv blueprint-cli/.compiler-archive.$$ blueprint-cli/compiler-archive
            '';
            packages = [
              roc
              rocStable
              zig-overlay.packages.${system}."0.16.0"
              pkgs.coreutils
              pkgs.gitMinimal
              pkgs.curl
              pkgs.gnutar
              pkgs.gzip
              # The release scripts: archives of the examples and the
              # documentation, and the releases already published.
              pkgs.zip
              pkgs.unzip
              pkgs.gh
            ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.bubblewrap pkgs.util-linux pkgs.python3 ];
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
