/*

# `fileSystems.*.formatArgs`

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, pkgs, lib, utils, ... }: let lib = inputs.self.lib.__internal__; in let
    inherit (inputs.config.rename) preMountCommands;
in {

    options = {
        fileSystems = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule [ ({ config, ...}@_: { options = {
            formatArgs = lib.mkOption { description = "Arguments passed to mkfs for this filesystem during OS installation."; type = lib.types.listOf lib.types.str; default = if (lib.isString config.formatOptions or null) then lib.splitString config.formatOptions else [ ]; };
        }; }) ]);
    }; };

    # (These are used in »../../lib/setup-scripts/disk.sh#format-partitions«.)

}
