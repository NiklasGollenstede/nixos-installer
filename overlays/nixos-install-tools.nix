dirname: inputs: final: prev: let
    lib = inputs.self.lib.__internal__;
in {
    ## The options reference manual takes long to generate, is also available online (in this exact form, as this version is the generic nixpkgs one), and has failed to generate on occasion.

    nixos-install-tools-no-doc = (prev.nixos-install-tools.override (old: { nixos = args: lib.recursiveUpdate (old.nixos args) { config.system.build.manual.nixos-configuration-reference-manpage = null; }; }));
    #nixos-install-tools-no-doc = (prev.nixos-install-tools.overrideAttrs (old: { pkgs = builtins.toJSON (builtins.tail (builtins.fromJSON old.pkgs)); }));
}
