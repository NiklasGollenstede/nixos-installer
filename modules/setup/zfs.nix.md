/*

# ZFS Pools and Datasets

This module primarily allows the specification of ZFS pools and datasets. The declared pools and datasets are complemented with some default and are then used by [`lib/setup-scripts/zfs.sh`](../../lib/setup-scripts/zfs.sh) to create them during system installation, and can optionally later be kept up to date (with the config) at config activation time or during reboot.
Additionally, this module sets some defaults for ZFS (but only in a "always better than nothing" style, so `lib.mkForce null` should never be necessary).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, options, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    inherit (inputs.config.rename) setup;
    cfg = config.${setup}.zfs;
    hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
in let module = {

    options.${setup} = { zfs = {
        enable = lib.mkEnableOption "NixOS managed ZFS pools and datasets";

        pools = lib.mkOption {
            description = "ZFS pools created during this host's installation.";
            type = lib.types.attrsOf (lib.types.nullOr (lib.types.submodule ({ name, ... }: { options = {
                name = lib.mkOption { description = "Attribute name as name of the pool."; type = lib.types.str; default = name; readOnly = true; };
                vdevArgs = lib.mkOption { description = "List of arguments that specify the virtual devices (vdevs) used when initially creating the pool. Can consist of the device type keywords and partition labels. The latter are prefixed with »/dev/mapper/« if a mapping with that name is configured or »/dev/disk/by-partlabel/« otherwise, and then the resulting argument sequence is is used verbatim in »zpool create«."; type = lib.types.listOf lib.types.str; default = [ name ]; example = [ "raidz1" "data1-..." "data2-..." "data3-..." "cache" "cache-..." ]; };
                props = lib.mkOption { description = "Zpool properties to pass when creating the pool. May also set »feature@...« and »compatibility«."; type = lib.types.attrsOf (lib.types.nullOr lib.types.str); default = { }; apply = lib.filterAttrs (k: v: v != null); };
                createDuringInstallation = (lib.mkEnableOption "creation of this pool during system installation. If disabled, the pool needs to exist already or be created manually and the pool's disk devices are expected to be present from the first boot onwards") // { default = true; };
                autoApplyDuringBoot = lib.mkOption { description = "Whether to automatically re-apply dataset properties and create missing child datasets in the initramfs phase during boot after this pool's declared datasets changed. This does not get triggered by external changes to the ZFS pool, but when triggered by changes in the declaration, it may affect/revert/correct them. Doing this in the initrd can be useful since the keystore is open but no datasets are mounted at that time."; type = lib.types.bool; default = true; };
                autoApplyOnActivation = lib.mkOption { description = "Same as »autoApplyDuringBoot«, but during system activation, not in the initrd. This works without rebooting, but may fail to apply some changes since datasets may be mounted and the keystore is usually closed at this time."; type = lib.types.bool; default = true; };
            }; config = {
                props.autotrim = lib.mkDefault "on"; # These days, there should be no reason not to trim.
                props.ashift = lib.mkOptionDefault "12"; # be explicit
                props.cachefile = lib.mkOptionDefault "none"; # If it works on first boot without (stateful) cachefile, then it will also do so later.
                props.comment = lib.mkOptionDefault (if (builtins.stringLength config.networking.hostName <= (32 - 9)) then "hostname=${config.networking.hostName}" else config.networking.hostName); # This is just nice to know which host this pool belongs to, without needing to inspect the datasets (»zpool import« shows the comment). The »comment« is limited to 32 characters.
            }; })));
            default = { };
            apply = lib.filterAttrs (k: v: v != null);
        };

        datasets = lib.mkOption {
            description = "ZFS datasets managed and mounted on this host.";
            type = lib.types.attrsOf (lib.types.nullOr (lib.types.submodule ({ name, ... }: { options = {
                name = lib.mkOption { description = "Attribute name as name of the dataset."; type = lib.types.str; default = name; readOnly = true; };
                props = lib.mkOption { description = "ZFS properties to set on the dataset."; type = lib.types.attrsOf (lib.types.nullOr lib.types.str); default = { }; apply = lib.filterAttrs (k: v: v != null); };
                recursiveProps = lib.mkOption { description = "Whether to apply this dataset's ».props« (but not ».permissions«) recursively to its children, even those that are not declared. This applies to invocations of the »ensure-dataset« function (called either explicitly or after changes by »...pools.*.autoApplyDuringBoot/autoApplyOnActivation«) and makes sense for declared leaf datasets that will have children that the NixOS configuration is not aware of (like receive targets)."; type = lib.types.bool; default = false; };
                mount = lib.mkOption { description = "Whether to create a »fileSystems« entry to mount the dataset. »noauto« creates an entry with that option set."; type = lib.types.enum [ true "noauto" false ]; default = false; };
                permissions = lib.mkOption { description = ''Permissions to set on the dataset via »zfs allow«. Attribute names should express propagation/who and match »/^[dl]?([ug]\d+|e)$/«, the values are the list of permissions granted.''; type = lib.types.attrsOf lib.types.commas; default = { }; };
                uid = lib.mkOption { description = "UID owning the dataset's root directory."; type = lib.types.ints.unsigned; default = 0; };
                gid = lib.mkOption { description = "GID owning the dataset's root directory."; type = lib.types.ints.unsigned; default = 0; };
                mode = lib.mkOption { description = "Permission mode of the dataset's root directory."; type = lib.types.str; default = "750"; };
            }; config = {
                props.canmount = lib.mkOptionDefault "off"; # (need to know this explicitly for each dataset)
            }; })));
            default = { };
            apply = lib.filterAttrs (k: v: v != null);
        };

        extraInitrdPools = lib.mkOption { description = "Additional pool that are imported in the initrd."; type = lib.types.listOf lib.types.str; default = [ ]; apply = lib.unique; };
    }; };

    config = let
    in lib.mkMerge [ (lib.mkIf cfg.enable (lib.mkMerge [ ({

        # boot.(initrd.)supportedFilesystems = [ "zfs" ]; # NixOS should figure that out itself based on zfs being used in »config.fileSystems«.
        # boot.zfs.extraPools = [ ]; # Don't need to import pools that have at least one dataset listed in »config.fileSystems« / with ».mount != false«.
        boot.zfs.devNodes = lib.mkDefault ''/dev/disk/by-partlabel" -d "/dev/mapper''; # Do automatic imports (initrd & systemd) by-partlabel or mapped device, instead of by-id, since that is how the pools were created. (This option is meant to support only a single path, but since it is not properly escaped, this works to pass two paths.)
        services.zfs.autoScrub.enable = true;
        services.zfs.trim.enable = true; # (default)
        networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName)); # ZFS requires one, so might as well set a default.

        ## Implement »cfg.datasets.*.mount«:
        fileSystems = lib.fun.mapMerge (path: { props, mount, ... }: if mount != false then {
            "${props.mountpoint}" = { fsType = "zfs"; device = path; options = [ "zfsutil" ] ++ (lib.optionals (mount == "noauto") [ "noauto" ]); };
        } else { }) cfg.datasets;

        ## Load keys (only) for (all) datasets that are declared as encryption roots and aren't disabled:
        boot.zfs.requestEncryptionCredentials = lib.attrNames (lib.filterAttrs (name: { props, ... }: if props?keylocation then props.keylocation != "file:///dev/null" else config.${setup}.keystore.keys?"zfs/${name}") cfg.datasets);

        ${setup} = {
            # Set default root dataset properties for every pool:
            zfs.datasets = lib.mapAttrs (name: { ... }: { props = {
                # Properties to set at the root dataset of the root pool at its creation. All are inherited by default, but some can't be changed later.
                devices = lib.mkOptionDefault "off"; # Don't allow character or block devices on the file systems, where they might be owned by non-root users.
                setuid = lib.mkOptionDefault "off"; # Don't allow suid binaries (NixOS puts them in »/run/wrappers/«).
                compression = lib.mkOptionDefault "lz4"; # Seems to be the best compromise between compression and CPU load.
                atime = lib.mkOptionDefault "off"; relatime = lib.mkOptionDefault "on"; # Very much don't need access times at all.

                acltype = lib.mkOptionDefault "posix"; # Enable ACLs (access control lists) on linux; might be useful at some point. (»posix« is the same as »posixacl«, but this is the normalized form)
                xattr = lib.mkOptionDefault "sa"; # Allow extended attributes and store them as system attributes, recommended with »acltype=posix«.
                dnodesize = lib.mkOptionDefault "auto"; # Recommenced with »xattr=sa«. (A dnode is roughly equal to inodes, storing file directory or meta data.)
                #normalization = lib.mkOptionDefault "formD"; # Don't enforce utf-8, and thus don't normalize file names; instead accept any byte stream as file name.

                canmount = lib.mkOptionDefault "off"; mountpoint = lib.mkOptionDefault "none"; # Assume the pool root is a "container", unless overwritten.
            }; }) cfg.pools;

            # All pools that have at least one dataset that (explicitly or implicitly) has a key to be loaded from »/run/keystore-.../zfs/« have to be imported in the initramfs while the keystore is open (but only if the keystore is not disabled):
            zfs.extraInitrdPools = lib.mkIf (config.boot.initrd.luks.devices?"keystore-${hash}") (lib.mapAttrsToList (name: _: lib.head (lib.splitString "/" name)) (lib.filterAttrs (name: { props, ... }: if props?keylocation then lib.fun.startsWith "file:///run/keystore-${hash}/" props.keylocation else config.${setup}.keystore.keys?"zfs/${name}") cfg.datasets));

            # Might as well set some defaults for all partitions required (though for all but one at least some of the values will need to be changed):
            disks.partitions = lib.fun.mapMergeUnique (name: { ${name} = { # (This also implicitly ensures that no partition is used twice for zpools.)
                type = lib.mkDefault "bf00"; size = lib.mkOptionDefault null; order = lib.mkDefault 500;
            }; }) (lib.fun.filterMismatching ''/|^(mirror|raidz[123]?|draid[123]?.*|spare|log|dedup|special|cache)$'' (lib.concatLists (lib.catAttrs "vdevArgs" (lib.attrValues cfg.pools))));
        };


    }) ({ ## Implement »cfg.extraInitrdPools«:

        boot.initrd.postDeviceCommands = (lib.mkAfter ''
            ${lib.concatStringsSep "\n" (map verbose.initrd-import-zpool cfg.extraInitrdPools)}
            ${verbose.initrd-load-keys}
        '');


    }) (lib.mkIf (config.boot.resumeDevice == "") { ## Disallow hibernation without fixed »resumeDevice«:

        boot.kernelParams = [ "nohibernate" "hibernate=no" ];
        assertions = [ { # Ensure that none is overriding the above:
            assertion = builtins.elem "nohibernate" config.boot.kernelParams;
            message = ''Hibernation with ZFS (and NixOS' initrd) without fixed »resumeDevice« can/will lead to pool corruption. Disallow it by setting »boot.kernelParams = [ "nohibernate" ]«'';
        } ];


    }) (lib.mkIf (false && (config.boot.resumeDevice != "")) { ## Make resuming after hibernation safe with ZFS:
        # or not: https://github.com/NixOS/nixpkgs/commit/c70f0473153c63ad1cf6fbea19f290db6b15291f

        boot.kernelParams = [ "resume=${config.boot.resumeDevice}" ];
        assertions = [ { # Just making sure ...
            assertion = builtins.elem "resume=${config.boot.resumeDevice}" config.boot.kernelParams;
            message = "When using ZFS and not disabling hibernation, make sure to set the »resume=« kernel parameter!";
        } ];

        boot.initrd.postDeviceCommands = let
            inherit (config.system.build) extraUtils;
        in (lib.mkBefore ''
            # After hibernation, the pools MUST NOT be imported before resuming, as doing so can corrupt them.
            # NixOS' mess of an initrd script does resuming after mounting FSs (which seems very unnecessarily late, resuming from a "file" doesn't need the FS to be mounted, does it?).
            # This should generally run after all (also mapped) devices are created, but before any ZFS action, so do the hibernation resume here.
            # But also only support a fixed »resumeDevice«. No guessing:

            resumeInfo="$(udevadm info -q property "${config.boot.resumeDevice}" )"
            if [ "$(echo "$resumeInfo" | sed -n 's/^ID_FS_TYPE=//p')" = "swsuspend" ]; then
                resumeMajor="$(echo "$resumeInfo" | sed -n 's/^MAJOR=//p')"
                resumeMinor="$(echo "$resumeInfo" | sed -n 's/^MINOR=//p')"
                echo -n "Attempting to resume from hibernation (device $resumeMajor:$resumeMinor as ${config.boot.resumeDevice}) ..."
                echo "$resumeMajor:$resumeMinor" > /sys/power/resume 2> /dev/null || echo "failed to wake from hibernation, continuing normal boot!"
            fi
        '');
            #setsid ${extraUtils}/bin/ash -c "exec ${extraUtils}/bin/ash < /dev/$console >/dev/$console 2>/dev/$console"
        boot.zfs = if (options.boot.zfs?allowHibernation) then { allowHibernation = true; } else { };


    }) (let ## Implement »cfg.pools.*.autoApplyDuringBoot« and »cfg.pools.*.autoApplyOnActivation«:

        inherit (config.system.build) extraUtils;
        anyPool = filterBy: lib.any (pool: pool.${filterBy}) (lib.attrValues cfg.pools);
        poolNames = filterBy: lib.attrNames (lib.filterAttrs (name: pool: pool.${filterBy}) cfg.pools);
        filter = pool: "^${pool}($|[/])";
        ensure-datasets = zfsPackage: pkgs.writeShellScript "ensure-datasets" ''
            ${lib.fun.substituteImplicit { inherit pkgs; scripts = lib.attrValues { inherit (lib.self.setup-scripts) zfs utils; }; context = { inherit config; native = pkgs // { zfs = zfsPackage; }; }; }}
            set -eu ; ensure-datasets "$@"
        '';
        ensure-datasets-for = filterBy: zfsPackage: ''( if [ ! "''${IN_NIXOS_ENTER:-}" ] && [ -e ${zfsPackage}/bin/zfs ] ; then
            ${lib.concatStrings (map (pool: ''
                expected=${lib.escapeShellArg (builtins.toJSON (lib.mapAttrs (n: v: v.props // (if v.permissions != { } then { ":permissions" = v.permissions; } else { })) (lib.filterAttrs (path: _: path == pool || lib.fun.startsWith "${pool}/" path) cfg.datasets)))}
                if [ "$(${zfsPackage}/bin/zfs get -H -o value nixos-${setup}:applied-datasets ${pool})" != "$expected" ] ; then
                    ${ensure-datasets zfsPackage} / ${lib.escapeShellArg (filter pool)} && ${zfsPackage}/bin/zfs set nixos-${setup}:applied-datasets="$expected" ${pool}
                fi
            '') (poolNames filterBy))}
        fi )'';
    in {

        boot.initrd.postDeviceCommands = lib.mkIf (anyPool "autoApplyDuringBoot") (lib.mkOrder 2000 ''
            ${ensure-datasets-for "autoApplyDuringBoot" extraUtils}
        '');
        boot.initrd.supportedFilesystems = lib.mkIf (anyPool "autoApplyDuringBoot") [ "zfs" ];
        ${setup}.zfs.extraInitrdPools = (poolNames "autoApplyDuringBoot");

        system.activationScripts.A_ensure-datasets = lib.mkIf (anyPool "autoApplyOnActivation") {
            text = ensure-datasets-for "autoApplyOnActivation" (pkgs.runCommandLocal "booted-system-link" { } ''ln -sT /run/booted-system/sw $out''); # (want to use the version of ZFS that the kernel module uses, also it's convenient that this does not yet exist during activation at boot)
        }; # these are sorted alphabetically, unless one gets "lifted up" by some other ending on it via its ».deps« field


    }) ])) (
        # Disable this module in VMs without filesystems:
        lib.mkIf (options.virtualisation?useDefaultFilesystems) { # (»nixos/modules/virtualisation/qemu-vm.nix« is imported, i.e. we are building a "vmVariant")
            ${setup}.zfs.enable = lib.mkIf config.virtualisation.useDefaultFilesystems (lib.mkVMOverride false);
        }
    ) ];

}; verbose = {

    # copied verbatim from https://github.com/NixOS/nixpkgs/blob/f989e13983fd1619f723b42ba271fe0b781dd24b/nixos/modules/tasks/filesystems/zfs.nix
    # It would be nice if this was done in a somewhat more composable way (why isn't this a function?) ...
    initrd-import-zpool = pool: ''
            echo -n "importing root ZFS pool \"${pool}\"..."
            # Loop across the import until it succeeds, because the devices needed may not be discovered yet.
            if ! poolImported "${pool}"; then
              for trial in `seq 1 60`; do
                poolReady "${pool}" > /dev/null && msg="$(poolImport "${pool}" 2>&1)" && break
                sleep 1
                echo -n .
              done
              echo
              if [[ -n "$msg" ]]; then
                echo "$msg";
              fi
              poolImported "${pool}" || poolImport "${pool}"  # Try one last time, e.g. to import a degraded pool.
            fi
    '';
    initrd-load-keys = let
        inherit (lib) isBool optionalString concatMapStrings; cfgZfs = config.boot.zfs;
    in ''
            ${if isBool cfgZfs.requestEncryptionCredentials
              then optionalString cfgZfs.requestEncryptionCredentials ''
                zfs load-key -a
              ''
              else concatMapStrings (fs: ''
                zfs load-key ${fs}
              '') cfgZfs.requestEncryptionCredentials}
    '';
}; in module
