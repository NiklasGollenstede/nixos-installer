
# Host Setup Scripts

This is a library of bash functions, mostly for NixOS system installation.

The (paths to these) scripts are meant to be passed in the `scripts` argument to [`mkSystemsFlake`](../flakes.nix#mkSystemsFlake) (see [`flake.nix`](../../flake.nix) for an example), which makes their functions available in the per-host [`devShells`/`apps`](../flakes.nix#mkSystemsFlake).
Host-specific nix variables are available to the bash functions as `@{...}` through [`substituteImplicit`](../scripts.nix#substituteImplicit) with the respective host as root context.
Any script passed later in `scripts` can overwrite the functions of these (earlier) default scripts.

With the functions from here, [a simple four-liner](../install.sh) is enough to do a completely automated NixOS installation:
```bash
function install-system {( set -eu # 1: diskPaths
    prepare-installer "$@"
    do-disk-setup "${argv[0]}"
    init-or-restore-system
    install-system-to $mnt
)}
```


# `install-system` Documentation

The above function performs the mostly automated installation of any `$HOST` from [`../../hosts/`](../../hosts/) to the local disk(s) (or image file(s)) `$DISK`.
On a NixOS host, this can be run by root as: `#` `nix run .#"$HOST" -- install-system "$DISK"`.

Doing an installation on non-NixOS (but Linux), where nix isn't installed for root, is a bit of a hack, but works as well.
In this case, all `nix` commands will be run as `$SUDO_USER`, but this script and some other user-owned (or user-generated) code will (need to) be run as root.
If that is acceptable, run with `sudo` as first argument: `$` `nix run .#"$HOST" -- sudo install-system "$DISK"` (And then maybe `sudo bash -c 'chown $SUDO_USER: '"$DISK"` afterwards.)

If `$DISK` points to something in `/dev/`, then it is directly formatted and written to as block device, otherwise `$DISK` is (re-)created as raw image and then used as loop device.
For hosts that install to multiple disks, pass a `:`-separated list of `<disk-name>=<path>` pairs (the name may be omitted only for the "`default`" disk).

Once done, the disk can be transferred -- or the image be copied -- to the final system, and should boot there.
If the host's hardware target allows, a resulting image can also be passed to [`register-vbox`](../maintenance.sh#register-vbox) to create a bootable VirtualBox instance for the current user, or to [`run-qemu`](../maintenance.sh#run-qemu) to start it in a qemu VM.

The "Installation" section of each host's documentation should contain host specific details, if any.
