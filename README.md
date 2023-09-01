
# Automated NixOS CLI Installer

NixOS is traditionally either installed by creating and populating filesystems [by hand](https://nixos.org/manual/nixos/stable/index.html#sec-installation-manual-partitioning), or by scripts that each only support one or a limited set of filesystem setups (the graphical installer falls somewhere between the two).
The mounted filesystems and some hardware aspects are then be captured in a `hardware-configuration.nix`.
This both completely contradicts the declarative nature and flexibility of Nix(OS).

In contrast to that, this flake implements a very flexible, declaratively driven and fully automated NixOS installer (framework).
Hosts can define any number of [disks and partitions](./modules/setup/disks.nix.md) on them.
If the `fileSystems` use `partlabel`s to identify their devices, then they can be associated with their partitions even before they are formatted -- and can thus automatically be formatted during the installation.
ZFS [pools and datasets](./modules/setup/zfs.nix.md), and LUKS and ZFS [encryption](./modules/setup/keystore.nix.md) are also supported.
For setups with ephemeral `/` (root filesystem), [`modules/setup/temproot.nix.md`](./modules/setup/temproot.nix.md) provides various preconfigured setups.
This, together with convenient defaults for most of the options, means that simple setups (see the `minimal` [example](./hosts/example.nix.md)) only require a handful of config lines, while complex multi-disk setups (see the `raidz` [example](./hosts/example.nix.md)) are just as possible.

A set of composable [`setup-scripts`](./lib/setup-scripts/) can then [automatically](https://github.com/NiklasGollenstede/nix-functions/blob/master/lib/scripts.nix#substituteImplicit) grab this information and perform a completely automated installation.
The only thing that the scripts will interactively prompt for are external secrets (e.g., passwords), iff required by the new host.
When using [`mkSystemsFlake`](./lib/nixos.nix#mkSystemsFlake), the installation can be started with:
```bash
nix run .'#'hostname -- install-system /path/to/disk
```
Help output with information on available commands and flags is [available here](https://github.com/NiklasGollenstede/nixos-installer/wiki/−−help-Output) or via:
```bash
nix run .'#'hostname -- --help
```

[`config.installer.commands.*`](./modules/installer.nix.md) can be used to run host-specific commands at various points of the installation, and additional `config.installer.scripts` can [add or replace](./lib/setup-scripts/README.md) new and existing setup commands or functions.
This mechanism has been used to, for example, <!-- [automatically restore of ZFS backups]() during the installation, or to --> [automatically deploy](https://github.com/NiklasGollenstede/nix-wiplib/blob/master/modules/hardware/hetzner-vps.nix.md#installation--testing) locally built system images tp Hetzner VPSes.


## Repo Layout/Contents

This is a nix flake repository, so [`flake.nix`](./flake.nix) is the entry point and export mechanism for almost everything.

[`lib/`](./lib/) defines new library functions which are exported as the `lib` flake output. Other Nix files in this repo use them as `inputs.self.lib`. \
[`setup-scripts`](./lib/setup-scripts/) contains the implementation for the default setup (system installation and maintenance) commands.

[`modules/`](./modules/) contains NixOS configuration modules.
[`bootloader/extlinux`](./modules/bootloader/extlinux.nix.md) enables `extlinux` as alternative bootloader for legacy BIOS environments, because GRUB refuses top be installed to loop-mounted images.
The modules in [`setup`](./modules/setup/) allow defining a NixOS system's disk and filesystem setup in sufficient detail that a fully automatic installation is possible.
The [`installer`](./modules/installer.nix.md) module composes the [`setup-scripts`](./lib/setup-scripts/) and the host's `config` into its individual installer.

There is currently only [one overlay](./overlays/gptfdisk.nix.md) that applies [a patch](./patches/gptfdisk-move-secondary-table.patch) to `sgdisk` (it allows moving the backup GPT table, see [gptfdisk #32](https://sourceforge.net/p/gptfdisk/code/merge-requests/32/)).

[`hosts/example`](./hosts/example.nix.md) provides some NixOS host definitions that demonstrate different types of disk setups.

[`example/`](./example/) contains examples for customizing the [installation](./example/install.sh.md) script for the hosts, and this flake's [default config](./example/defaultConfig/flake.nix).


## License

All files in this repository ([`nixos-installer`](https://github.com/NiklasGollenstede/nixos-installer)), except `./LICENSE`, are authored by the authors of this repository, and are copyright 2022 - present Niklas Gollenstede.

See [`patches/README.md#license`](./patches/README.md#license) for the licensing of the included [patches](./patches/).
All other parts of this software may be used under the terms of the MIT license, as detailed in [`./LICENSE`](./LICENSE).

This license applies to the files in this repository only.
Any external packages are built from sources that have their own licenses, which should be the ones indicated in the package's metadata.
