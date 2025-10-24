/*

# `fileSystems.*.preMountCommands`/`.postUnmountCommands`

So far, this has been shown to work as `preMountCommands` and `postUnmountCommands` in the normal system and as `preMountCommands` and `postMountCommands` in the systemd initrd.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, pkgs, lib, utils, ... }: let lib = inputs.self.lib.__internal__; in let
in {

    options = {
        fileSystems = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule [ { options = {
            preMountCommands = lib.mkOption { description = ''
                Commands to be run as root every time before mounting this filesystem **via systemd**, but after all its dependents were mounted.
                If, for whatever reason, the mount point is already mounted (which should never be the case), then the commands will be skipped.

                If this mount is (implicitly or explicitly) `.neededForBoot`, then the commands are (also) added to the initrd boot stage (systemd only).
                But note that the mount point in the initrd is different (prefixed with `/sysroot`).
                To write commands that work in the initrd and afterwards, prefix all paths (mount points, bind sources, but not `/dev`) with the shell variable `root`, which is set to `/sysroot/` in the initrd and `/` afterwards.
                Also consider the limited tools available in the initrd, esp. stat the full `/nix/store` is not yet there.

                Since systemd will only attempt the mount (and thus run these commands) if its pre-conditions are met -- it is thus not possible to use these commands to create things that systemd thinks should be created by other units.

                This does not order itself before or after `systemd-fsck@''${utils.escapeSystemdPath device}.service`.
                Note that if a symlink exists at a mount point when systemd's fstab-generator runs, it will read/resolve the symlink and use the link's target as the mount point, resulting in mismatching unit names for that mount, effectively disabling its `.preMountCommands`.
                This does not (apparently and unfortunately) run when mounting via the `mount` command (and probably not with the `mount` system call either).
            ''; type = lib.types.lines; default = ""; };
            postMountCommands = lib.mkOption { description = ''
                Like `.preMountCommands`, but runs after mounting the filesystem.
                Note that for mounts made in the initrd, these commands will run again in the normal system once systemd acknoledges the mount made earlier.
            ''; type = lib.types.lines; default = ""; };
            preUnmountCommands = lib.mkOption { description = ''
                Like `.preMountCommands`, but runs before unmounting the filesystem.
                This will only run before unmounting when the FS is unmounted via systemd. If it is unmounted by other means, systemd can only adjust the mount units state afterwards, and the commands will be skipped.
                You may want to compensate for that in the `.postUnmountCommands`.
            ''; type = lib.types.lines; default = ""; };
            postUnmountCommands = lib.mkOption { description = ''
                Like `.preMountCommands`, but runs after unmounting the filesystem.
            ''; type = lib.types.lines; default = ""; };
                #Also, trying to create the "device" of a "nofail" mount will not work with `mount`, as it will not even attempt to mount anything (and thus not run the `.preMountCommands`) if the "device" is missing. # TODO: is that actually different? For "nofail" systemd holds back, and otherwise it just attempts the mount?
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
            mountPoint' = if inInitrd then "/sysroot${mountPoint}" else mountPoint;
            mountPoint'' = utils.escapeSystemdPath mountPoint'; mountPointDep = [ "${mountPoint''}.mount" ];
            device' = utils.escapeSystemdPath (if inInitrd && isDevice then "/sysroot${mountPoint}" else device);
            mkService = when: {
                description = "Prepare mounting ${device} at ${mountPoint'}";
                wantedBy = mountPointDep; ${if when != "after" then when else null} = mountPointDep; partOf = mountPointDep;
                requires = lib.optional isDevice "${device'}.device"; after = (lib.optionals (when == "after") mountPointDep) ++ (lib.optional isDevice "${device'}.device");
                unitConfig.RequiresMountsFor = map utils.escapeSystemdExecArg (depends ++ (lib.optional (lib.hasPrefix "/" device) device) ++ [ (builtins.dirOf mountPoint') ]);
                unitConfig.DefaultDependencies = false;
                serviceConfig.Type = "oneshot"; serviceConfig.RemainAfterExit = true;
                path = lib.optional (!inInitrd) pkgs.util-linux;
            } // (lib.optionalAttrs (!inInitrd) {
                restartIfChanged = false;
            });
            prepare = ''
                set -uo pipefail
                root=''${root:-${if inInitrd then "/sysroot/" else "/"}}
            '';
            requireMounted = mounted: time: ''
                if ${if mounted then "!" else ""} mountpoint -q $root${lib.escapeShellArg mountPoint} ; then
                    echo $root${lib.escapeShellArg mountPoint} is ${time} ${if mounted then "not " else ""} 'mounted, skipping commands' >&2
                    exit 0 # it is an error, but we don't want to cause other units to fail because of it
                fi
            '';
        in lib.optionalAttrs (!inInitrd || utils.fsNeededForBoot fs) (
            (lib.optionalAttrs (
                fs.preMountCommands != "" || fs.postUnmountCommands != ""
            ) { "${mountPoint''}-before" = (mkService "before") // {
                script = lib.mkIf (fs.preMountCommands != "") (prepare + (requireMounted false "already") + fs.preMountCommands);
                preStop = lib.mkIf (fs.postUnmountCommands != "") (prepare + (requireMounted false "still") + fs.postUnmountCommands); # ("preStop" still runs post unmount)
            }; })
            // (lib.optionalAttrs (
                fs.postMountCommands != "" || fs.preUnmountCommands != ""
            ) { "${mountPoint''}-after" = (mkService "after") // {
                script = lib.mkIf (fs.postMountCommands != "") (prepare + (requireMounted true "still") + fs.postMountCommands);
                preStop = lib.mkIf (fs.preUnmountCommands != "") (prepare + (requireMounted true "already") + fs.preUnmountCommands);
            }; })
        )) config.fileSystems;

    in {
        inherit assertions;
        systemd.services = mkServices false;
        boot.initrd.systemd.services = lib.mkIf (config.boot.initrd.systemd.enable) (mkServices true);
        boot.initrd.systemd.extraBin = lib.mkIf (config.boot.initrd.systemd.enable && (mkServices true) != { }) {
            mountpoint = "${config.boot.initrd.systemd.package.util-linux}/bin/mountpoint";
        };
    };

}
