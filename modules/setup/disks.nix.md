/*

# Disk Declarations

Options to declare devices and partitions to be picked up by the installer scripts.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    inherit (inputs.config.rename) setup;
    cfg = config.${setup}.disks; globalConfig = config;
    types.guid = lib.types.strMatching ''^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'';
in {

    options.${setup} = { disks = {
        devices = lib.mkOption {
            description = "Set of disk devices that this host will be installed on.";
            type = lib.types.attrsOf (lib.types.nullOr (lib.types.submodule ({ name, ... }: { options = {
                name = lib.mkOption { description = "Name that this device is being referred to as in other places."; type = lib.types.str; default = name; readOnly = true; };
                guid = lib.mkOption { description = "GPT disk GUID of the disk."; type = types.guid; default = lib.fun.sha256guid ("gpt-disk:${name}"+":${globalConfig.networking.hostName}"); };
                size = lib.mkOption { description = "The size of the disk, either as number in bytes or as argument to »parseSizeSuffix«. When installing to a physical device, its size must match; images are created with this size."; type = lib.types.either lib.types.ints.unsigned lib.types.str; apply = lib.fun.parseSizeSuffix; default = "16G"; };
                sectorSize = lib.mkOption { description = "The disk's logical sector size in bytes. Used to convert (e.g.) partition sizes in sectors to bytes or vice versa."; type = lib.types.ints.unsigned; default = 512; };
                allowLarger = lib.mkOption { description = "Whether to allow installation to a physical disk that is larger than the declared size."; type = lib.types.bool; default = true; };
                serial = lib.mkOption { description = "Serial number of the specific hardware device to use. If set the device path passed to the installer must point to the device with this serial. Use » udevadm info --query=property --name=$DISK | grep -oP 'ID_SERIAL_SHORT=\K.*' || echo '<none>' « to get the serial."; type = lib.types.nullOr lib.types.str; default = null; };
                alignment = lib.mkOption { description = "Default alignment quantifier for partitions on this device. Should be at least the optimal physical write size of the device, but going larger at worst wastes this many times the number of partitions disk sectors."; type = lib.types.int; default = 16384; };
                gptOffset = lib.mkOption { description = "Offset of the partition tables, inwards from where (third / 2nd last) they usually are."; type = lib.types.ints.unsigned; default = 0; };
                mbrParts = lib.mkOption { description = "Up to three colon-separated (GPT) partition numbers that will be made available in a hybrid MBR."; type = lib.types.nullOr lib.types.str; default = null; };
                extraFDiskCommands = lib.mkOption { description = "»fdisk« menu commands to run against the hybrid MBR. ».mbrParts« 1[2[3]] exist as transfers from the GPT table, and part4 is the protective GPT part. Can do things like marking partitions as bootable or changing their type. Spaces and end-of-line »#«-prefixed comments are removed, new lines and »;« also mean return."; type = lib.types.lines; default = ""; example = ''
                    t;1;c  # type ; part1 ; W95 FAT32 (LBA)
                    a;1    # active/boot ; part1
                ''; };
                partitionDuringInstallation = (lib.mkEnableOption "partitioning of this disk during system installation. If disabled, the disk needs be partitioned, and its filesystems formatted, already or manually. Declaring filesystems or LUKS mappings on unpartitioned devices via `/dev/disk/by-partlabel/...` will currently break the installation.") // { default = true; };
            }; })));
            default = { primary = { }; };
            apply = lib.filterAttrs (k: v: v != null);
        };
        partitions = lib.mkOption {
            description = "Set of disks disk partitions that the system will need/use. Partitions will be created on their respective ».disk«s in ».order« using »sgdisk -n X:+0+$size«.";
            type = lib.types.attrsOf (lib.types.nullOr (lib.types.submodule ({ name, config, ... }: { options = {
                name = lib.mkOption { description = "Name/partlabel that this partition can be referred to as once created."; type = lib.types.str; default = name; readOnly = true; };
                guid = lib.mkOption { description = "GPT partition GUID of the partition."; type = types.guid; default = lib.fun.sha256guid ("gpt-part:${name}"+":${globalConfig.networking.hostName}"); };
                disk = lib.mkOption { description = "Name of the disk that this partition resides on, which will automatically be declared with default options."; type = lib.types.str; default = "primary"; };
                type = lib.mkOption { description = "»gdisk« partition type of this partition."; type = lib.types.str; };
                size = lib.mkOption { description = "Partition size, either as integer suffixed with »K«, »M«, »G«, etc for sizes in XiB, or an integer suffixed with »%« for that portion of the size of the actual disk the partition gets created on. Or »null« to fill the remaining disk space."; type = lib.types.nullOr lib.types.str; default = null; };
                position = lib.mkOption { description = "Position at which to create the partition. The default »+0« means the beginning of the largest free block."; type = lib.types.str; default = "+0"; };
                alignment = lib.mkOption { description = "Adjusted alignment quantifier for this partition only."; type = lib.types.nullOr lib.types.int; default = null; example = 1; };
                index = lib.mkOption { description = "Optionally explicit partition table index to place this partition in. Use ».order« to make sure that this index hasn't been used yet.."; type = lib.types.nullOr lib.types.int; default = null; };
                order = lib.mkOption { description = "Creation order ranking of this partition. Higher orders will be created first, and will thus be placed earlier in the partition table (if ».index« isn't explicitly set) and also further to the front of the disk space. No partitions may follow one that has ».size == null«. The computed default puts the partition(s) with ».size == null« last (»500«), partitions with an ».index« before that (»744 + .index«, sorted), and all other partitions at the front (»1000«, unordered)."; type = lib.types.int; default = if config.size == null then 500 else (1000 - (if config.index == null then 0 else 256 - config.index)); };
            }; })));
            default = { };
            apply = lib.filterAttrs (k: v: v != null);
        };
        partitionList = lib.mkOption { description = "Partitions as a sorted list."; type = lib.types.listOf (lib.types.attrsOf lib.types.anything); default = lib.sort (before: after: before.order >= after.order) (lib.attrValues cfg.partitions); readOnly = true; internal = true; };
        partitioning = lib.mkOption { description = "The resulting disk partitioning as »sgdisk --backup --print« per disk."; type = lib.types.package; readOnly = true; internal = true; };
    }; };

    config.${setup} = {
        # (Don't) create all devices referenced by partitions: (The problem with this is that all device attributes depend on the partition attributes, and it would thus be impossible to have a dependency in reverse (e.g. a partition's size based on the disk size).)
        #disks.devices = lib.genAttrs (lib.catAttrs "disk" config.${setup}.disks.partitionList) (name: { });

        disks.partitioning = let
            partition-disk = { name = "partition-disk"; text = lib.fun.extractBashFunction (builtins.readFile lib.self.setup-scripts.disk) "partition-disk"; };
            esc = lib.escapeShellArg; native = pkgs.buildPackages;
        in pkgs.runCommand "partitioning-${config.networking.hostName}" { } ''
            ${lib.fun.substituteImplicit { inherit pkgs; scripts = [ partition-disk ]; context = { inherit config native; }; }} # inherit (builtins) trace;
            set -u ; mkdir -p $out ; declare -A args=([debug]=1)
            ${lib.concatStrings (lib.mapAttrsToList (name: disk: ''
                name=${esc name} ; img=$name.img
                ${native.coreutils}/bin/truncate -s ${esc disk.size} "$img"
                partition-disk "$name" "$img" ${toString (lib.fun.parseSizeSuffix disk.size)}
                ${native.gptfdisk}/bin/sgdisk --backup=$out/"$name".backup "$img"
                ${native.gptfdisk}/bin/sgdisk --print "$img" >$out/"$name".gpt
                ${if disk.mbrParts != null then ''
                    ${native.util-linux}/bin/fdisk --type mbr --list "$img" >$out/"$name".mbr
                '' else ""}
            '') cfg.devices)}
        '';
    };

}
