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
            postMountCommands = lib.mkOption { description = ''
                Like `.preMountCommands`, but runs after mounting the filesystem.
            ''; type = lib.types.lines; default = ""; };
            preUnmountCommands = lib.mkOption { description = ''
                Like `.preMountCommands`, but runs before unmounting the filesystem.
                This will only run before unmounting when the FS is unmounted by systemd before the FS is unmounted
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
        mkServices = inInitrd: lib.fun.mapMergeUnique (_: fs@{ mountPoint, device, depends, ... }: let
            isDevice = lib.fun.startsWith "/dev/" device;
            mountPoint' = utils.escapeSystemdPath mountPoint; mountPointDep = [ "${mountPoint'}.mount" ];
            device' = utils.escapeSystemdPath device;
            mkService = when: { # TODO: in initrd (or during installation), how to deal with the fact that the system is mounted at "/sysroot"?
                description = "Prepare mounting ${device} at ${mountPoint}";
                wantedBy = mountPointDep; ${if when != "after" then when else null} = mountPointDep; partOf = mountPointDep;
                requires = lib.optional isDevice "${device'}.device"; after = (lib.optionals (when == "after") mountPointDep) ++ (lib.optional isDevice "${device'}.device");
                unitConfig.RequiresMountsFor = map utils.escapeSystemdExecArg (depends ++ (lib.optional (lib.hasPrefix "/" device) device) ++ [ (builtins.dirOf mountPoint) ]);
                unitConfig.DefaultDependencies = false; restartIfChanged = false;
                serviceConfig.Type = "oneshot"; serviceConfig.RemainAfterExit = true;
            };
            prepare = ''
                #set -x
            '';
        in lib.optionalAttrs (inInitrd == utils.fsNeededForBoot fs) (
            (lib.optionalAttrs (
                fs.preMountCommands != "" || fs.postUnmountCommands != ""
            ) { "${mountPoint'}-before" = (mkService "before") // {
                script = lib.mkIf (fs.preMountCommands != "") (prepare + fs.preMountCommands);
                preStop = lib.mkIf (fs.postUnmountCommands != "") (prepare + fs.postUnmountCommands); # ("preStop" still runs post unmount)
            }; })
            // (lib.optionalAttrs (
                fs.postMountCommands != "" || fs.preUnmountCommands != ""
            ) { "${mountPoint'}-after" = (mkService "after") // {
                script = lib.mkIf (fs.postMountCommands != "") (prepare + fs.postMountCommands);
                preStop = lib.mkIf (fs.preUnmountCommands != "") (prepare + fs.preUnmountCommands);
            }; })
        )) config.fileSystems;

    in {
        inherit assertions;
        systemd.services = mkServices false;
        boot.initrd.systemd.services = lib.mkIf (config.boot.initrd.systemd.enable) (mkServices true);
    };

}
