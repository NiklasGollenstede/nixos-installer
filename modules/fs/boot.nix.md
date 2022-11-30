/*

# Boot(-loader) File Systems

This is a simple shortcut to define and mount a boot/firmware/EFI partition and file system, such that they can get created automatically.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.fs.boot;
    hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
in {

    options.${prefix} = { fs.boot = {
        enable = lib.mkEnableOption "configuration of a boot partition as GPT partition 1 on the »primary« disk and a FAT32 filesystem on it";
        mountpoint = lib.mkOption { description = "Path at which to mount a vfat boot partition."; type = lib.types.str; default = "/boot"; };
        createMbrPart = lib.mkOption { description = "Whether to create a hybrid MBR with (only) the boot partition listed as partition 1."; type = lib.types.bool; default = true; };
        size = lib.mkOption { description = "Size of the boot partition, should be *more* than 32M(iB)."; type = lib.types.str; default = "2G"; };
    }; };

    config = let
    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        ${prefix} = {
            fs.disks.partitions."boot-${hash}" = { type = lib.mkDefault "ef00"; size = lib.mkDefault cfg.size; index = lib.mkDefault 1; order = lib.mkDefault 1500; disk = lib.mkOptionDefault "primary"; }; # require it to be part1, and create it early
            fs.disks.devices = lib.mkIf cfg.createMbrPart { primary = { mbrParts = lib.mkDefault "1"; extraFDiskCommands = ''
                t;1;c  # type ; part1 ; W95 FAT32 (LBA)
                a;1    # active/boot ; part1
            ''; }; };
        };
        fileSystems.${cfg.mountpoint} = { fsType = "vfat"; device = "/dev/disk/by-partlabel/boot-${hash}"; neededForBoot = true; options = [ "nosuid" "nodev" "noexec" "noatime" "umask=0027" ]; formatOptions = "-F 32"; };

    }) ]);

}
