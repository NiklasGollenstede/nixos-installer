/*

# Example Host Configuration

Just to provide an example of what a host configuration using this set of libraries can look like.


## Installation

To prepare a virtual machine disk, as `sudo` user with `nix` installed, run in `..`:
```bash
 nix run '.#example' -- sudo install-system /home/$(id -un)/vm/disks/example.img && sudo chown $(id -un): /home/$(id -un)/vm/disks/example.img
 nix run '.#example-raidz' -- sudo install-system /tmp/nixos-main.img:raidz1=/tmp/nixos-rz1.img:raidz2=/tmp/nixos-rz2.img:raidz3=/tmp/nixos-rz3.img
```
Then to boot the system in a qemu VM with KVM:
```bash
 nix run '.#example' -- sudo run-qemu /home/$(id -un)/vm/disks/example.img
```
Or as user with vBox access, run this and use the UI or the printed commands:
```bash
 nix run '.#example' -- register-vbox /home/$(id -un)/vm/disks/example.img
```
Alternative to running directly as `root` (esp. if `nix` is not installed for root), the above commands can also be run with `sudo` as additional argument before the `--`.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    #suffix = builtins.head (builtins.match ''example-(.*)'' name); # make differences in config based on this when using »wip.preface.instances«
    hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
in { imports = [ ({ ## Hardware
    wip.preface.instances = [ "example-explicit" "example" "example-minimal" "example-raidz" ];

    wip.preface.hardware = "x86_64"; system.stateVersion = "22.05";

    ## What follows is a whole bunch of boilerplate-ish stuff, most of which multiple hosts would have in common and which would thus be moved to one or more modules:

    wip.bootloader.extlinux.enable = true;

    # Example of adding and/or overwriting setup/maintenance functions:
    wip.setup.scripts.install-overwrite = { path = ../example/install.sh.md; order = 1000; };


}) (lib.mkIf (name == "example-explicit") { ## Minimal explicit FS setup

    # Declare a boot and system partition. Though not required for EFI, make the boot part visible to boot loaders supporting only MBR.
    wip.fs.disks.partitions."boot-${hash}"   = { type = "ef00"; size = "64M"; index = 1; order = 1500; };
    wip.fs.disks.partitions."system-${hash}" = { type = "8300"; size = null; order = 500; };
    wip.fs.disks.devices = { primary = { mbrParts = "1"; extraFDiskCommands = ''
        t;1;c  # type ; part1 ; W95 FAT32 (LBA)
        a;1    # active/boot ; part1
    ''; }; };

    # Put everything except for /boot and /nix/store on a tmpfs. This is the absolute minimum, most usable systems require some more paths that are persistent (e.g. all of /nix and /home).
    fileSystems."/"          = { fsType  =  "tmpfs";    device = "tmpfs"; neededForBoot = true; options = [ "mode=755" ]; };
    fileSystems."/boot"      = { fsType  =   "vfat";    device = "/dev/disk/by-partlabel/boot-${hash}"; neededForBoot = true; options = [ "noatime" ]; formatOptions = "-F 32"; };
    fileSystems."/system"    = { fsType  =   "ext4";    device = "/dev/disk/by-partlabel/system-${hash}"; neededForBoot = true; options = [ "noatime" ]; formatOptions = "-O inline_data -E nodiscard -F"; };
    fileSystems."/nix/store" = { options = ["bind,ro"]; device = "/system/nix/store"; neededForBoot = true; };


}) (lib.mkIf (name == "example") { ## More complex but automatic FS setup

    #wip.fs.disks.devices.primary.size = "16G"; # (default)
    wip.fs.boot.enable = true; wip.fs.boot.size = "512M";

    wip.fs.keystore.enable = true;
    wip.fs.temproot.enable = true;

    wip.fs.temproot.temp.type = "tmpfs";

    wip.fs.temproot.local.type = "bind";
    wip.fs.temproot.local.bind.base = "f2fs-encrypted"; # creates partition and FS
    #wip.fs.keystore.keys."luks/local-${hash}/0" = "random"; # (implied by the »-encrypted« suffix above)
    #wip.fs.disks.partitions."local-${hash}".size = "50%"; # (default)

    wip.fs.temproot.remote.type = "zfs";
    wip.fs.keystore.keys."luks/rpool-${hash}/0" = "random";
    #wip.fs.keystore.keys."zfs/rpool-${hash}/remote" = "random"; # (default)
    #wip.fs.zfs.pools."rpool-${hash}".vdevArgs = [ "rpool-${hash}" ]; # (default)
    #wip.fs.disks.partitions."rpool-${hash}" = { type = "bf00"; size = null; order = 500; }; # (default)

    wip.fs.temproot.local.mounts."/var/log" = lib.mkForce null; # example: don't keep logs


}) (lib.mkIf (name == "example-minimal") { ## Minimal automatic FS setup

    wip.fs.boot.enable = true;
    wip.fs.temproot.enable = true;
    wip.fs.temproot.temp.type = "tmpfs";
    wip.fs.temproot.local.type = "bind";
    wip.fs.temproot.local.bind.base = "f2fs";
    wip.fs.temproot.remote.type = "none";


}) (lib.mkIf (name == "example-raidz") { ## Multi-disk ZFS setup

    wip.bootloader.extlinux.enable = lib.mkForce false; # use UEFI boot this time
    boot.loader.systemd-boot.enable = true; boot.loader.grub.enable = false;

    wip.fs.disks.devices = lib.genAttrs ([ "primary" "raidz1" "raidz2" "raidz3" ]) (name: { size = "16G"; });
    wip.fs.boot.enable = true; wip.fs.boot.size = "512M";

    wip.fs.keystore.enable = true;
    wip.fs.temproot.enable = true;

    wip.fs.temproot.temp.type = "zfs";
    wip.fs.temproot.local.type = "zfs";

    wip.fs.temproot.remote.type = "zfs";
    wip.fs.zfs.pools."rpool-${hash}".vdevArgs = [ "raidz1" "rpool-rz1-${hash}" "rpool-rz2-${hash}" "rpool-rz3-${hash}" "log" "rpool-zil-${hash}" "cache" "rpool-arc-${hash}" ];
    wip.fs.disks.partitions."rpool-rz1-${hash}" = { type = "bf00"; disk = "raidz1"; };
    wip.fs.disks.partitions."rpool-rz2-${hash}" = { type = "bf00"; disk = "raidz2"; };
    wip.fs.disks.partitions."rpool-rz3-${hash}" = { type = "bf00"; disk = "raidz3"; };
    wip.fs.disks.partitions."rpool-zil-${hash}" = { type = "bf00"; size = "2G"; };
    wip.fs.disks.partitions."rpool-arc-${hash}" = { type = "bf00"; };


}) ({ ## Base Config

    # Some base config:
    wip.base.enable = true;
    documentation.enable = false; # sometimes takes quite long to build


}) ({ ## Actual Config

    ## And here would go the things that actually make the host unique (and do something productive). For now just some debugging things:

    environment.systemPackages = [ pkgs.curl pkgs.htop ];

    services.getty.autologinUser = "root"; users.users.root.password = "root";

    boot.kernelParams = [ /* "console=tty1" */ "console=ttyS0" "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    wip.services.dropbear.enable = true;
    wip.services.dropbear.rootKeys = ''${lib.readFile "${dirname}/../example/ssh-login.pub"}'';
    wip.services.dropbear.socketActivation = true;

    #wip.fs.disks.devices.primary.gptOffset = 64;
    #wip.fs.disks.devices.primary.size = "250059096K"; # 256GB Intel H10

    boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

})  ]; }
