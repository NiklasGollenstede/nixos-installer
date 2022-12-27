/*

# `nixpkgs` Profiles as Options

The "modules" in `<nixpkgs>/nixos/modules/profile/` define sets of option defaults to be used in certain contexts.
Unfortunately, they apply their options unconditionally once included, and NixOS' module system does not allow conditional imports.
This wrapper makes it possible to apply a profile based on some option's values.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module patch:
dirname: inputs: specialArgs@{ config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
in {

    imports = [
        (lib.wip.overrideNixpkgsModule ({ inherit inputs; } // specialArgs) "profiles/qemu-guest.nix" (module: {
            options.profiles.qemu-guest.enable = (lib.mkEnableOption "qemu-guest profile");
            config = lib.mkIf config.profiles.qemu-guest.enable module;
        }))
        # Could do this automatically for all files in the directory ...
    ];

}
