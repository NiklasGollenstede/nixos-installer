
# Automated File System Setup

NixOS usually gets set up by booting a live system (e.g. from USB), manually setting up file systems on the target disks, mounting them and then using `nixos-generate-config` to deduct the `fileSystems` from the mounted state.

This runs completely contrary to how NixOS usually does (and should) work (the system state should be derived from the config, not the config from the system state), and it does not at all work for hermetic flakes (where all config needs to be committed in the flake repo) or for automated installations.

[`disks`](./disks.nix.md), [`keystore`](./keystore.nix.md), and [`zfs`](./zfs.nix.md), allow to not only specify how file systems are to be mounted, but also which devices, partitions, and LUKS layers they live on, and for ZFS the complete pool and dataset layout.
The bash functions in [`lib/setup-scripts`](../../lib/setup-scripts/README.md) take these definitions and perform arbitrarily complex partitioning and file systems creation, as long as:
* Actual device instances or image files (by path) are passed to the installer for each device specified in the configuration.
* Disks are may be partitioned with GPT, but may optionally have an MBR for boot partitions if the loader requires that.
* `fileSystems.*.device`/`boot.initrd.luks.devices.*.device`/`wip.fs.zfs.pools.*.vdevArgs` refer to partitions by GPT partition label (`/dev/disk/by-partlabel/*`) or (LUKS) mapped name (`dev/mapper/*`).
* `boot.initrd.luks.devices.${name}` have a `wip.fs.keystore.keys."luks/${name}/0"` key specified.

[`boot`](./boot.nix.md) and [`temproot`](./temproot.nix.md) help with a concise (if somewhat opinionated) file system setup that places `/` on a file system that gets cleared during reboot, to achieve a system that is truly stateless (or at least explicitly acknowledges where it has state).
