/*

# `mount a -o noexec` Experiment

This is a (so far not successful) experiment to mount (almost) all filesystems as `noexec`, `nosuid` and `nodev` -- and to then deal with the consequences.


## Exceptions

* `/dev` and `/dev/pts` need `dev`
* `/run/wrappers` needs `exec` `suid`
* `/run/binfmt` needs `exec`
* `/run` `/run/user/*` may need `exec` (TODO: test)
* The Nix build dir (default: `/tmp`) needs `exec` (TODO!)
* Some parts of `/home/<user>/` will need `exec`


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.experiments.noexec;
in {

    options.${prefix} = { experiments.noexec = {
        enable = lib.mkEnableOption "(almost) all filesystems being mounted as »noexec« (and »nosuid« and »nodev«)";
    }; };

    config = let

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        # This was the only "special" mount that did not have »nosuid« and »nodev« set:
        systemd.packages = [ (lib.wip.mkSystemdOverride pkgs "dev-hugepages.mount" "[Mount]\nOptions=nosuid,nodev,noexec\n") ];
        # And these were missing »noexec«:
        boot.specialFileSystems."/dev".options = [ "noexec" ];
        boot.specialFileSystems."/dev/shm".options = [ "noexec" ];
        boot.specialFileSystems."/run/keys".options = [ "noexec" ];

        # Make all "real" FSs »noexec« (if »wip.fs.temproot.enable = true«):
        ${prefix}.fs.temproot = let
            it = { mountOptions = { nosuid = true; noexec = true; nodev = true; }; };
        in { temp = it; local = it; remote = it; };

        # Ensure that the /nix/store is not »noexec«, even if the FS it is on is:
        boot.initrd.postMountCommands = ''
            if ! mountpoint -q $targetRoot/nix/store ; then
                mount --bind $targetRoot/nix/store $targetRoot/nix/store
            fi
            mount -o remount,exec $targetRoot/nix/store
        '';
        # Nix has no (direct) settings to change where the builders have their »/build« bound to, but many builds will need it to be »exec«:
        systemd.services.nix-daemon = { # TODO: while noexec on /tmp is the problem, neither of this solve it:
            serviceConfig.PrivateTmp = true;
            #serviceConfig.PrivateMounts = true; serviceConfig.ExecStartPre = "/run/wrappers/bin/mount -o remount,exec /tmp";
        };

        nix.allowedUsers = [ "root" "@wheel" ]; # This goes hand-in-hand with setting mounts as »noexec«. Cases where a user other than root should build stuff are probably fairly rare. A "real" user might want to, but that is either already in the wheel(sudo) group, or explicitly adding that user is pretty reasonable.

        boot.postBootCommands = ''
            # Make the /nix/store non-iterable, to make it harder for unprivileged programs to search the store for programs they should not have access to:
            unshare --fork --mount --uts --mount-proc --pid -- ${pkgs.bash}/bin/bash -euc '
                mount --make-rprivate / ; mount --bind /nix/store /nix/store ; mount -o remount,rw /nix/store
                chmod -f 1770 /nix/store
                chmod -f  751 /nix/store/.links
            '
        '';


    }) ]);

}
