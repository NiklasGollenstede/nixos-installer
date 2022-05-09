/*

# Example Host Configuration

Just to provide an example of what a host configuration using this set of libraries can look like.


## Installation

To prepare a virtual machine disk, as `sudo` user with `nix` installed, run in `..`:
```bash
 nix run '.#example' -- sudo install-system /home/$(id -un)/vm/disks/example.img && sudo chown $(id -un): /home/$(id -un)/vm/disks/example.img
```
Then as the user that is supposed to run the VM(s):
```bash
 nix run '.#example' -- register-vbox /home/$(id -un)/vm/disks/example.img
```
And manage the VM(s) using the UI or the commands printed.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    #suffix = builtins.head (builtins.match ''example-(.*)'' name); # make differences in config based on this when using »preface.instances«
    hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
in { imports = [ ({ ## Hardware
    #preface.instances = [ "example-a" "example-b" "example-c" ];

    preface.hardware = "x86_64"; system.stateVersion = "22.05";

    ## What follows is a whole bunch of boilerplate-ish stuff, most of which multiple hosts would have in common and which would thus be moved to one or more modules:

    boot.loader.systemd-boot.enable = true; boot.loader.grub.enable = false;

    # Declare a boot and system partition. Though not required for EFI, make the boot part visible to boot loaders supporting only MBR.
    wip.installer.partitions."boot-${hash}"   = { type = "ef00"; size = "64M"; index = 1; order = 1500; };
    wip.installer.partitions."system-${hash}" = { type = "8300"; size = null; order = 500; };
    wip.installer.disks = { primary = { mbrParts = "1"; extraFDiskCommands = ''
        t;1;c  # type ; part1 ; W95 FAT32 (LBA)
        a;1    # active/boot ; part1
    ''; }; };

    # Put everything except for /boot and /nix/store on a tmpfs. This is the absolute minimum, most usable systems require some more paths that are persistent (e.g. all of /nix and /home).
    fileSystems."/"          = { fsType  =  "tmpfs";    device = "tmpfs"; neededForBoot = true; options = [ "mode=755" ]; };
    fileSystems."/boot"      = { fsType  =   "vfat";    device = "/dev/disk/by-partlabel/boot-${hash}"; neededForBoot = true; options = [ "noatime" ]; formatOptions = "-F 32"; };
    fileSystems."/system"    = { fsType  =   "ext4";    device = "/dev/disk/by-partlabel/system-${hash}"; neededForBoot = true; options = [ "noatime" ]; formatOptions = "-O inline_data -E nodiscard -F"; };
    fileSystems."/nix/store" = { options = ["bind,ro"]; device = "/system/nix/store"; neededForBoot = true; };

    # Some base config:
    users.mutableUsers = false; users.allowNoPasswordLogin = true;
    networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));
    environment.etc."machine-id".text = (builtins.substring 0 32 (builtins.hashString "sha256" "${config.networking.hostName}:machine-id"));
    boot.kernelParams = [ "panic=10" "boot.panic_on_fail" ]; # Reboot on kernel panic, panic if boot fails.
    systemd.extraConfig = "StatusUnitFormat=name"; # Show unit names instead of descriptions during boot.

    # Static config for VBox Adapter 1 set to NAT (the default):
    networking.interfaces.enp0s3.ipv4.addresses = [ {
        address = "10.0.2.15"; prefixLength = 24;
    } ];
    networking.defaultGateway = "10.0.2.2";
    networking.nameservers = [ "1.1.1.1" ]; # [ "10.0.2.3" ];


}) ({ ## Actual Config

    ## And here would go the things that actually make the host unique (and do something productive). For now just some debugging things:

    environment.systemPackages = [ pkgs.curl pkgs.htop ];

    services.getty.autologinUser = "root"; users.users.root.password = "root";

    boot.kernelParams = [ "boot.shell_on_fail" ];

    wip.services.dropbear.enable = true;
    #wip.services.dropbear.rootKeys = [ ''${lib.readFile "${dirname}/....pub"}'' ];


})  ]; }
