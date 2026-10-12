{
  outputs = { self }: {
    overlays.default = final: prev: {
      # Says what it was built with, taking the options a toolchain of
      # rust-overlay takes.
      configurableTool = prev.lib.makeOverridable
        ({ targets ? [ ], extensions ? [ ] }:
          prev.writeShellScriptBin "configurable-tool"
            "printf 'targets=%s extensions=%s\\n' ${prev.lib.escapeShellArg (toString targets)} ${prev.lib.escapeShellArg (toString extensions)}")
        { };
    };
  };
}
