
# Host Setup Scripts

This is a library of bash functions, mostly for NixOS system installation.

The (paths to these) scripts are meant to be (and by default are) set as `config.wip.setup.scripts.*` (see [`../flakes.nix`](../flakes.nix)), which makes their functions available in the per-host [`devShells`/`apps`](../flakes.nix#mkSystemsFlake).
Host-specific nix variables are available to the bash functions as `@{...}` through [`substituteImplicit`](../scripts.nix#substituteImplicit) with the respective host as root context.
Any script passed later in `scripts` can overwrite the functions of these (earlier) default scripts.

With the functions from here, [a simple three-liner](./install.sh) is enough to do a completely automated NixOS installation:
```bash
function install-system {( # 1: diskPaths
    prepare-installer "$@" || exit
    do-disk-setup "${argv[0]}" || exit
    install-system-to $mnt || exit
)}
```


# `install-system` Documentation

For repositories that use the `lib.wip.mkSystemsFlake` Nix function in their `flake.nix`, the above bash function performs the automated installation of any `nixosConfigurations.$HOST`s (where the host's configurations would usually be placed in the `/hosts/` directory of the repository) to the local disk(s) (or image file(s)) `$DISK`.
On a NixOS host or with a Nix multi-user installation, this can be run by root as: `#` `nix run .#"$HOST" -- install-system "$DISK"`.

Doing an installation on non-NixOS (but Linux), where nix isn't installed for root, the process is a bit of a hack, but works as well.
In this case, all `nix` commands will be run as `$SUDO_USER`, but this script and some other user-owned (or user-generated) code will (need to) be run as root.
If that is acceptable, run with `sudo` as first argument: `$` `nix run .#"$HOST" -- sudo install-system "$DISK"` (And then maybe `sudo bash -c 'chown $SUDO_USER: '"$DISK"` afterwards.)

If `$DISK` points to something in `/dev/`, then it is directly formatted and written to as block device, otherwise `$DISK` is (re-)created as raw image and then used as loop device.
For hosts that install to multiple disks, pass a `:`-separated list of `<disk-name>=<path>` pairs (the name may be omitted only for the "`default`" disk).

Once done, the disk can be transferred -- or the image be copied -- to the final system, and should boot there.
If the host's hardware target allows, a resulting image can also be passed to [`register-vbox`](./maintenance.sh#register-vbox) to create a bootable VirtualBox instance for the current user, or to [`run-qemu`](./maintenance.sh#run-qemu) to start it in a qemu VM.

The "Installation" section of each host's documentation should contain host specific details, if any.


## Development Notes

* The functions are designed to be (and by default are) executed with the bash options `pipefail` and `nounset` (`-u`) set.
* When the functions are executed, `generic-arg-parse` has already been called on the CLI arguments, and the parsed result can be accessed as `"${args[<name>]:-}"` for named arguments and `"${argv[<index>]}"` for positional arguments (except the first one, which has been removed and used as the command or name of the entry function to run).
* Do not use `set -e`. It has some unexpected and unpredictable behavior, and *does not* actually provide the expected semantic of "exit the shell if a command fails (exits != 0)". For example, the internal exit behavior of commands in a function depends on *how the function is called*.
* If the `--debug` flag is passed, then `return` and `exit` are aliased to open a shell when `$?` is not zero. This effectively turns any `|| return` / `|| exit` into break-on-error point.
    * The aliasing does not work if an explicit code is provided to `return` or `exit`. In these cases, or where the breakpoint behavior is not desired, use `\return` or `\exit` (since the `\` suppresses the alias expansion).
    * For/in loops, do not write to / `read` from stdin/fd1, which conflicts with the `return`/`exit` aliasing. Instead use a different file descriptor, e.g.: `while read -u3 a b c ; do ... done 3< <( LC_ALL=C sort ... )`.
    * Similarly in functions that expect stdin data, read all of it before using the first `|| return`.
* `@{native}` is an instance of `nixpkgs` for the calling system (not the target system) with the overlays (implicitly or explicitly) passed to `mkSystemsFlake` applied, but without other `nixpkgs.overlays` set by the system configuration itself.
