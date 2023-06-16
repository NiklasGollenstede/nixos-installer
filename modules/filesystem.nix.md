/*

# Additions to `fileSystems`

Currently, this just adds `preMountCommands`.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, pkgs, lib, utils, ... }: let lib = inputs.self.lib.__internal__; in let
    inherit (inputs.config.rename) preMountCommands;
in {

    options = {
        fileSystems = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule [ { options = {
            ${preMountCommands} = lib.mkOption { description = ''
                Commands to be run as root every time before mounting this filesystem, but after all its dependents were mounted (TODO: or does this run just once per boot?).
                This does not order itself before or after `systemd-fsck@''${utils.escapeSystemdPath device}.service`.
                This is not implemented for mounts in the initrd (those that are `neededForBoot`) yet.
                Note that if a symlink exists at a mount point when systemd's fstab-generator runs, it will read/resolve the symlink and use that as the mount point, resulting in mismatching unit names for that mount, effectively disabling its `${preMountCommands}`.
            ''; type = lib.types.lines; default = ""; };
        }; } ]);
    }; };

    config = let
    in ({

        assertions = lib.mapAttrsToList (name: fs: {
            assertion = (fs.${preMountCommands} == "") || (!utils.fsNeededForBoot fs);
            message = ''The filesystem "${name}" has `.${preMountCommands}` but is also (possibly implicitly) `.neededForBoot`. This is not currently supported.'';
        }) config.fileSystems;

        # The implementation is derived from the "mkfs-${device'}" service in nixpkgs.
        systemd.services = lib.fun.mapMergeUnique (_: args@{ mountPoint, device, depends, ... }: if (args.${preMountCommands} != "") then let
            isDevice = lib.fun.startsWith "/dev/" device;
            mountPoint' = utils.escapeSystemdPath mountPoint;
            device' = utils.escapeSystemdPath device;
        in { "pre-mount-${mountPoint'}" = {
            description = "Prepare mounting ${device} at ${mountPoint}";
            wantedBy = [ "${mountPoint'}.mount" ]; before = [ "${mountPoint'}.mount" ];
            requires = lib.optional isDevice "${device'}.device"; after = lib.optional isDevice "${device'}.device";
            unitConfig.RequiresMountsFor = depends ++ [ (builtins.dirOf device) (builtins.dirOf mountPoint) ];
            unitConfig.DefaultDependencies = false;
            serviceConfig.Type = "oneshot"; script = args.${preMountCommands};
        }; } else { }) config.fileSystems;

    });

}
