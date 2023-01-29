dirname: inputs: final: prev: let
    inherit (final) pkgs; inherit (inputs.self) lib;
in lib.mapAttrs (name: path: (
    pkgs.writeShellScriptBin name (
        lib.wip.substituteImplicit { inherit pkgs; scripts = [ path ]; context = { inherit dirname inputs pkgs lib; }; }
    )
)) (lib.wip.getFilesExt "sh(.md)?" dirname)
