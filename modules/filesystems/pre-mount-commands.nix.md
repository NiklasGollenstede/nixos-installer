/*

# `fileSystems.*.preMountCommands`/`.postUnmountCommands`

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, pkgs, lib, utils, ... }: let lib = inputs.self.lib.__internal__; in let
in {

    options = {
        fileSystems = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule [ { options = {
            preMountCommands = lib.mkOption { description = ''
                Commands to be run as root every time before mounting this filesystem **via systemd**, but after all its dependents were mounted.
                This does not order itself before or after `systemd-fsck@''${utils.escapeSystemdPath device}.service`.
                Note that if a symlink exists at a mount point when systemd's fstab-generator runs, it will read/resolve the symlink and use the link's target as the mount point, resulting in mismatching unit names for that mount, effectively disabling its `.preMountCommands`.
                This does not (apparently and unfortunately) run when mounting via the `mount` command (and probably not with the `mount` system call either).
            ''; type = lib.types.lines; default = ""; };
            postUnmountCommands = lib.mkOption { description = ''
                Like `.preMountCommands`, but runs after unmounting the filesystem.
            ''; type = lib.types.lines; default = ""; };
                #Also, trying to create the "device" of a "nofail" mount will not work with `mount`, as it will not even attempt to mount anything (and thus not run the `.preMountCommands`) if the "device" is missing.
        }; } ]);
    }; };

    config = let

        assertions = lib.mkIf (!config.boot.initrd.systemd.enable) (lib.mapAttrsToList (name: fs: {
            assertion = (fs.preMountCommands == "") || (!utils.fsNeededForBoot fs);
            message = ''The filesystem "${name}" has `.preMountCommands` but is also (possibly implicitly) `.neededForBoot`. This is not supported without `boot.initrd.systemd.enable`.'';
        }) config.fileSystems);

        # The implementation is derived from the "mkfs-${device'}" service in nixpkgs.
        services = initrd: lib.fun.mapMergeUnique (_: fs@{ mountPoint, device, depends, ... }: if
            (fs.preMountCommands != "" || fs.postUnmountCommands != "") && initrd == utils.fsNeededForBoot fs
        then let
            isDevice = lib.fun.startsWith "/dev/" device;
            mountPoint' = utils.escapeSystemdPath mountPoint;
            device' = utils.escapeSystemdPath device;
        in { "pre-mount-${mountPoint'}" = rec { # TODO: in initrd (or during installation), how to deal with the fact that the system is not mounted at "/"?
            description = "Prepare mounting ${device} at ${mountPoint}";
            wantedBy = [ "${mountPoint'}.mount" ]; before = wantedBy; partOf = wantedBy;
            requires = lib.optional isDevice "${device'}.device"; after = lib.optional isDevice "${device'}.device";
            unitConfig.RequiresMountsFor = map utils.escapeSystemdExecArg (depends ++ (lib.optional (lib.hasPrefix "/" device) device) ++ [ (builtins.dirOf mountPoint) ]);
            unitConfig.DefaultDependencies = false; restartIfChanged = false;
            serviceConfig.Type = "oneshot"; serviceConfig.RemainAfterExit = true;
            script = lib.mkIf (fs.preMountCommands != "") fs.preMountCommands;
            preStop = lib.mkIf (fs.postUnmountCommands != "") fs.postUnmountCommands; # ("preStop" still runs post unmount)
        }; } else { }) config.fileSystems;

    in {
        inherit assertions;
        systemd.services = services false;
        boot.initrd.systemd.services = lib.mkIf (config.boot.initrd.systemd.enable) (services true);
    };

}
