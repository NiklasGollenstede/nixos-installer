/*

# TempRoot Layout Options

The core concept of NixOS is to maintain the hosts' programs and configuration in a stateless manner.
Hand in hand with that goes the need to (but also the advantages of) identifying anything stateful in the system.
Such state generally falls into one of four categories:
1) It is secret and/or can not be re-generated (without other information of the same kind).
2) It may or may not be secret, but re-generating it takes time or is impractical.
3) It may or may not be secret and can be re-generated quickly.

Category 1 data can not be included in the nix store and thus can not (directly) be derived from the system configuration.
It needs to be stored in a way that the host (and only the host) can access it an that it can't be lost.
It is therefore referred to as `remote` data (even though it would usually also be stored locally).

Category 2 data is required for the system to boot (in reasonable time), and should thus, as `local` data, be stored persistently on the host.
Parts that are not secret should be included in or generated from the system configuration.
Anything that is secret likely shouldn't be lost (i.e. is actually category 1) or can be re-generated from randomness or category 1 (and is thus category 3).

Category 3 data is expendable, and, as `temp` data, can thus be cleared on reboot or at other times.
Temporary data is the cheapest to (not) maintain, esp. in terms of administrative overhead, and should be used wherever possible.
Though incorrectly assigning data to `temp` that should be `local` or `remote` may break the system or cause data loss.

TempRoot is the concept of defaulting everything to `temp` and selectively whitelisting things as `local` or `remote`, by mounting an ephemeral root (`/`) file system and mounting/binding/linking various, sometimes many, nested paths to persistent storage.

This module implements the concept with different filesystem options for `remote`, `local` and `temp` data, while maintaining the same general mount structure regardless, which should make the choice of backing storage largely transparent for anything running on the system.

ZFS is capable of serving all three roles quite well.
Its pooling and datasets allow seamless allocation of storage between the categories, file-system level encryption and sending of encrypted, incremental dataset snapshots make it excellent for the `remote` role.
As backed for `local`, which primarily holds the nix store, it benefits from transparent compression, and checksumming.
With `fsync` disabled, and the ability to roll back snapshots, it also works to create very large storage areas for `temp` data.
ZFS though struggles on lower-end systems. BtrFS could probably be configured to serve the roles with similar capability.

F2FS also supports checksumming and compression, though it currently does not automatically reclaim space gained by the latter (and "manually" enabling it per file prevents `mmap`ing those files).
This and its design optimized for flash storage should make it an optimal backend for the `local` data, esp. on lower-end hardware.
EXT4 supports checksumming only for metadata, and does not support compression. Block device layers could in principle be used for this.
Using a sime filesystem with external backup tools is possible yet suboptimal for `remote` data, unless the system doesn't actually have any/much of it.

As long as the amount of `temp` data can be expected to stay within reasonable bounds, `tmpfs`es and swap can also be used to back the `temp` data.

The disk/partition declaration and the installer tooling refer to disks by GPT `partlabel`. They require the labels to be unique not only within a single target host, but also between the host that does the installation and the one being installed. It is therefore highly advisable (and in some places maybe implicitly expected) that the labels contain a unique host identifier, for example:
```nix
let hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName); in # ...
```


## Examples

This completely configures the disks, partitions, pool, datasets, and mounts for a ZFS `rpool` on a three-disk `raidz1` with read and write cache on an additional SSD, which also holds the boot partition and swap:
```nix
{ wip.fs.disks.devices = lib.genAttrs ([ "primary" "raidz1" "raidz2" "raidz3" ]) (name: { size = "16G"; }); # Need more than one disk, so must declare them. When installing to a physical disk, the declared size must match the actual size (or be smaller). The »primary« disk will hold all implicitly created partitions and those not stating a »disk«.
  wip.fs.boot.enable = true; wip.fs.boot.size = "512M"; # See »./boot.nix.md«. Creates a FAT boot partition.

  wip.fs.keystore.enable = true; # See »./keystore.nix.md«. With this enabled, »remote« will automatically be encrypted, with a random key by default.

  wip.fs.temproot.enable = true; # Use ZFS for all categories.
  wip.fs.temproot.temp.type = "zfs";
  wip.fs.temproot.local.type = "zfs";
  wip.fs.temproot.remote.type = "zfs";

  # Change/set the pools storage layout (see above), then adjust the partitions disks/sizes. Declaring disks requires them to be passed to the system installer.
  wip.fs.zfs.pools."rpool-${hash}".vdevArgs = [ "raidz1" "rpool-rz1-${hash}" "rpool-rz2-${hash}" "rpool-rz3-${hash}" "log" "rpool-zil-${hash}" "cache" "rpool-arc-${hash}" ];
  wip.fs.disks.partitions."rpool-rz1-${hash}" = { disk = "raidz1"; };
  wip.fs.disks.partitions."rpool-rz2-${hash}" = { disk = "raidz2"; };
  wip.fs.disks.partitions."rpool-rz3-${hash}" = { disk = "raidz3"; };
  wip.fs.disks.partitions."rpool-zil-${hash}" = { size = "2G"; };
  wip.fs.disks.partitions."rpool-arc-${hash}" = { }; } # (this is actually already implicitly declared)
```

On a less beefy system, but also with less data to manage, `tmpfs` works fine for `tmp`, and `f2fs` promises to get more performance out of the flash/ram/cpu:
```nix
{ # See above for these:
  #wip.fs.disks.devices.primary.size = "16G"; # (default)
  wip.fs.boot.enable = true; wip.fs.boot.size = "512M";
  wip.fs.keystore.enable = true;
  wip.fs.temproot.enable = true;

  wip.fs.temproot.temp.type = "tmpfs"; # Put `/` on a `tmpfs`.
  wip.fs.temproot.local.type = "bind"; # `bind`-mount all `local` locations to `/.local/*`, ...
  wip.fs.temproot.local.bind.base = "f2fs-encrypted"; # ... where a LUKS-encrypted F2FS is mounted.
  #wip.fs.keystore.keys."luks/local-${hash}/0" = "random"; # (implied by the »-encrypted« suffix above)
  #wip.fs.disks.partitions."local-${hash}".size = "50%"; # (default, fixed after installation)
  wip.fs.temproot.remote.type = "zfs";
  wip.fs.keystore.keys."luks/rpool-${hash}/0" = "random";
  #wip.fs.keystore.keys."zfs/rpool-${hash}/remote" = "random"; # (default)
  #wip.fs.zfs.pools."rpool-${hash}".vdevArgs = [ "rpool-${hash}" ]; # (default)
  #wip.fs.disks.partitions."rpool-${hash}" = { type = "bf00"; size = null; order = 500; }; # (default)

  # Default mounts/binds can also be removed, in this case causing logs to be removed on reboot:
  wip.fs.temproot.local.mounts."/var/log" = lib.mkForce null; }
```


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, utils, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.fs.temproot;
    hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
    keep = if cfg.remote.type == "none" then "local" else "remote"; # preferred place for data that should be kept

    optionsFor = type: desc: lib.wip.mergeAttrsRecursive [ ({
        zfs.dataset = lib.mkOption { description = "Dataset path under which to create the ${desc} »${type}« datasets."; type = lib.types.str; default = "rpool-${hash}/${type}"; };
    }) (lib.optionalAttrs (type != "temp") {
        bind.source = lib.mkOption { description = "Prefix for bind-mount targets."; type = lib.types.str; default = "/.${type}"; };
    }) (lib.optionalAttrs (type == "local") {
        bind.base = lib.mkOption { description = "Filesystem to automatically create as the ».source« for the bind mounts."; type = lib.types.enum [ null "f2fs" "f2fs-encrypted" "ext4" "ext4-encrypted" ]; default = null; };
    }) ({
        mounts = lib.mkOption {
            description = "Locations (for »temp« in addition to »/«) where a ${desc} filesystem should be mounted. Some are declared by default but may be removed by setting them to »null«.";
            type = lib.types.attrsOf (lib.types.nullOr (lib.types.submodule ({ name, ... }: { options = {
                target = lib.mkOption { description = "Attribute name as the mount target path."; type = lib.types.strMatching ''^/.*[^/]$''; default = name; readOnly = true; };
                source = lib.mkOption { description = "Relative source path of the mount. (Irrelevant for »tmpfs«.)"; type = lib.types.str; default = builtins.substring 1 (builtins.stringLength name - 1) name; };
                uid = lib.mkOption { description = "UID owning the mounted target."; type = lib.types.ints.unsigned; default = 0; };
                gid = lib.mkOption { description = "GID owning the mounted target."; type = lib.types.ints.unsigned; default = 0; };
                mode = lib.mkOption { description = "Permission mode of the mounted target."; type = lib.types.str; default = "750"; };
                options = lib.mkOption { description = "Additional mount options to set. Note that not all mount types support all options, they may be silently ignored or cause errors. »bind« supports setting »nosuid«, »nodev«, »noexec«, »noatime«, »nodiratime«, and »relatime«. »zfs« will explicitly heed »noauto«, the other options are applied but may conflict with the ones implied by the ».zfsProps«."; type = lib.types.attrsOf (lib.types.oneOf [ lib.types.bool lib.types.str lib.types.str lib.types.int ]); default = { }; };
                extraFsConfig = lib.mkOption { description = "Extra config options to set on the generated »fileSystems.*« entry (unless this mount is forced to »null«)."; type = lib.types.attrsOf lib.types.anything; default = { }; };
                zfsProps = lib.mkOption { description = "ZFS properties to set on the dataset, if mode type is »zfs«. Note that ZFS mounts made in the initramfs don't have the correct mount options from ZFS properties, so properties that affect mount options should (also) be set as ».options«."; type = lib.types.attrsOf (lib.types.nullOr lib.types.str); default = { }; };
            }; })));
            default = { };
            apply = lib.filterAttrs (k: v: v != null);
        };
        mountOptions = lib.mkOption { description = "Mount options that will be merged under ».mounts.*.options«."; type = lib.types.attrsOf (lib.types.oneOf [ lib.types.bool lib.types.str lib.types.str lib.types.int ]); default = { nosuid = true; nodev = true; noatime = true; }; };
    }) ];

    zfsNoSyncProps = { sync = "disabled"; logbias = "throughput"; }; # According to the documentation, »logbias« should be irrelevant without sync (i.e. no logging), but some claim setting it to »throughput« still improves performance.
in {

    options.${prefix} = { fs.temproot = {
        enable = lib.mkEnableOption "filesystem layouts with ephemeral root";

        # Settings for filesystems that will be cleared on reboot:
        temp = {
            type = lib.mkOption { description = ''
                "tmpfs": Creates »tmpfs« filesystems at »/« and all specified mount points.
                "zfs": ...
                "bind": Expects a filesystem to be mounted at »/«. Creates a hook to cre-create that filesystem on boot (TODO: implement and then enable this), and bind-mounts any additional mounts to ».bind.source+"/"+<mount.source>« (creating those paths if necessary).
            ''; type = lib.types.enum [ "tmpfs" "zfs" ]; default = "tmpfs"; };
        } // (optionsFor "temp" "temporary");

        # Settings for filesystems that persist across reboots:
        local = {
            type = lib.mkOption { description = ''
                "bind": Expects a (locally persistent) filesystem to be mounted at ».bind.target«, and bind-mounts any additional mounts to ».bind.source+"/"+<mount.source>« (creating those paths if necessary).
                "zfs": ...
            ''; type = lib.types.enum [ "bind" "zfs" ]; default = "bind"; };
        } // (optionsFor "local" "locally persistent");

        # Settings for filesystems that should have remote backups:
        remote = {
            type = lib.mkOption { description = ''
                "bind": Expects a filesystem to be mounted at ».bind.target« that gets backed. Bind-mounts any additional mounts to ».bind.source+"/"+<mount.source>« (creating those paths if necessary).
                "zfs": ...
                "none": Don't provide a »/remote«. For hosts that have no secrets or important state.
            ''; type = lib.types.enum [ "bind" "zfs" "none" ]; default = "bind"; };
        } // (optionsFor "remote" "remotely backed-up");

        swap = {
            size = lib.mkOption { description = "Size of the swap partition or file to create."; type = lib.types.nullOr lib.types.str; default = null; };
            encrypted = lib.mkOption { description = "Whether to encrypt the swap with a persistent key. Only relevant if ».asPartition = true«."; type = lib.types.bool; default = false; };
            asPartition = lib.mkOption { description = "Whether to create a swap partition instead of a file."; type = lib.types.bool; default = cfg.local.type == "zfs"; };
        };

        persistenceFixes = (lib.mkEnableOption "some fixes to cope with »/« being ephemeral") // { default = true; example = false; };

    }; };

    config = let

        optionsToList = attrs: lib.mapAttrsToList (k: v: if v == true then k else "${k}=${toString v}") (lib.filterAttrs (k: v: v != false) attrs);

    in lib.mkIf cfg.enable (lib.mkMerge ([ ({

        ${prefix} = {
            fs.temproot.temp.mounts = {
                "/tmp" = { mode = "1777"; };
            };
            fs.temproot.local.mounts = {
                "/local" = { source = "system"; mode = "755"; };
                "/nix" = { zfsProps = zfsNoSyncProps; mode = "755"; }; # this (or /nix/store) is required
                "/var/log" = { source = "logs"; mode = "755"; };
                # »/swap« is used by »cfg.swap.asPartition = false«
            };
            fs.temproot.remote.mounts = {
                "/remote" = { source = "system"; mode = "755"; extraFsConfig = { neededForBoot = true; }; }; # if any secrets need to be picked up by »activate«, they should be here
            };
        };

        boot.tmpOnTmpfs = false; # This would create a systemd mount unit for »/tmp«.


    }) ({ # Make each individual attribute on »wip.fs.temproot.*.mountOptions« a default, instead of having them be the default as a set:

        ${prefix}.fs.temproot = let
            it = { mountOptions = { nosuid = lib.mkOptionDefault true; nodev = lib.mkOptionDefault true; noatime = lib.mkOptionDefault true; }; };
        in { temp = it; local = it; remote = it; };


    }) (lib.mkIf cfg.persistenceFixes { # Cope with the consequences of having »/« (including »/{etc,var,root,...}«) cleared on every reboot.

        environment.etc.nixos.source = "/local/etc/nixos";

        systemd.tmpfiles.rules = [ # keep in mind: this does not get applied super early ...
            # »/root/.nix-channels« is already being restored.
            # »/var/lib/nixos« remains ephemeral. Where it matters, explicitly define a U/GID!

            # root's command history
            "f                                                            /${keep}/root/.bash_history                     0600  root  root  -"
            "L+ /root/.bash_history                  - - - -            ../${keep}/root/.bash_history"
            "f                                                            /${keep}/root/.local/share/nix/repl-history     0600  root  root  -"
            "L+ /root/.local/share/nix/repl-history  - - - -   ../../../../${keep}/root/.local/share/nix/repl-history"
        ];
        fileSystems = { # this does get applied early
            # (on systems without hardware clock, this allows systemd to provide an at least monolithic time after restarts)
            "/var/lib/systemd/timesync" = { device = "/local/var/lib/systemd/timesync"; options = [ "bind" "nofail" ]; }; # TODO: add »neededForBoot = true«?
            # save persistent timer states
            "/var/lib/systemd/timers" = { device = "/local/var/lib/systemd/timers"; options = [ "bind" "nofail" ]; }; # TODO: add »neededForBoot = true«?
        };
        security.sudo.extraConfig = "Defaults lecture=never"; # default is »once«, but we'd forget that we did that


    }) (lib.mkIf (cfg.swap.size != null && cfg.swap.asPartition) (let
        useLuks = config.${prefix}.fs.keystore.keys?"luks/swap-${hash}/0";
        device = "/dev/${if useLuks then "mapper" else "disk/by-partlabel"}/swap-${hash}";
    in {

        ${prefix} = {
            fs.disks.partitions."swap-${hash}" = { type = lib.mkDefault "8200"; size = lib.mkDefault cfg.swap.size; order = lib.mkDefault 1250; };
            fs.keystore.keys."luks/swap-${hash}/0" = lib.mkIf cfg.swap.encrypted (lib.mkOptionDefault "random");
        };
        swapDevices = [ { inherit device; } ];
        boot.resumeDevice = device;


    })) (lib.mkIf (cfg.swap.size != null && !cfg.swap.asPartition) {

        swapDevices = [ { device = "${cfg.local.bind.source}/swap"; size = (lib.wip.parseSizeSuffix cfg.swap.size) / 1024 / 1024; } ];


    }) (lib.mkIf (cfg.temp.type == "tmpfs") (let type = "temp"; in { # (only temp can be of type tmpfs)

        # TODO: this would probably be better implemented by creating a single /.temp tmpfs with a decent size restriction, and then bind-mounting all other mount points into that pool (or at least do that for any locations that are non-root writable?)

        fileSystems = lib.mapAttrs (target: args@{ uid, gid, mode, extraFsConfig, ... }: (extraFsConfig // {
            fsType = "tmpfs"; device = "tmpfs";
            options = (extraFsConfig.options or [ ]) ++ (optionsToList (cfg.${type}.mountOptions // args.options // { uid = toString uid; gid = toString gid; mode = mode; }));
        })) ({ "/" = { options = { }; uid = 0; gid = 0; mode = "755"; extraFsConfig = { }; }; } // cfg.${type}.mounts);


    })) (lib.mkIf (cfg.temp.type == "zfs") {

        boot.initrd.postDeviceCommands = lib.mkAfter ''
            echo 'Clearing root ZFS'
            ( zfs list -H -o name -t snapshot -r ${cfg.temp.zfs.dataset} | grep '@empty$' | xargs -n1 --no-run-if-empty zfs rollback -r )
        '';


    }) (lib.mkIf (cfg.temp.type == "bind") { # (TODO: this should completely clear or even recreate the »cfg.temp.bind.source«)

        boot.cleanTmpDir = true; # Clear »/tmp« on reboot.


    }) (lib.mkIf (cfg.local.type == "bind" && (cfg.local.bind.base != null)) (let # Convenience option to create a local F2FS/EXT4 optimized to host the nix store:
        type = if cfg.local.bind.base == "f2fs" || cfg.local.bind.base == "f2fs-encrypted" then "f2fs" else "ext4";
        encrypted = cfg.local.bind.base == "f2fs-encrypted" || cfg.local.bind.base == "ext4-encrypted";
        useLuks = config.${prefix}.fs.keystore.keys?"luks/local-${hash}/0";
    in {

        # TODO: fsck
        ${prefix} = {
            fs.keystore.keys."luks/local-${hash}/0" = lib.mkIf encrypted (lib.mkOptionDefault "random");
            fs.disks.partitions."local-${hash}" = {
                type = "8300"; order = lib.mkDefault 1000; disk = lib.mkDefault "primary"; size = lib.mkDefault (if cfg.remote.type == "none" then null else "50%");
            };
        };
        fileSystems.${cfg.local.bind.source} = {
            fsType = type; device = "/dev/${if useLuks then "mapper" else "disk/by-partlabel"}/local-${hash}";
        } // (if type == "f2fs" then {
            formatOptions = (lib.concatStrings [
                " -O extra_attr" # required by other options
                ",inode_checksum" # enable inode checksum
                ",sb_checksum" # enable superblock checksum
                ",compression" # allow compression
                #"-w ?" # "sector size in bytes"
                # sector ? segments < section < zone
            ]);
            options = optionsToList (cfg.local.mountOptions // {
                # F2FS compresses only for performance and wear. The whole uncompressed space is still reserved (in case the file content needs to get replaced by incompressible data in-place). To free the gained space, »ioctl(fd, F2FS_IOC_RELEASE_COMPRESS_BLOCKS)« needs to be called per file, making the file immutable. Nix could do that when moving stuff into the store.
                compress_mode = "fs"; # enable compression for all files
                compress_algorithm = "lz4"; # compress using lz4
                compress_chksum = true; # verify checksums (when decompressing data blocks?)
                lazytime = true; # update timestamps asynchronously
            });
        } else {
            formatOptions = (lib.concatStrings [
                " -O inline_data" # embed data of small files in the top-level inode
                ",has_journal,extent,huge_file,flex_bg,metadata_csum,64bit,dir_nlink,extra_isize" # (ext4 default options)
                #",lazy_journal_init,lazy_itable_init" # speed up creation (but: Invalid filesystem option set)
                " -I 256" # inode size (ext default, allows for timestamps past 2038)
                " -i 16384" # create one inode per 16k bytes of disk (ext default)
                " -b 4096" # block size (ext default)
                " -E nodiscard" # do not trim the whole blockdev upon formatting
                " -e panic" # when (critical?) FS errors are detected, reset the system
            ]); options = optionsToList (cfg.local.mountOptions // {
            });
        });
        # TODO: "F2FS and its tools support various parameters not only for configuring on-disk layout, but also for selecting allocation and cleaning algorithms."
        boot.initrd.kernelModules = [ type ]; # This is not generally, but sometimes, required to boot. Strange. (Kernel message: »request_module fs-f2fs succeeded, but still no fs?«)


    })) ] ++ (map (type: (lib.mkIf (cfg.${type}.type == "bind") {

        fileSystems = (lib.mapAttrs (target: args@{ source, uid, gid, mode, extraFsConfig, ... }: extraFsConfig // (rec {
            device = "${cfg.${type}.bind.source}/${source}";
            options = (extraFsConfig.options or [ ]) ++ (optionsToList (cfg.${type}.mountOptions // args.options // { bind = true; }));
            preMountCommands = ''
                ${extraFsConfig.preMountCommands or ""}
                mkdir -pm 000 -- ${lib.escapeShellArg target}
                mkdir -pm 000 -- ${lib.escapeShellArg device}
                chown ${toString uid}:${toString gid} -- ${lib.escapeShellArg device}
                chmod ${mode} -- ${lib.escapeShellArg device}
            '';
        })) cfg.${type}.mounts) // {
            ${cfg.${type}.bind.source} = { neededForBoot = lib.any utils.fsNeededForBoot (lib.attrValues (builtins.intersectAttrs cfg.${type}.mounts config.fileSystems)); };
        };


    })) [ "temp" "local" "remote" ]) ++ (map (type: (lib.mkIf (cfg.${type}.type == "zfs") (let
        dataset = cfg.${type}.zfs.dataset;
    in {

        ${prefix} = {
            fs.zfs.enable = true;
            fs.zfs.pools.${lib.head (lib.splitString "/" dataset)} = { }; # ensure the pool exists (all properties can be adjusted)
            fs.keystore.keys."zfs/${dataset}" = lib.mkIf (type == "remote" && config.${prefix}.fs.keystore.enable) (lib.mkOptionDefault "random"); # the entire point of ZFS remote are backups, and those should be encrypted

            fs.zfs.datasets = {
                ${dataset} = {
                    mount = false; props = { canmount = "off"; mountpoint = "/"; } // (if type == "temp" then { refreservation = "1G"; } // zfsNoSyncProps else { });
                };
            } // (if type == "temp" then {
                "${dataset}/root" = {
                    mount = true; props = { canmount = "noauto"; mountpoint = "/"; }; mode = "755";
                };
            }  else { }) // (lib.wip.mapMerge (target: { source, options, zfsProps, uid, gid, mode, ... }: {
                "${dataset}/${source}" = {
                    mount = if (options.noauto or false) == true then "noauto" else true; inherit uid gid mode;
                    props = { canmount = "noauto"; mountpoint = target; } // zfsProps;
                };
            } // (
                lib.wip.mapMerge (prefix: if (lib.any (_:_.source == prefix) (lib.attrValues cfg.${type}.mounts)) then { } else {
                    "${dataset}/${prefix}" = lib.mkDefault { props.canmount = "off"; };
                }) (lib.wip.parentPaths source)
            )) cfg.${type}.mounts);
        };

        fileSystems = lib.mapAttrs (target: args@{ extraFsConfig, ... }: extraFsConfig // {
            options = (extraFsConfig.options or [ ]) ++ (optionsToList (cfg.${type}.mountOptions // args.options));
        }) ((if type == "temp" then { "/" = { options = { }; extraFsConfig = { }; }; } else { }) // cfg.${type}.mounts);

    }))) [ "temp" "local" "remote" ])));

}
