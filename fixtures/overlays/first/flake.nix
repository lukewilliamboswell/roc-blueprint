{
  outputs = { self }: {
    overlays.default = final: prev: {
      fixtureTool = prev.writeShellScriptBin "fixture-tool" "printf 'base\\n'";
    };
  };
}
