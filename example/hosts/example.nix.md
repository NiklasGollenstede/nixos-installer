/*

# Example Host Configuration

Just to provide an example of what a host configuration using this set of libraries can look like.


## Installation

To install the system to a (set of) virtual machine disk images, with `$hostname` as any of the `instances` below, run in `..`:
```bash
 nix run .'#'$hostname -- install-system --disks=/tmp/$hostname/
```
Then to boot the system in a qemu VM with KVM:
```bash
 nix run .'#'$hostname -- run-qemu --disks=/tmp/$hostname/
```
See `nix run .#$hostname -- --help` for options and more commands.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in let
    hash = builtins.substring 0 8 (builtins.hashString "sha256" name);
in { preface = { # (any »preface« options have to be defined here)
    instances = [ "explicit-fs" "complex-fs" "minimal-setup" "encrypted" "multi-disk-raidz" "rpi" ]; # Generate multiple variants of this host, with these »name«s.
}; imports = [ ({ ## Hardware

    nixpkgs.hostPlatform = if name == "rpi" then "aarch64-linux" else "x86_64-linux"; system.stateVersion = "24.05";

    ## What follows is a whole bunch of boilerplate-ish stuff, most of which multiple hosts would have in common and which would thus be moved to one or more modules:

    boot.loader.extlinux.enable = name != "rpi";
    boot.loader.grub.enable = false;

    # Example of adding and/or overwriting setup/maintenance functions:
    #installer.scripts.install-overwrite.path = ../lib/install.sh.md;

    boot.initrd.systemd.enable = true;


}) (lib.mkIf (name == "explicit-fs") { ## Minimal explicit FS setup

    # Declare a boot and system partition.
    setup.disks.partitions."boot-${hash}"   = { type = "ef00"; size = "64M"; index = 1; order = 1500; };
    setup.disks.partitions."system-${hash}" = { type = "8300"; size = null; order = 500; };
    # Though not required for EFI, make the boot part visible to boot loaders supporting only MBR.
    setup.disks.devices = { primary = { mbrParts = "1"; extraFDiskCommands = ''
        t;1;c  # set type ; part1 ; W95 FAT32 (LBA)
        a;1    # set as active/bootable ; part1
    ''; }; };
    setup.bootpart.enable = false; # (enabled by the bootloader)

    # Put everything except for /boot and /nix/store on a tmpfs. This is the absolute minimum, most usable systems require some more paths that are persistent (e.g. all of /nix and /home).
    fileSystems."/"          = { fsType  =  "tmpfs";    device = "tmpfs"; neededForBoot = true; options = [ "mode=755" ]; };
    fileSystems."/boot"      = { fsType  =   "vfat";    device = "/dev/disk/by-partlabel/boot-${hash}"; neededForBoot = true; options = [ "noatime" ]; formatArgs = [ "-F" "32" ]; };
    fileSystems."/system"    = { fsType  =   "ext4";    device = "/dev/disk/by-partlabel/system-${hash}"; neededForBoot = true; options = [ "noatime" ]; formatArgs = [ "-O" "inline_data" "-E" "nodiscard" "-F" ]; };
    fileSystems."/nix/store" = { options = ["bind,ro"]; device = "/system/nix/store"; neededForBoot = true; };


}) (lib.mkIf (name == "complex-fs") { ## More complex but automatic FS setup

    #setup.disks.devices.primary.size = "16G"; # (default)
    setup.bootpart.enable = true; setup.bootpart.size = "512M";

    setup.keystore.enable = true;
    setup.temproot.enable = true;

    setup.temproot.swap.size = "2G";
    setup.temproot.swap.asPartition = true;
    setup.temproot.swap.encrypted = true;

    setup.temproot.temp.type = "tmpfs";

    setup.temproot.local.type = "bind";
    setup.temproot.local.bind.base = "f2fs-encrypted"; # creates partition and FS
    #setup.keystore.keys."luks/local-${hash}/0" = "random"; # (implied by the »-encrypted« suffix above)
    #setup.disks.partitions."local-${hash}".size = "50%"; # (default)

    setup.temproot.remote.type = "zfs";
    setup.keystore.keys."luks/rpool-${hash}/0" = "random";
    #setup.keystore.keys."zfs/rpool-${hash}/remote" = "random"; # (default)
    #setup.zfs.pools."rpool-${hash}".vdevArgs = [ "rpool-${hash}" ]; # (default)
    #setup.disks.partitions."rpool-${hash}" = { type = "bf00"; size = null; order = 500; }; # (default)

    setup.temproot.local.mounts."/var/log" = lib.mkForce null; # example: don't keep logs


}) (lib.mkIf (name == "minimal-setup") { ## Minimal automatic FS setup

    setup.bootpart.enable = true; # (also set by »boot.loader.extlinux.enable«)
    setup.temproot.enable = true;
    setup.temproot.temp.type = "tmpfs"; # (default)
    setup.temproot.local.type = "bind"; # (default)
    setup.temproot.local.bind.base = "f2fs";
    setup.temproot.remote.type = "none";


}) (lib.mkIf (name == "encrypted") { ## Encrypted FS setup

    setup.keystore.enable = true;
    setup.keystore.keys."luks/keystore-${hash}/0" = "random"; # (this makes little practical sense)
    setup.keystore.keys."luks/keystore-${hash}/1" = "constant=insecure"; # static password: "insecure"
    #setup.keystore.keys."luks/keystore-${hash}/2" = "password"; # password prompted at installation
    #setup.keystore.keys."luks/rpool-${hash}/0" = "random";
    setup.temproot = {
        enable = true;
        temp.type = "zfs"; local.type = "zfs"; remote.type = "zfs";
        #temp.type = "zfs"; local.type = "zfs"; remote.type = "none";
        #local.bind.base = "f2fs"; remote.type = "none";
        swap = { size = "2G"; asPartition = true; encrypted = true; };
    };
    setup.keystore.unlockMethods.pinThroughYubikey = true;
    #setup.keystore.keys."zfs/rpool-${hash}/remote" = null;
    #setup.keystore.keys."luks/rpool-${hash}/0" = "random";


}) (lib.mkIf (name == "multi-disk-raidz") { ## Multi-disk ZFS setup

    boot.loader.extlinux.enable = lib.mkForce false; # use UEFI boot this time
    boot.loader.systemd-boot.enable = true;

    setup.disks.devices = lib.genAttrs ([ "primary" "raidz1" "raidz2" "raidz3" ]) (name: { size = "16G"; });
    setup.bootpart.enable = true; setup.bootpart.size = "512M";

    setup.keystore.enable = true;
    setup.temproot.enable = true;

    setup.temproot.temp.type = "zfs";
    setup.temproot.local.type = "zfs";

    setup.temproot.remote.type = "zfs";
    setup.zfs.pools."rpool-${hash}".vdevArgs = [ "raidz1" "rpool-rz1-${hash}" "rpool-rz2-${hash}" "rpool-rz3-${hash}" "log" "rpool-zil-${hash}" "cache" "rpool-arc-${hash}" ];
    setup.disks.partitions."rpool-rz1-${hash}" = { type = "bf00"; disk = "raidz1"; };
    setup.disks.partitions."rpool-rz2-${hash}" = { type = "bf00"; disk = "raidz2"; };
    setup.disks.partitions."rpool-rz3-${hash}" = { type = "bf00"; disk = "raidz3"; };
    setup.disks.partitions."rpool-zil-${hash}" = { type = "bf00"; size = "2G"; };
    setup.disks.partitions."rpool-arc-${hash}" = { type = "bf00"; };


}) (lib.optionalAttrs (name == "rpi") { ## Booting on Raspberry PIs
    # This is mostly a demo for the `extra-files` module, but it does produce an image that boots on a rPI4

    setup.temproot = { enable = true; local.bind.base = "ext4"; remote.type = "none"; };
    setup.bootpart.enable = true;

    boot.loader.generic-extlinux-compatible.enable = true;
    boot.loader.extra-files.enable = true;
    boot.loader.extra-files.files = let
        fw = files: lib.genAttrs files (file: { source = "${pkgs.raspberrypifw}/share/raspberrypi/boot/${file}"; });
    in {
        "config.txt".format = lib.generators.toINI { listsAsDuplicateKeys = true; };
        "config.txt".text = lib.mkOrder 100 ''
            # Generated file. Do not edit.
        '';
        "config.txt".data.all = {
            arm_64bit = 1; enable_uart = 1; avoid_warnings = 1;
        };
        "config.txt".data.pi4 = {
            enable_gic = 1; disable_overscan = 1; arm_boost = 1;
            kernel = "u-boot-rpi4.bin";
            armstub = "armstub8-gic.bin";
        };
        "u-boot-rpi4.bin".source = "${pkgs.ubootRaspberryPi4_64bit}/u-boot.bin";
        "armstub8-gic.bin".source = "${pkgs.raspberrypi-armstubs}/armstub8-gic.bin";
    } // (fw [
        "start4.elf" "fixup4.dat" "bcm2711-rpi-cm4s.dtb" "bcm2711-rpi-400.dtb" "bcm2711-rpi-4-b.dtb" "bcm2711-rpi-cm4.dtb" "bcm2711-rpi-cm4-io.dtb"
    ]);

    #imports = [ "${inputs.nixos-hardware}/raspberry-pi/4" ]; # activating the correct hardware config should help
    #hardware.deviceTree.filter = "bcm271*.dtb";


}) ({ ## Base Config

    # Some base config:
    documentation.enable = false; # sometimes takes quite long to build


}) ({ ## Actual Config

    ## And here would go the things that actually make the host unique (and do something productive). For now just some debugging things:

    environment.systemPackages = [ pkgs.curl pkgs.htop pkgs.tree ];

    services.getty.autologinUser = "root"; users.users.root.password = "root";

    boot.kernelParams = [ /* "console=tty1" */ "console=ttyS0" "boot.shell_on_fail" ]; # [ "rd.systemd.unit=emergency.target" ]; # "rd.systemd.debug_shell" "rd.systemd.debug-shell=1"
    boot.initrd.systemd.emergencyAccess = true;

    systemd.extraConfig = "StatusUnitFormat=name"; # Show unit names instead of descriptions during boot.
    boot.initrd.systemd.extraConfig = "StatusUnitFormat=name";

    boot.loader.timeout = lib.mkDefault 1; # save 4 seconds on startup


}) ]; }
