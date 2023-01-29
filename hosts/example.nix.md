/*

# Example Host Configuration

Just to provide an example of what a host configuration using this set of libraries can look like.


## Installation

To prepare a virtual machine disk, as `sudo` user with `nix` installed, run in `..`:
```bash
 nix run '.#example' -- sudo install-system /home/$(id -un)/vm/disks/example/
 ( sudo chown $(id -un): /home/$(id -un)/vm/disks/example/* )
 nix run '.#example-raidz' -- sudo install-system /tmp/nixos-example-raidz/
```
Then to boot the system in a qemu VM with KVM:
```bash
 nix run '.#example' -- sudo run-qemu /home/$(id -un)/vm/disks/example/
```
Or as user with vBox access, run this and use the UI or the printed commands:
```bash
 nix run '.#example' -- register-vbox /home/$(id -un)/vm/disks/example/primary.img
```
Alternative to running with `sudo` (if `nix` is installed for root), the above commands can also be run as `root` without the `sudo` argument.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    #suffix = builtins.head (builtins.match ''example-(.*)'' name); # make differences in config based on this when using »wip.preface.instances«
    hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
in { imports = [ ({ ## Hardware
    wip.preface.instances = [ "example-explicit" "example" "example-minimal" "example-raidz" "test-zfs-hibernate" ];

    wip.preface.hardware = "x86_64"; system.stateVersion = "22.05";

    ## What follows is a whole bunch of boilerplate-ish stuff, most of which multiple hosts would have in common and which would thus be moved to one or more modules:

    wip.bootloader.extlinux.enable = true;

    # Example of adding and/or overwriting setup/maintenance functions:
    #wip.setup.scripts.install-overwrite = { path = ../example/install.sh.md; order = 1000; };


}) (lib.mkIf (name == "example-explicit") { ## Minimal explicit FS setup

    # Declare a boot and system partition. Though not required for EFI, make the boot part visible to boot loaders supporting only MBR.
    wip.fs.disks.partitions."boot-${hash}"   = { type = "ef00"; size = "64M"; index = 1; order = 1500; };
    wip.fs.disks.partitions."system-${hash}" = { type = "8300"; size = null; order = 500; };
    wip.fs.disks.devices = { primary = { mbrParts = "1"; extraFDiskCommands = ''
        t;1;c  # type ; part1 ; W95 FAT32 (LBA)
        a;1    # active/boot ; part1
    ''; }; };
    wip.fs.boot.enable = false;

    # Put everything except for /boot and /nix/store on a tmpfs. This is the absolute minimum, most usable systems require some more paths that are persistent (e.g. all of /nix and /home).
    fileSystems."/"          = { fsType  =  "tmpfs";    device = "tmpfs"; neededForBoot = true; options = [ "mode=755" ]; };
    fileSystems."/boot"      = { fsType  =   "vfat";    device = "/dev/disk/by-partlabel/boot-${hash}"; neededForBoot = true; options = [ "noatime" ]; formatOptions = "-F 32"; };
    fileSystems."/system"    = { fsType  =   "ext4";    device = "/dev/disk/by-partlabel/system-${hash}"; neededForBoot = true; options = [ "noatime" ]; formatOptions = "-O inline_data -E nodiscard -F"; };
    fileSystems."/nix/store" = { options = ["bind,ro"]; device = "/system/nix/store"; neededForBoot = true; };


}) (lib.mkIf (name == "example" || name == "test-zfs-hibernate") { ## More complex but automatic FS setup

    #wip.fs.disks.devices.primary.size = "16G"; # (default)
    wip.fs.boot.enable = true; wip.fs.boot.size = "512M";

    wip.fs.keystore.enable = true;
    wip.fs.temproot.enable = true;

    wip.fs.temproot.swap.size = "2G";
    wip.fs.temproot.swap.asPartition = true;
    wip.fs.temproot.swap.encrypted = true;

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

    environment.systemPackages = [ pkgs.curl pkgs.htop pkgs.tree ];

    services.getty.autologinUser = "root"; users.users.root.password = "root";

    boot.kernelParams = [ /* "console=tty1" */ "console=ttyS0" "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    wip.services.dropbear.enable = true;
    wip.services.dropbear.rootKeys = ''${lib.readFile "${dirname}/../example/ssh-login.pub"}'';
    wip.services.dropbear.socketActivation = true;

    #wip.fs.disks.devices.primary.gptOffset = 64;
    #wip.fs.disks.devices.primary.size = "250059096K"; # 256GB Intel H10

    boot.binfmt.emulatedSystems = [ "aarch64-linux" ];


}) (lib.mkIf (name == "test-zfs-hibernate") {
    # This was an attempt to reliably get ZFS to corrupt when importing a ZFS pool before resuming from hibernation in initrd. It isn't reproducible, though: https://github.com/NixOS/nixpkgs/pull/208037#issuecomment-1368240321

    wip.fs.temproot.temp.type = lib.mkForce "zfs";
    wip.fs.temproot.local.type = lib.mkForce "zfs";
    wip.fs.keystore.keys."luks/rpool-${hash}/0" = lib.mkForce null;

    wip.fs.disks.devices.mirror.size = "16G";
    wip.fs.disks.partitions."mirror-${hash}" = { type = "bf00"; disk = "mirror"; };
    environment.systemPackages = [ (pkgs.writeShellScriptBin "test-zfs-hibernate" ''
        set -ex
        </dev/urandom head -c 10G >/tmp/dump
        sync ; echo 3 > /proc/sys/vm/drop_caches ; sleep 5
        zpool attach rpool-${hash} /dev/disk/by-partlabel/rpool-${hash} /dev/disk/by-partlabel/mirror-${hash}
        sleep 2 # the above command should still be in progress
        : before ; date
        systemctl hibernate
        : hibernating ; date
        sleep 3 ; : awake ; date
    '') ];
    boot.zfs = if (builtins.substring 0 5 inputs.nixpkgs.lib.version) == "22.05" then { } else { allowHibernation = true; };


}) ]; }
