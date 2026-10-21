# Only immutable source and toolchain bytes enter this native runner derivation.
# The Blueprint executable and caller's cache paths are deliberately absent.
{ pkgs, source, compilerArchive }:
let
  compiler = pkgs.runCommand "blueprint-runner-compiler-v1" {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
  } ''
    mkdir -p "$out"
    tar -xzf ${compilerArchive} -C "$out" --strip-components=1
  '';
  basicCli = pkgs.fetchurl {
    url = "https://github.com/roc-lang/basic-cli/releases/download/0.26.0-rc2/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af.tar.zst";
    hash = "sha256-V3jm3ANU1ef7Wwcl7/jgTaPI1lYEnGO0PjzCdevvr4s=";
  };
  http = pkgs.fetchurl {
    url = "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst";
    hash = "sha256-6e+qlQ5y9vds326vAEJFcvppsEumEnMjV6wEU2ePArQ=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  name = "blueprint-build-runner-v1";
  dontUnpack = true;
  dontConfigure = true;
  dontFixup = true;
  nativeBuildInputs = [ pkgs.gnutar pkgs.zstd ];
  buildPhase = ''
    export HOME="$TMPDIR/home" XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$HOME" \
      "$XDG_CACHE_HOME/roc/packages/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af" \
      "$XDG_CACHE_HOME/roc/packages/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS"
    zstd -dc ${basicCli} | tar -x -C "$XDG_CACHE_HOME/roc/packages/Gj3zVDr3qrQa6aTh7Z1zgUfe9NeBE6R76T5ho3xrc8af"
    zstd -dc ${http} | tar -x -C "$XDG_CACHE_HOME/roc/packages/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS"
    cp ${source} main.roc
    ${compiler}/roc build main.roc --output=runner
  '';
  installPhase = ''
    install -Dm755 runner "$out/bin/roc-build-runner"
  '';
}
