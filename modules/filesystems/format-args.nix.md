/*

# `fileSystems.*.formatArgs`

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, pkgs, lib, utils, ... }: let lib = inputs.self.lib.__internal__; in let
    inherit (inputs.config.rename) preMountCommands;
    types = moduleArgs.lib.types;
in {

    options = {
        fileSystems = lib.mkOption { type = types.attrsOf (types.submodule [ ({ config, ... }@_: { options = {
            formatArgs = lib.mkOption { description = "Arguments passed to mkfs for this filesystem during OS installation."; type = types.listOf types.str; default = if (lib.isString config.formatOptions or null) && config.formatOptions != "" then lib.splitString " " config.formatOptions else [ ]; };
        }; }) ]);
    }; };

    # (These are used in »../../lib/setup-scripts/disk.sh#format-partitions«.)

}
