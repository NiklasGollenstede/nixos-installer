/*

# FS Nixpkgs "Patches"

Filesystem related "patches" of options in nixpkgs, i.e. additions of options that are *not* prefixed.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    utils = import "${inputs.nixpkgs.outPath}/nixos/lib/utils.nix" { inherit (specialArgs) lib config pkgs; };

in {

    options = {
        fileSystems = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule [ { options = {
            preMountCommands = lib.mkOption { description = ""; type = lib.types.nullOr lib.types.str; default = null; };
        }; } ]);
    }; };

    config = let
    in ({

        systemd.services = lib.wip.mapMerge (target: { device, preMountCommands,  ... }: if (preMountCommands != null) then let
            isDevice = lib.wip.startsWith "/dev/" device;
            target' = utils.escapeSystemdPath target;
            device' = utils.escapeSystemdPath device;
            mountPoint = "${target'}.mount";
        in { "pre-mount-${target'}" = {
            description = "Prepare mounting (to) ${target}";
            wantedBy = [ mountPoint ]; before = [ mountPoint ] ++ (lib.optional isDevice "systemd-fsck@${device'}.service");
            requires = lib.optional isDevice "${device'}.device"; after = lib.optional isDevice "${device'}.device";
            unitConfig.RequiresMountsFor = [ (builtins.dirOf device) (builtins.dirOf target) ];
            unitConfig.DefaultDependencies = false;
            serviceConfig.Type = "oneshot"; script = preMountCommands;
        }; } else { }) config.fileSystems;

    });

}
