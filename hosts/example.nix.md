/*

# Example Host Configuration

Just to provide an example of what a host configuration using this set of libraries can look like.


## Installation

To install the system to a (set of) virtual machine disk images, with `$hostname` as any of the `instances` below, run in `..`:
```bash
 nix run .'#'$hostname -- install-system /tmp/$hostname/
```
Then to boot the system in a qemu VM with KVM:
```bash
 nix run .'#'$hostname -- run-qemu /tmp/$hostname/
```
See `nix run .#$hostname -- --help` for options and more commands.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in let
    #suffix = builtins.head (builtins.match ''example-(.*)'' name); # make differences in config based on this when using »preface.instances«
    hash = builtins.substring 0 8 (builtins.hashString "sha256" name);
in { preface = { # (any »preface« options have to be defined here)
    instances = [ "example-explicit" "example" "example-minimal" "example-raidz" ]; # Generate multiple variants of this host, with these »name«s.
}; imports = [ ({ ## Hardware

    nixpkgs.hostPlatform = "x86_64-linux"; system.stateVersion = "22.05";

    ## What follows is a whole bunch of boilerplate-ish stuff, most of which multiple hosts would have in common and which would thus be moved to one or more modules:

    boot.loader.extlinux.enable = true;

    # Example of adding and/or overwriting setup/maintenance functions:
    #installer.scripts.install-overwrite = { path = ../example/install.sh.md; order = 1500; };


}) (lib.mkIf (name == "example-explicit") { ## Minimal explicit FS setup

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


}) (lib.mkIf (name == "example") { ## More complex but automatic FS setup

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


}) (lib.mkIf (name == "example-minimal") { ## Minimal automatic FS setup

    setup.bootpart.enable = true; # (also set by »boot.loader.extlinux.enable«)
    setup.temproot.enable = true;
    setup.temproot.temp.type = "tmpfs"; # (default)
    setup.temproot.local.type = "bind"; # (default)
    setup.temproot.local.bind.base = "f2fs";
    setup.temproot.remote.type = "none";


}) (lib.mkIf (name == "example-raidz") { ## Multi-disk ZFS setup

    boot.loader.extlinux.enable = lib.mkForce false; # use UEFI boot this time
    boot.loader.systemd-boot.enable = true; boot.loader.grub.enable = false;

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


}) ({ ## Base Config

    # Some base config:
    documentation.enable = false; # sometimes takes quite long to build


}) ({ ## Actual Config

    ## And here would go the things that actually make the host unique (and do something productive). For now just some debugging things:

    environment.systemPackages = [ pkgs.curl pkgs.htop pkgs.tree ];

    services.getty.autologinUser = "root"; users.users.root.password = "root";

    boot.kernelParams = [ /* "console=tty1" */ "console=ttyS0" "boot.shell_on_fail" ];

}) ]; }
