/*

# FS Nixpkgs "Patches"

Filesystem related "patches" of options in nixpkgs, i.e. additions of options that are *not* prefixed.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, utils, ... }: let inherit (inputs.self) lib; in let
in {

    options = {
        fileSystems = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule [ { options = {
            preMountCommands = lib.mkOption { description = ''
                Commands to be run as root every time before mounting this filesystem, but after all its dependents were mounted (TODO: or does this run just once per boot?).
                This does not order itself before or after `systemd-fsck@''${utils.escapeSystemdPath device}.service`.
                Note that if a symlink exists at a mount point when systemd's fstab-generator runs, it will read/resolve the symlink and use that as the mount point, resulting in mismatching unit names for that mount, effectively disabling its `preMountCommands`.
            ''; type = lib.types.lines; default = ""; };
        }; } ]);
    }; };

    config = let
    in ({

        # The implementation is derived from the "mkfs-${device'}" service in nixpkgs.
        systemd.services = lib.wip.mapMergeUnique (_: { mountPoint, device, preMountCommands, depends, ... }: if (preMountCommands != "") then let
            isDevice = lib.wip.startsWith "/dev/" device;
            mountPoint' = utils.escapeSystemdPath mountPoint;
            device' = utils.escapeSystemdPath device;
        in { "pre-mount-${mountPoint'}" = {
            description = "Prepare mounting ${device} at ${mountPoint}";
            wantedBy = [ "${mountPoint'}.mount" ]; before = [ "${mountPoint'}.mount" ];
            requires = lib.optional isDevice "${device'}.device"; after = lib.optional isDevice "${device'}.device";
            unitConfig.RequiresMountsFor = depends ++ [ (builtins.dirOf device) (builtins.dirOf mountPoint) ];
            unitConfig.DefaultDependencies = false;
            serviceConfig.Type = "oneshot"; script = preMountCommands;
        }; } else { }) config.fileSystems;

    });

}
